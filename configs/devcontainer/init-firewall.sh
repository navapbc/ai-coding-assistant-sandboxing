#!/bin/bash
# init-firewall.sh — default-deny egress firewall for the AI-agent devcontainer.
# Adapted from Anthropic's reference implementation:
#   https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh
#
# Reads the domain allowlist from allowed-domains.txt (one per line, # comments),
# resolves each to IPs at container start, adds GitHub's published web/api/git
# ranges, then sets DROP-by-default policies. Self-tests before finishing.
#
# Requires: NET_ADMIN + NET_RAW capabilities, iptables, ipset, dig, jq, curl.
# Limitation (documented in docs/devcontainer.md): IPs are resolved once at
# start; CDN rotation can break a domain later (rerun this script) and broad
# CDN ranges can over-permit. For hostname-exact filtering use a proxy instead.
set -euo pipefail
IFS=$'\n\t'

ALLOWED_DOMAINS_FILE="${ALLOWED_DOMAINS_FILE:-/usr/local/etc/allowed-domains.txt}"

# GitHub IP-range source. Defaults to public github.com's meta endpoint.
# For GitHub Enterprise Server (self-hosted), set SKIP_GITHUB_META=true and put
# your server's CIDR(s) in EXTRA_CIDRS (space-separated) — your GHES host is your
# own infrastructure, not in GitHub's published ranges.
GITHUB_META_URL="${GITHUB_META_URL:-https://api.github.com/meta}"
SKIP_GITHUB_META="${SKIP_GITHUB_META:-false}"
EXTRA_CIDRS="${EXTRA_CIDRS:-}"

if [[ ! -r "$ALLOWED_DOMAINS_FILE" ]]; then
    echo "ERROR: allowlist not found at $ALLOWED_DOMAINS_FILE" >&2
    exit 1
fi

# Preserve Docker's embedded DNS rules before flushing.
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

if [[ -n "$DOCKER_DNS_RULES" ]]; then
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

# Loopback must work before the default-deny lands.
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# --- DNS egress: pin to the resolver(s) the container actually uses ----------
# Layer 1 (always on): allow DNS only to the nameservers in /etc/resolv.conf
# plus Docker's embedded resolver (127.0.0.11). This removes the "send DNS
# straight to an attacker's resolver" path. It does NOT, by itself, stop DNS
# tunneling via *recursive* resolution through an allowed resolver — for that
# see Layer 2 (ENABLE_DNS_ALLOWLIST) below and docs/threat-model.md.
# Fail-open by design: if we can't determine a resolver, allow DNS broadly with
# a warning rather than breaking all name resolution.
declare -a RESOLVERS=()
if [[ -r /etc/resolv.conf ]]; then
    while read -r ns; do RESOLVERS+=("$ns"); done \
        < <(awk '/^nameserver/ {print $2}' /etc/resolv.conf)
fi
RESOLVERS+=("127.0.0.11")   # Docker embedded resolver (reached via the NAT rules above)
dns_pinned=false
for r in "${RESOLVERS[@]}"; do
    if [[ "$r" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        iptables -A OUTPUT -p udp --dport 53 -d "$r" -j ACCEPT
        iptables -A OUTPUT -p tcp --dport 53 -d "$r" -j ACCEPT  # DNS over TCP (large responses)
        dns_pinned=true
    fi
done
if ! $dns_pinned; then
    echo "WARNING: no IPv4 resolver found in /etc/resolv.conf; allowing DNS broadly" >&2
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
fi
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A INPUT -p tcp --sport 53 -j ACCEPT

ipset create allowed-domains hash:net

# GitHub publishes its web/api/git CIDR ranges; add them wholesale so git
# operations survive GitHub's load balancing. (Public github.com only — see the
# GHES note on GITHUB_META_URL / SKIP_GITHUB_META / EXTRA_CIDRS above.)
if [[ "$SKIP_GITHUB_META" != "true" ]]; then
    echo "Fetching GitHub IP ranges from $GITHUB_META_URL ..."
    gh_ranges=$(curl -s "$GITHUB_META_URL")
    if [[ -z "$gh_ranges" ]] || ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
        echo "ERROR: could not fetch valid GitHub IP ranges" >&2
        exit 1
    fi
    while read -r cidr; do
        if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            echo "ERROR: invalid CIDR from GitHub meta: $cidr" >&2
            exit 1
        fi
        ipset add allowed-domains "$cidr" 2>/dev/null || true
    done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | grep -v ':')  # IPv4 only
else
    echo "Skipping GitHub meta fetch (SKIP_GITHUB_META=true)."
fi

# Extra CIDRs (e.g. a self-hosted GHES server's range).
for cidr in $EXTRA_CIDRS; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: invalid CIDR in EXTRA_CIDRS: $cidr" >&2
        exit 1
    fi
    echo "Adding extra CIDR $cidr"
    ipset add allowed-domains "$cidr" 2>/dev/null || true
done

# Resolve each allowlisted domain to its current IPs.
while read -r domain; do
    domain="${domain%%#*}"                      # strip trailing comments
    domain="$(echo "$domain" | tr -d '[:space:]')"
    [[ -z "$domain" ]] && continue
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [[ -z "$ips" ]]; then
        echo "WARNING: failed to resolve $domain (skipping)" >&2
        continue
    fi
    while read -r ip; do
        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            ipset add allowed-domains "$ip" 2>/dev/null || true
        fi
    done <<< "$ips"
done < "$ALLOWED_DOMAINS_FILE"

# Allow traffic to/from the host network (devcontainer <-> IDE).
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [[ -z "$HOST_IP" ]]; then
    echo "ERROR: failed to detect host IP" >&2
    exit 1
fi
HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Default-deny, then allow established flows and the allowlist.
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
# REJECT (not DROP) the rest so blocked tools fail fast with a clear error.
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# --- DNS egress Layer 2 (opt-in): resolve ONLY allowlisted domains -----------
# Layer 1 above stops DNS to arbitrary resolvers but not tunneling *through* an
# allowed recursive resolver (queries for data.attacker.com still get resolved).
# This layer closes that: run a local dnsmasq that forwards only the allowlisted
# domains to the upstream resolver and refuses everything else (no default
# server), then point the container at it. A lookup for a non-allowlisted name
# returns no answer, so it can't carry data out.
#
# Off by default. Requires dnsmasq in the image (the Dockerfile installs it).
# UNTESTED reference implementation — verify resolution works in your
# environment before relying on it. See docs/threat-model.md and devcontainer.md.
if [[ "${ENABLE_DNS_ALLOWLIST:-false}" == "true" ]]; then
    if ! command -v dnsmasq >/dev/null 2>&1; then
        echo "ERROR: ENABLE_DNS_ALLOWLIST=true but dnsmasq is not installed" >&2
        exit 1
    fi
    DNS_UPSTREAM="${DNS_UPSTREAM:-127.0.0.11}"   # Docker embedded resolver by default
    conf="/etc/dnsmasq.d/sandbox-allowlist.conf"
    mkdir -p /etc/dnsmasq.d
    {
        echo "no-resolv"   # do NOT inherit a default upstream — unlisted names get no server
        echo "no-hosts"
        echo "listen-address=127.0.0.1"
        echo "bind-interfaces"
        # GitHub hostnames (the IP ranges are allowlisted separately by ipset, but
        # the names still need to resolve). Apex domains cover their subdomains.
        for d in github.com githubusercontent.com githubcopilot.com ghcr.io; do
            echo "server=/$d/$DNS_UPSTREAM"
        done
        # Everything in the egress allowlist.
        while read -r line; do
            d="${line%%#*}"; d="$(echo "$d" | tr -d '[:space:]')"
            [[ -z "$d" ]] && continue
            d="${d#\*.}"   # strip a leading wildcard if present
            echo "server=/$d/$DNS_UPSTREAM"
        done < "$ALLOWED_DOMAINS_FILE"
    } > "$conf"
    # dnsmasq's own upstream queries go to $DNS_UPSTREAM:53, already permitted by
    # Layer 1 (the embedded resolver / resolv.conf nameservers).
    pkill -x dnsmasq 2>/dev/null || true
    dnsmasq --conf-file="$conf"
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    echo "DNS allowlist (Layer 2) active via dnsmasq — UNTESTED, verify resolution."
fi

# --- self-test: the firewall must block a non-allowed host and pass an
# allowlisted one. Default reachability target is public GitHub; on GHES set
# VERIFY_REACHABLE_URL to a URL on your server (e.g. https://github.yourco.com).
VERIFY_REACHABLE_URL="${VERIFY_REACHABLE_URL:-https://api.github.com/zen}"
echo "Verifying firewall..."
if curl -s --connect-timeout 5 https://example.com -o /dev/null; then
    echo "ERROR: firewall verification FAILED — reached https://example.com" >&2
    exit 1
fi
if ! curl -s --connect-timeout 10 "$VERIFY_REACHABLE_URL" -o /dev/null; then
    echo "ERROR: firewall verification FAILED — could not reach $VERIFY_REACHABLE_URL" >&2
    exit 1
fi
echo "Firewall verified: default-deny active, allowlist reachable."
