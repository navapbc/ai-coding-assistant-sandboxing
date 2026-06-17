#!/usr/bin/env bash
# init-egress-proxy.sh — EXPERIMENTAL opt-in egress mode for the devcontainer.
#
# Runs an explicit HTTP CONNECT forward proxy (Envoy) and forces all egress
# through it. Two sub-modes:
#   EGRESS_TLS_TERMINATE=false (default) — pass-through. Allowlists the cleartext
#     CONNECT authority; TLS not terminated. Hostname-matched (no IP drift) and
#     ROBUST TO ECH. Does NOT defeat domain fronting.
#   EGRESS_TLS_TERMINATE=true — MITM. Pre-mints one leaf cert per allowlisted
#     host from a session CA, terminates the tunnelled TLS, allowlists the
#     decrypted Host (so fronting is denied), re-originates upstream. This is a
#     real MITM: pinned-cert hosts break. ⚠️ UNVALIDATED — see README.md.
#
# ⚠️ UNTESTED IN CI. Reviewed reference only — validate on a real build.
# Requires: root + NET_ADMIN, iptables, envoy, openssl, a dedicated run-as user.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINS_FILE="${DOMAINS_FILE:-${SCRIPT_DIR}/../allowed-domains.txt}"
ENVOY_CONFIG="${ENVOY_CONFIG:-/tmp/envoy-egress.yaml}"
ENVOY_PORT="${ENVOY_PORT:-15001}"
ENVOY_USER="${ENVOY_USER:-envoyproxy}"
TERMINATE="${EGRESS_TLS_TERMINATE:-false}"
CERTS_DIR="${CERTS_DIR:-/tmp/egress-certs}"

die() { echo "init-egress-proxy: $*" >&2; exit 1; }

command -v envoy >/dev/null 2>&1 || die "envoy not found on PATH (build with --build-arg EGRESS_PROXY=true)"
command -v iptables >/dev/null 2>&1 || die "iptables not found"
[ -f "$DOMAINS_FILE" ] || die "allowlist not found: $DOMAINS_FILE"
id -u "$ENVOY_USER" >/dev/null 2>&1 || die "user '$ENVOY_USER' does not exist (create it in the Dockerfile)"
envoy_uid="$(id -u "$ENVOY_USER")"

# Bare host list (single source of truth) used for every rendering below.
hosts_file="$(mktemp)"
trap 'rm -f "$hosts_file"' EXIT
sed -E 's/#.*$//; s/[[:space:]]+//g' "$DOMAINS_FILE" | grep -vE '^$' > "$hosts_file"
[ -s "$hosts_file" ] || die "no domains parsed from $DOMAINS_FILE"

if [ "$TERMINATE" = "true" ]; then
  command -v openssl >/dev/null 2>&1 || die "openssl not found (needed for EGRESS_TLS_TERMINATE)"
  echo "init-egress-proxy: TLS-TERMINATING mode — pre-minting per-host certs (MITM; pinned hosts will break)"

  # 1) Session CA + a leaf per allowlisted host; trust the CA so clients accept it.
  install -d -m 700 "$CERTS_DIR"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$CERTS_DIR/ca.key" -out "$CERTS_DIR/ca.crt" -subj "/CN=devcontainer-egress-CA" 2>/dev/null
  install -m 644 "$CERTS_DIR/ca.crt" /usr/local/share/ca-certificates/egress-ca.crt
  update-ca-certificates >/dev/null 2>&1 || echo "init-egress-proxy: WARNING: update-ca-certificates failed" >&2

  certs_block="$(mktemp)"; auth_block="$(mktemp)"; host_block="$(mktemp)"
  trap 'rm -f "$hosts_file" "$certs_block" "$auth_block" "$host_block"' EXIT
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    openssl req -newkey rsa:2048 -nodes -keyout "$CERTS_DIR/$host.key" -out "$CERTS_DIR/$host.csr" \
      -subj "/CN=$host" 2>/dev/null
    openssl x509 -req -in "$CERTS_DIR/$host.csr" -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" \
      -CAcreateserial -days 1 -extfile <(printf 'subjectAltName=DNS:%s' "$host") \
      -out "$CERTS_DIR/$host.crt" 2>/dev/null
    printf '              - certificate_chain: { filename: %s/%s.crt }\n                private_key: { filename: %s/%s.key }\n' \
      "$CERTS_DIR" "$host" "$CERTS_DIR" "$host" >> "$certs_block"
    printf '                - "%s:443"\n' "$host" >> "$auth_block"
    printf '                - "%s"\n' "$host" >> "$host_block"
  done < "$hosts_file"
  chown -R "$ENVOY_USER" "$CERTS_DIR"

  awk -v af="$auth_block" -v cf="$certs_block" -v hf="$host_block" '
    /@@CONNECT_AUTHORITIES@@/ { while ((getline l < af) > 0) print l; close(af); next }
    /@@TLS_CERTIFICATES@@/    { while ((getline l < cf) > 0) print l; close(cf); next }
    /@@ALLOWED_HOSTS@@/       { while ((getline l < hf) > 0) print l; close(hf); next }
    /example\.invalid/        { next }
    { print }
  ' "${SCRIPT_DIR}/envoy-mitm.yaml" > "$ENVOY_CONFIG"
else
  echo "init-egress-proxy: CONNECT pass-through mode (ECH-robust; fronting not caught)"
  auth_block="$(mktemp)"
  trap 'rm -f "$hosts_file" "$auth_block"' EXIT
  sed -E 's/.*/                - "&:443"/' "$hosts_file" > "$auth_block"
  awk -v af="$auth_block" '
    /@@CONNECT_AUTHORITIES@@/ { while ((getline l < af) > 0) print l; close(af); next }
    /"example\.invalid:443"/ { next }
    { print }
  ' "${SCRIPT_DIR}/envoy.yaml" > "$ENVOY_CONFIG"
fi

# 2) Point every client at the proxy (best-effort; containerEnv is more reliable).
proxy_url="http://127.0.0.1:${ENVOY_PORT}"
{
  echo "HTTP_PROXY=${proxy_url}";  echo "http_proxy=${proxy_url}"
  echo "HTTPS_PROXY=${proxy_url}"; echo "https_proxy=${proxy_url}"
  echo "NO_PROXY=localhost,127.0.0.1,::1"; echo "no_proxy=localhost,127.0.0.1,::1"
} >> /etc/environment
printf 'export HTTP_PROXY=%s HTTPS_PROXY=%s NO_PROXY=localhost,127.0.0.1,::1\n' \
  "$proxy_url" "$proxy_url" > /etc/profile.d/egress-proxy.sh

# 3) Firewall: default-deny; allow loopback (client -> proxy), DNS to the pinned
#    resolver, and the proxy's OWN egress. Direct connections fail closed.
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
iptables -A OUTPUT -m owner --uid-owner "$envoy_uid" -j ACCEPT

# 4) Launch Envoy as the dedicated user (background for a single postStart; run
#    it as a managed service for real use).
echo "init-egress-proxy: starting Envoy on 127.0.0.1:$ENVOY_PORT (terminate=$TERMINATE, $(wc -l < "$hosts_file") hosts)"
sudo -u "$ENVOY_USER" sh -c "nohup envoy -c '$ENVOY_CONFIG' --base-id 1 >/tmp/envoy-egress.log 2>&1 &"

# 5) Smoke-test (best-effort): allowlisted host OK, non-listed 403/blocked.
sleep 2
echo "init-egress-proxy: self-test (expect api.github.com OK, example.com 403/blocked):"
curl -sS --max-time 8 -x "$proxy_url" -o /dev/null -w "  api.github.com -> %{http_code}\n" https://api.github.com/zen || echo "  api.github.com -> blocked"
curl -sS --max-time 8 -x "$proxy_url" -o /dev/null -w "  example.com -> %{http_code} (expect 403, NOT 200)\n" https://example.com/ || echo "  example.com -> blocked"
