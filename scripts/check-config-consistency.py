#!/usr/bin/env python3
"""Guard against config drift that review is supposed to catch but won't always.

Two invariants, checked across the repo:

1. The secret-path `denyRead` lists are identical everywhere they're declared.
   Canonical source: managed-settings.json. settings.user.json and
   managed-settings.scoped-pat.json must match it exactly; agent.sb must deny
   each path (and must NOT deny ~/.gitconfig, which is intentionally readable).

2. No cloud-provider storage / paste domain appears in any *config* file.
   (Docs name them as forbidden examples, so docs are excluded from this scan.)

Run from the repo root:  python3 scripts/check-config-consistency.py
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FORBIDDEN = [
    "amazonaws.com", "googleapis.com", "blob.core.windows.net", "azurefd.net",
    "cloudfront.net", "r2.dev", "pastebin.com", "transfer.sh", "file.io",
]


def deny_read(path):
    with open(path) as f:
        return json.load(f)["sandbox"]["filesystem"]["denyRead"]


def main():
    problems = []

    # --- invariant 1: secret-path lists agree ---
    cc = os.path.join(ROOT, "configs", "claude-code")
    canonical = deny_read(os.path.join(cc, "managed-settings.json"))
    for name in ("settings.user.json", "managed-settings.scoped-pat.json"):
        other = deny_read(os.path.join(cc, name))
        if other != canonical:
            problems.append(
                f"{name}: denyRead differs from managed-settings.json\n"
                f"      canonical: {canonical}\n      this file: {other}"
            )

    agent_sb = open(os.path.join(ROOT, "configs", "seatbelt", "agent.sb")).read()
    for p in canonical:
        leaf = p.lstrip("~/")  # e.g. ".ssh", "Library/Keychains"
        if leaf not in agent_sb:
            problems.append(f"agent.sb: canonical secret path '{p}' not denied")
    if re.search(r'"/\.gitconfig"|/\.gitconfig"', agent_sb) and "intentionally NOT denied" not in agent_sb:
        problems.append("agent.sb: ~/.gitconfig appears to be denied (it should be readable)")

    # --- invariant 2: no forbidden domains in config files ---
    for dirpath, _, files in os.walk(os.path.join(ROOT, "configs")):
        for name in files:
            if not name.endswith((".json", ".toml", ".txt")):
                continue
            path = os.path.join(dirpath, name)
            text = open(path).read()
            for bad in FORBIDDEN:
                # allow it only on a comment line that explicitly forbids it
                for ln in text.splitlines():
                    if bad in ln and not ln.lstrip().startswith("#"):
                        rel = os.path.relpath(path, ROOT)
                        problems.append(f"{rel}: forbidden domain '{bad}' in: {ln.strip()}")

    if problems:
        print("Config consistency FAILED:")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("Config consistency OK: secret lists agree; no forbidden domains in configs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
