#!/usr/bin/env bash
# init-egress-proxy.sh — EXPERIMENTAL opt-in egress mode for the devcontainer.
#
# Runs an explicit HTTP CONNECT forward proxy (Envoy) and forces all egress
# through it. Clients send `CONNECT host:443` in cleartext; only allowlisted
# CONNECT authorities are tunnelled, everything else is 403'd. Filtering is by
# HOSTNAME (no IP resolution → no CDN drift) and is ROBUST TO ECH (the
# destination is the cleartext CONNECT host; the encrypted inner SNI is never
# needed). It does NOT defeat domain fronting — only TLS termination does
# (Docker Sandboxes).
#
# ⚠️ UNTESTED IN CI. Reviewed reference only — validate on a real build (see
# README.md "Validate before relying").
#
# Requires: root + NET_ADMIN, iptables, envoy on PATH, a dedicated run-as user.
# Egress is locked to the proxy: clients use HTTP(S)_PROXY; anything that ignores
# the proxy and connects directly is dropped by iptables (fails closed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINS_FILE="${DOMAINS_FILE:-${SCRIPT_DIR}/../allowed-domains.txt}"
ENVOY_TEMPLATE="${ENVOY_TEMPLATE:-${SCRIPT_DIR}/envoy.yaml}"
ENVOY_CONFIG="${ENVOY_CONFIG:-/tmp/envoy-egress.yaml}"
ENVOY_PORT="${ENVOY_PORT:-15001}"
ENVOY_USER="${ENVOY_USER:-envoyproxy}"

die() { echo "init-egress-proxy: $*" >&2; exit 1; }

command -v envoy >/dev/null 2>&1 || die "envoy not found on PATH (build with --build-arg EGRESS_PROXY=true)"
command -v iptables >/dev/null 2>&1 || die "iptables not found"
[ -f "$DOMAINS_FILE" ] || die "allowlist not found: $DOMAINS_FILE"
id -u "$ENVOY_USER" >/dev/null 2>&1 || die "user '$ENVOY_USER' does not exist (create it in the Dockerfile)"
envoy_uid="$(id -u "$ENVOY_USER")"

# 1) Render the allowed CONNECT authorities ("host:443") from the shared
#    allowlist (single source of truth) into the Envoy config.
auth_file="$(mktemp)"
trap 'rm -f "$auth_file"' EXIT
sed -E 's/#.*$//; s/[[:space:]]+//g' "$DOMAINS_FILE" | grep -vE '^$' \
  | sed -E 's/.*/                - "&:443"/' > "$auth_file"
[ -s "$auth_file" ] || die "no domains parsed from $DOMAINS_FILE"

awk -v af="$auth_file" '
  /@@CONNECT_AUTHORITIES@@/ { while ((getline l < af) > 0) print l; close(af); next }
  /"example\.invalid:443"/ { next }
  { print }
' "$ENVOY_TEMPLATE" > "$ENVOY_CONFIG"

# 2) Point every client at the proxy (best-effort, container-wide). Reliable
#    delivery is via containerEnv (see README); these cover login shells.
proxy_url="http://127.0.0.1:${ENVOY_PORT}"
{
  echo "HTTP_PROXY=${proxy_url}";  echo "http_proxy=${proxy_url}"
  echo "HTTPS_PROXY=${proxy_url}"; echo "https_proxy=${proxy_url}"
  echo "NO_PROXY=localhost,127.0.0.1,::1"; echo "no_proxy=localhost,127.0.0.1,::1"
} >> /etc/environment
printf 'export HTTP_PROXY=%s HTTPS_PROXY=%s NO_PROXY=localhost,127.0.0.1,::1\n' \
  "$proxy_url" "$proxy_url" > /etc/profile.d/egress-proxy.sh

# 3) Firewall: default-deny; allow loopback (client -> proxy), DNS to the pinned
#    resolver (the proxy resolves CONNECT hosts), and the proxy's OWN egress.
#    Direct connections that bypass the proxy fall through to DROP (fail closed).
resolver="$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)"

iptables -F
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
# Only the proxy may make outbound connections to the world.
iptables -A OUTPUT -m owner --uid-owner "$envoy_uid" -j ACCEPT

# 4) Launch Envoy as the dedicated user. NOTE: backgrounded for a single
#    postStart; run it as a managed service (supervisor / sidecar) for real use.
echo "init-egress-proxy: starting Envoy CONNECT proxy (uid $envoy_uid) on 127.0.0.1:$ENVOY_PORT, $(grep -c ':443"' "$ENVOY_CONFIG") allowed authorities"
sudo -u "$ENVOY_USER" sh -c "nohup envoy -c '$ENVOY_CONFIG' --base-id 1 >/tmp/envoy-egress.log 2>&1 &"

# 5) Smoke-test (best-effort, non-fatal): allowlisted host tunnels; others 403.
sleep 2
echo "init-egress-proxy: self-test via the proxy (expect api.github.com OK, example.com 403/blocked):"
curl -sS --max-time 8 -x "$proxy_url" -o /dev/null -w "  api.github.com -> %{http_code}\n" https://api.github.com/zen || echo "  api.github.com -> blocked"
curl -sS --max-time 8 -x "$proxy_url" -o /dev/null -w "  example.com -> %{http_code} (expect 403, NOT 200)\n" https://example.com/ || echo "  example.com -> blocked"
