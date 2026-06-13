#!/usr/bin/env bash
# setup.sh — install the AI-agent sandbox baselines for whichever tools are present.
#
# Self-locating: copies the configs that sit next to this script into their
# user-level homes. It NEVER refers to a repo URL, so it works the same no matter
# where the repo lives or whether it's private — clone it once (any way you like),
# then run ./setup.sh from the checkout.
#
# When a config already exists, the installer never destroys your settings:
#   - JSON (Claude Code): deep-merges our baseline into your file (our values win
#     on conflicts, arrays are unioned, your other keys are kept), shows a diff,
#     and asks before writing (default NO). The original is backed up first.
#   - TOML (Codex): there is no safe automatic merge, so an existing file is
#     LEFT UNTOUCHED. We drop a baseline sidecar (config.toml.sandbox-baseline)
#     and show you which keys to add. Enforcement proper comes from MDM-deployed
#     requirements.toml, not from editing each developer's config.toml.
#
# Usage:
#   ./setup.sh [--dry-run] [--yes]
#     --dry-run   show diffs and what would change, write nothing
#     --yes       proceed without prompting (for non-interactive/CI use)
#
# Settings are read at tool startup, so changes apply after you RESTART the tool.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS="${SCRIPT_DIR}/configs"
DRY_RUN=false
ASSUME_YES=false
STAMP="$(date +%Y%m%d-%H%M%S)"
RESTART_NOTES=()
TMPS=()

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y)  ASSUME_YES=true ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

cleanup() { for t in ${TMPS[@]+"${TMPS[@]}"}; do rm -f "$t"; done; }
trap cleanup EXIT

say() { printf '%s\n' "$*"; }

# prompt_yes_no <message> — default NO. Honors --yes; safe when non-interactive.
prompt_yes_no() {
  $ASSUME_YES && return 0
  local ans
  # Probe for a usable controlling terminal without leaking an error if absent.
  if ! (exec </dev/tty) 2>/dev/null; then
    say "  (non-interactive shell; defaulting to NO — re-run with --yes to apply)"
    return 1
  fi
  read -r -p "  $1 [y/N] " ans </dev/tty || return 1
  [[ "$ans" =~ ^[Yy]$ ]]
}

backup() {  # backup <dest>
  say "  backing up $1 -> $1.bak.${STAMP}"
  $DRY_RUN || cp "$1" "$1.bak.${STAMP}"
}

show_diff() {  # show_diff <current> <proposed>
  say "  ---- diff for $1   (your current '-'  vs. baseline/merged '+') ----"
  diff -u "$1" "$2" || true
  say "  ------------------------------------------------"
}

# install_json <src> <dest> — deep-merge (ours wins, arrays unioned), diff, prompt.
install_json() {
  local src="$1" dest="$2"
  if [[ ! -f "$src" ]]; then say "  SKIP (missing in repo): $src"; return; fi
  if [[ ! -f "$dest" ]]; then
    say "  install (new): $dest"
    $DRY_RUN || { mkdir -p "$(dirname "$dest")"; cp "$src" "$dest"; }
    return
  fi
  if cmp -s "$src" "$dest"; then say "  unchanged: $dest"; return; fi

  local merged; merged="$(mktemp -t sandbox-merge)"; TMPS+=("$merged")
  if ! python3 "${SCRIPT_DIR}/.merge-json.py" "$dest" "$src" "$merged" 2>/dev/null; then
    say "  WARN: could not merge $dest (python3/JSON issue); leaving it unchanged."
    say "        Baseline to merge by hand: $src"
    return
  fi
  if cmp -s "$merged" "$dest"; then
    say "  already satisfies the baseline (no merge needed): $dest"; return
  fi

  show_diff "$dest" "$merged"
  if $DRY_RUN; then say "  [dry-run] would prompt to apply this merge (default no)"; return; fi
  if prompt_yes_no "Apply this merge to $dest?"; then
    backup "$dest"
    say "  merged: $dest"
    $DRY_RUN || cp "$merged" "$dest"
  else
    say "  left unchanged: $dest  (baseline at $src)"
  fi
}

# install_advise <src> <dest> — non-mergeable formats (TOML). Install ONLY on a
# fresh machine; never overwrite an existing config. If one exists, leave it
# untouched and drop a baseline sidecar + guidance. No destructive prompt.
install_advise() {
  local src="$1" dest="$2"
  if [[ ! -f "$src" ]]; then say "  SKIP (missing in repo): $src"; return; fi
  if [[ ! -f "$dest" ]]; then
    say "  install (new): $dest"
    $DRY_RUN || { mkdir -p "$(dirname "$dest")"; cp "$src" "$dest"; }
    return
  fi
  if cmp -s "$src" "$dest"; then say "  unchanged: $dest"; return; fi

  local side="${dest}.sandbox-baseline"
  say "  $dest already exists — leaving it UNTOUCHED (no safe automatic TOML merge)."
  show_diff "$dest" "$src"
  if $DRY_RUN; then
    say "  [dry-run] would write the baseline sidecar to $side (your config stays as-is)"
    return
  fi
  cp "$src" "$side"
  say "  wrote baseline sidecar: $side"
  say "  -> review the diff and add the sandbox keys to $dest yourself, or rely on"
  say "     MDM-deployed requirements.toml for enforcement (see docs/enforcement.md)."
}

say "AI-agent sandbox setup  (dry-run: $DRY_RUN, assume-yes: $ASSUME_YES)"
say "Reading configs from: $CONFIGS"
say ""

if ! command -v python3 >/dev/null 2>&1; then
  say "NOTE: python3 not found — JSON merge is unavailable; existing JSON configs"
  say "      will be left unchanged. Install python3 to enable merging."
  say ""
fi

# --- Claude Code (JSON, mergeable) ---------------------------------------
if command -v claude >/dev/null 2>&1; then
  say "Claude Code detected:"
  install_json "${CONFIGS}/claude-code/settings.user.json" "${HOME}/.claude/settings.json"
  RESTART_NOTES+=("Claude Code: quit and relaunch (or 'claude --continue' to resume).")
  say ""
else
  say "Claude Code not found — skipping."; say ""
fi

# --- Codex (TOML, not mergeable here) ------------------------------------
if command -v codex >/dev/null 2>&1; then
  say "Codex detected:"
  install_advise "${CONFIGS}/codex/config.toml" "${HOME}/.codex/config.toml"
  RESTART_NOTES+=("Codex: start a new session to pick up ~/.codex/config.toml.")
  say ""
else
  say "Codex not found — skipping."; say ""
fi

# --- Copilot CLI (guidance only) -----------------------------------------
if command -v copilot >/dev/null 2>&1; then
  say "Copilot CLI detected:"
  say "  No file installed (nothing safe to write unattended)."
  say "  Per session, run: /sandbox enable"
  say "  VS Code users: apply ${CONFIGS}/copilot/vscode-settings.json to your settings."
  say ""
else
  say "Copilot CLI not found — skipping."; say ""
fi

# --- summary -------------------------------------------------------------
if [[ ${#RESTART_NOTES[@]} -eq 0 ]]; then
  say "No supported tools were configured. Install a tool, then re-run ./setup.sh."
  exit 0
fi
say "Done. Files apply on restart:"
for n in "${RESTART_NOTES[@]}"; do say "  - $n"; done
say ""
say "User-level baselines handled. For per-project additions (registries, etc.)"
say "commit the project configs into the repo's .claude/ and .codex/ instead."
$DRY_RUN && say "" && say "(dry-run: nothing was written.)"
