#!/usr/bin/env bash
# apply-policy.sh — set Docker Sandboxes (sbx) egress to deny-all + our allowlist.
#
# We use the 'deny-all' (Locked Down) preset, NOT 'balanced': balanced ships
# Docker's own baseline allowlist, which includes common cloud services such as
# *.blob.core.windows.net — domains this repo never allows. With deny-all, the
# only allow rules are ours plus whatever built-in agent kits add per sandbox
# (inspect those with: sbx policy ls <sandbox> --source kit --type network --wide).
#
# Drives policy through the documented `sbx policy` CLI (the on-disk local policy
# store format is undocumented, so we don't hand-author a file). Reads
# allowed-domains.txt next to this script (tool-level configs keep their own
# copies — see docs/network-allowlists.md "Keeping the allowlists in sync").
#
# Usage:
#   apply-policy.sh [--sandbox NAME] [--domains FILE] [--reset]
#
#   --sandbox NAME   scope the rules to one sandbox (default: global)
#   --domains FILE   allowlist file (default: ./allowed-domains.txt)
#   --reset          run `sbx policy reset` first (asks for confirmation; stops
#                    running sandboxes). Needed to switch an existing install
#                    from another preset, since `sbx policy init` is one-time.
#
# Fleet note: rules set here are USER-LOCAL and developer-changeable. For
# non-overridable enforcement, set an organization policy in the Docker Admin
# Console (AI governance) — see docs/docker-sandbox.md and docs/enforcement.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINS_FILE="${SCRIPT_DIR}/allowed-domains.txt"
SANDBOX_ARGS=()
RESET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sandbox) SANDBOX_ARGS=(--sandbox "$2"); shift 2 ;;
    --domains) DOMAINS_FILE="$2"; shift 2 ;;
    --reset) RESET=true; shift ;;
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

if [[ "$RESET" == true ]]; then
  echo "Resetting the local policy store (sbx will ask to confirm)..."
  sbx policy reset
fi

# Deny-all baseline: nothing leaves the sandbox unless an allow rule below (or a
# kit's per-sandbox rule) permits it. `init` is one-time, so it fails if a preset
# was already chosen (e.g. at `sbx login`). That's fine if it was deny-all; the
# preset check at the end shows which it was.
echo "Initializing global policy to 'deny-all'..."
if ! sbx policy init deny-all; then
  echo "WARNING: 'sbx policy init deny-all' failed — a preset is probably already" >&2
  echo "set. If the preset check below lists allow rules, it isn't deny-all:" >&2
  echo "re-run with --reset." >&2
fi

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
echo "Preset check — rules created by a preset (expect NO allow rules under deny-all):"
sbx policy ls --created-via default --type network --wide
echo
echo "Done. Reminder: cloud-provider storage domains must never be added"
echo "(see docs/network-allowlists.md). For enforced (non-overridable) policy,"
echo "use the Docker Admin Console org governance tier."
