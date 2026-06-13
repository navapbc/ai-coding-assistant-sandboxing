#!/usr/bin/env bash
# run-sandboxed.sh — run a command under the agent.sb Seatbelt profile with a
# sanitized environment. Default posture: workspace-write filesystem, NO network.
#
# Usage:
#   run-sandboxed.sh [options] -- <command> [args...]
#
# Options:
#   --workspace DIR        writable workspace (default: current directory)
#   --allow-net-proxy PORT allow outbound network ONLY to localhost:PORT
#                          (run a domain-filtering proxy there, e.g. mitmproxy
#                          or srt's proxy; direct egress stays blocked, so a
#                          tool that ignores HTTPS_PROXY simply has no network)
#   --pass-env VAR         pass an extra env var through (repeatable)
#
# Examples:
#   run-sandboxed.sh -- npm test
#   run-sandboxed.sh --allow-net-proxy 8888 --pass-env GH_TOKEN -- gh pr list
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${SCRIPT_DIR}/agent.sb"

WORKSPACE="$(pwd)"
PROXY_PORT=""
PASS_ENV=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)       WORKSPACE="$2"; shift 2 ;;
    --allow-net-proxy) PROXY_PORT="$2"; shift 2 ;;
    --pass-env)        PASS_ENV+=("$2"); shift 2 ;;
    --)                shift; break ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "usage: run-sandboxed.sh [options] -- <command> [args...]" >&2
  exit 2
fi

WORKSPACE="$(cd "$WORKSPACE" && pwd)"   # absolute, must exist

# Refuse footgun workspaces: HOME itself or a secrets directory.
case "$WORKSPACE" in
  "$HOME"|"$HOME/.ssh"*|"$HOME/.aws"*|"$HOME/.gnupg"*)
    echo "refusing to use $WORKSPACE as the writable workspace" >&2
    exit 2 ;;
esac

# Assemble the final profile: base + optional network section.
FINAL_PROFILE="$(mktemp -t agent-profile)"
trap 'rm -f "$FINAL_PROFILE"' EXIT
cat "$PROFILE" > "$FINAL_PROFILE"

if [[ -n "$PROXY_PORT" ]]; then
  if ! [[ "$PROXY_PORT" =~ ^[0-9]+$ ]]; then
    echo "--allow-net-proxy expects a port number" >&2
    exit 2
  fi
  cat >> "$FINAL_PROFILE" <<EOF

;; appended by run-sandboxed.sh: outbound ONLY to the localhost proxy
(allow network-outbound (remote tcp "localhost:${PROXY_PORT}"))
EOF
fi

# Sanitized environment: nothing from the parent shell leaks in except an
# explicit allowlist. Add secrets only via --pass-env, deliberately.
ENV_ARGS=(
  "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  "HOME=${HOME}"
  "TMPDIR=${TMPDIR:-/tmp}"
  "TERM=${TERM:-xterm-256color}"
  "LANG=${LANG:-en_US.UTF-8}"
  "USER=${USER}"
)
if [[ -n "$PROXY_PORT" ]]; then
  ENV_ARGS+=(
    "HTTP_PROXY=http://localhost:${PROXY_PORT}"
    "HTTPS_PROXY=http://localhost:${PROXY_PORT}"
    "http_proxy=http://localhost:${PROXY_PORT}"
    "https_proxy=http://localhost:${PROXY_PORT}"
  )
fi
for var in ${PASS_ENV[@]+"${PASS_ENV[@]}"}; do
  if [[ -n "${!var:-}" ]]; then
    ENV_ARGS+=("${var}=${!var}")
  fi
done

exec /usr/bin/env -i "${ENV_ARGS[@]}" \
  /usr/bin/sandbox-exec \
    -f "$FINAL_PROFILE" \
    -D "TARGET_DIR=${WORKSPACE}" \
    -D "HOME_DIR=${HOME}" \
    "$@"
