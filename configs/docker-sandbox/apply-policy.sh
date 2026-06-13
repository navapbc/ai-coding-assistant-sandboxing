#!/usr/bin/env bash
# apply-policy.sh — set Docker Sandboxes (sbx) egress to default-deny + our allowlist.
#
# Drives policy through the documented `sbx policy` CLI (the on-disk local policy
# store format is undocumented, so we don't hand-author a file). Reads the same
# allowed-domains.txt the devcontainer firewall uses (shared list for the
# container-style tiers; tool-level configs keep their own copies — see
# docs/network-allowlists.md "Keeping the allowlists in sync").
#
# Usage:
#   apply-policy.sh [--sandbox NAME] [--domains FILE]
#
#   --sandbox NAME   scope the rules to one sandbox (default: global)
#   --domains FILE   allowlist file (default: ../devcontainer/allowed-domains.txt)
#
# Fleet note: rules set here are USER-LOCAL and developer-changeable. For
# non-overridable enforcement, set an organization policy in the Docker Admin
# Console (AI governance) — see docs/docker-sandbox.md and docs/enforcement.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINS_FILE="${SCRIPT_DIR}/../devcontainer/allowed-domains.txt"
SANDBOX_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sandbox) SANDBOX_ARGS=(--sandbox "$2"); shift 2 ;;
    --domains) DOMAINS_FILE="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if ! command -v sbx >/dev/null 2>&1; then
  echo "ERROR: sbx not found. Install with: brew install docker/tap/sbx" >&2
  exit 1
fi
if [[ ! -r "$DOMAINS_FILE" ]]; then
  echo "ERROR: allowlist not found at $DOMAINS_FILE" >&2
  exit 1
fi

# Default-deny baseline (also covers AI-provider APIs). Everything else is added
# explicitly below; nothing not listed in the allowlist can leave the sandbox.
echo "Setting default policy to 'balanced' (default-deny + AI-provider baseline)..."
sbx policy set-default balanced

echo "Allowing domains from $DOMAINS_FILE ..."
while read -r line; do
  domain="${line%%#*}"                       # strip trailing comments
  domain="$(echo "$domain" | tr -d '[:space:]')"
  [[ -z "$domain" ]] && continue
  echo "  allow $domain"
  sbx policy allow network "$domain" ${SANDBOX_ARGS[@]+"${SANDBOX_ARGS[@]}"}
done < "$DOMAINS_FILE"

echo
echo "Current policy:"
sbx policy ls ${SANDBOX_ARGS[@]+"${SANDBOX_ARGS[@]}"}
echo
echo "Done. Reminder: cloud-provider storage domains must never be added"
echo "(see docs/network-allowlists.md). For enforced (non-overridable) policy,"
echo "use the Docker Admin Console org governance tier."
