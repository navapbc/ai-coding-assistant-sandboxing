#!/usr/bin/env bash
# init-egress-proxy.sh — EXPERIMENTAL opt-in egress mode for the devcontainer.
#
# Replaces the IP-allowlist firewall (init-firewall.sh) with an SNI-filtering
# transparent proxy: outbound :443 is redirected into a local Envoy that allows
# a TLS connection only if its ClientHello SNI is on the allowlist, then proxies
# it (TLS NOT terminated) to its original destination. Matching is by HOSTNAME,
# so it is immune to the CDN IP rotation that makes the IP-resolve firewall
# fragile. Default-deny: unmatched SNI is closed; non-443 egress is dropped.
#
# ⚠️ UNTESTED IN CI. Reviewed reference only — validate on a real build (see
# README.md "Validate before relying"). It does NOT defeat domain fronting or
# ECH; for that, TLS termination is required (use Docker Sandboxes).
#
# Requires: root + NET_ADMIN (the devcontainer has both), iptables, envoy on
# PATH, and a dedicated unprivileged user to run Envoy. HTTPS(443) only — port
# 80 falls through to the default DROP (our allowlist is HTTPS).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINS_FILE="${DOMAINS_FILE:-${SCRIPT_DIR}/../allowed-domains.txt}"
ENVOY_TEMPLATE="${ENVOY_TEMPLATE:-${SCRIPT_DIR}/envoy.yaml}"
ENVOY_CONFIG="${ENVOY_CONFIG:-/tmp/envoy-egress.yaml}"
ENVOY_PORT="${ENVOY_PORT:-15001}"
ENVOY_USER="${ENVOY_USER:-envoyproxy}"

die() { echo "init-egress-proxy: $*" >&2; exit 1; }

command -v envoy >/dev/null 2>&1 || die "envoy not found on PATH (add it to the Dockerfile)"
command -v iptables >/dev/null 2>&1 || die "iptables not found"
[ -f "$DOMAINS_FILE" ] || die "allowlist not found: $DOMAINS_FILE"
id -u "$ENVOY_USER" >/dev/null 2>&1 || die "user '$ENVOY_USER' does not exist (create it in the Dockerfile)"
envoy_uid="$(id -u "$ENVOY_USER")"

# 1) Render the allowlist (single source of truth: allowed-domains.txt) into the
#    Envoy server_names block. Strip comments/blanks/whitespace, indent to match.
names_file="$(mktemp)"
trap 'rm -f "$names_file"' EXIT
sed -E 's/#.*$//; s/[[:space:]]+//g' "$DOMAINS_FILE" | grep -vE '^$' \
  | sed -E 's/.*/          - "&"/' > "$names_file"
[ -s "$names_file" ] || die "no domains parsed from $DOMAINS_FILE"

awk -v nf="$names_file" '
  /@@SERVER_NAMES@@/ { while ((getline l < nf) > 0) print l; close(nf); next }
  /"example\.invalid"/ { next }
  { print }
' "$ENVOY_TEMPLATE" > "$ENVOY_CONFIG"

# 2) Firewall: default-deny; keep DNS pinned to the container resolver; redirect
#    everyone's :443 into Envoy; let Envoy's own egress out (and never redirect
#    it, or it would loop).
resolver="$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)"

iptables -F
iptables -t nat -F
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

if [ -n "$resolver" ]; then
  iptables -A OUTPUT -p udp -d "$resolver" --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp -d "$resolver" --dport 53 -j ACCEPT
else
  echo "init-egress-proxy: WARNING: no resolver in /etc/resolv.conf; DNS will be blocked" >&2
fi

# Envoy's own outbound (to the real, SNI-approved destination) is allowed and
# must be exempt from the redirect below.
iptables -A OUTPUT -m owner --uid-owner "$envoy_uid" -j ACCEPT

# Redirect every other process's :443 into Envoy for SNI filtering, and permit
# the redirected flow to reach it. Everything else falls through to DROP.
iptables -t nat -A OUTPUT -p tcp --dport 443 -m owner ! --uid-owner "$envoy_uid" \
  -j REDIRECT --to-ports "$ENVOY_PORT"
iptables -A OUTPUT -p tcp -d 127.0.0.1 --dport "$ENVOY_PORT" -j ACCEPT

# 3) Launch Envoy as the dedicated user. NOTE: backgrounded here for a single
#    postStart run; for anything real, run Envoy as a managed service (a
#    supervisor or a sidecar compose service) so it is restarted on exit.
echo "init-egress-proxy: starting Envoy (uid $envoy_uid) on :$ENVOY_PORT with $(grep -c '          - "' "$ENVOY_CONFIG") allowed SNI names"
sudo -u "$ENVOY_USER" sh -c "nohup envoy -c '$ENVOY_CONFIG' --base-id 1 >/tmp/envoy-egress.log 2>&1 &"

# 4) Smoke-test (best-effort): an allowlisted host should connect; a non-listed
#    one should be refused. Non-fatal — logs the result for the self-check.
sleep 2
echo "init-egress-proxy: self-test (expect api.github.com OK, example.com BLOCKED):"
curl -sS --max-time 8 -o /dev/null -w "  api.github.com -> %{http_code}\n" https://api.github.com/zen || echo "  api.github.com -> blocked"
curl -sS --max-time 8 -o /dev/null -w "  example.com -> %{http_code} (should NOT be 200)\n" https://example.com/ || echo "  example.com -> blocked (good)"
