#!/usr/bin/env bash
# test-merge.sh — verify .merge-json.py deep-merges correctly:
# existing custom keys are kept, our baseline wins on conflicts, arrays union.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

printf '%s' '{"theme":"dark","sandbox":{"enabled":false},"permissions":{"ask":["Bash(terraform apply *)"]}}' \
  > "$tmp/existing.json"

python3 "$ROOT/.merge-json.py" \
  "$tmp/existing.json" \
  "$ROOT/configs/claude-code/settings.user.json" \
  "$tmp/merged.json"

python3 - "$tmp/merged.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["theme"] == "dark", "custom key not preserved"
assert d["sandbox"]["enabled"] is True, "baseline value did not win on conflict"
assert "Bash(terraform apply *)" in d["permissions"]["ask"], "existing array entry lost"
assert "Bash(git push *)" in d["permissions"]["ask"], "baseline array entry not merged in"
print("merge test OK")
PY
