#!/usr/bin/env python3
"""Guard against config drift that review is supposed to catch but won't always.

Three invariants, checked across the repo:

1. The secret-path `denyRead` lists are identical everywhere they're declared.
   Canonical source: managed-settings.json. settings.user.json and
   managed-settings.scoped-pat.json must match it exactly; agent.sb must deny
   each path (and must NOT deny ~/.gitconfig, which is intentionally readable).

2. No cloud-provider storage / paste domain appears in any *config* file.
   (Docs name them as forbidden examples, so docs are excluded from this scan.
   The domain manifest names them in its 'rejected' list, so it's excluded too —
   but its *allowed* domains are still checked against the forbidden list.)

3. Every tier's allowlist matches the authoritative manifest
   (configs/allowed-domains.manifest.json). Edit a domain's tiers in the
   manifest, update the per-tier files to match, and this check enforces that
   they agree — no silent drift across the duplicated lists.

Run from the repo root:  python3 scripts/check-config-consistency.py
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "configs", "allowed-domains.manifest.json")

FORBIDDEN = [
    "amazonaws.com", "googleapis.com", "blob.core.windows.net", "azurefd.net",
    "cloudfront.net", "r2.dev", "pastebin.com", "transfer.sh", "file.io",
]


def deny_read(path):
    with open(path) as f:
        return json.load(f)["sandbox"]["filesystem"]["denyRead"]


def net_domains(path):
    """allowedDomains from a Claude Code settings JSON file."""
    with open(path) as f:
        return set(json.load(f)["sandbox"]["network"]["allowedDomains"])


def txt_domains(path):
    """domains from a one-per-line allowlist file (# comments / blanks ignored)."""
    out = set()
    with open(path) as f:
        for ln in f:
            ln = ln.split("#", 1)[0].strip()
            if ln:
                out.add(ln)
    return out


def main():
    problems = []
    cc = os.path.join(ROOT, "configs", "claude-code")

    # --- invariant 1: secret-path lists agree ---
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
            # The manifest legitimately names forbidden domains in its 'rejected'
            # list (like the docs do); its allowed domains are checked in inv. 3.
            if os.path.abspath(path) == os.path.abspath(MANIFEST):
                continue
            text = open(path).read()
            for bad in FORBIDDEN:
                # allow it only on a comment line that explicitly forbids it
                for ln in text.splitlines():
                    if bad in ln and not ln.lstrip().startswith("#"):
                        rel = os.path.relpath(path, ROOT)
                        problems.append(f"{rel}: forbidden domain '{bad}' in: {ln.strip()}")

    # --- invariant 3: per-tier allowlists match the manifest ---
    with open(MANIFEST) as f:
        manifest = json.load(f)

    def expected(tier):
        return set(d["domain"] for d in manifest["domains"] if tier in d["tiers"])

    # the manifest's own allowed domains must not be forbidden
    for d in manifest["domains"]:
        for bad in FORBIDDEN:
            if bad in d["domain"]:
                problems.append(f"manifest: allowed domain '{d['domain']}' matches forbidden '{bad}'")

    tier_files = [
        ("claude-user", net_domains(os.path.join(cc, "settings.user.json"))),
        ("claude-managed", net_domains(os.path.join(cc, "managed-settings.json"))),
        ("claude-managed", net_domains(os.path.join(cc, "managed-settings.scoped-pat.json"))),
        ("devcontainer", txt_domains(os.path.join(ROOT, "configs", "devcontainer", "allowed-domains.txt"))),
    ]
    for tier, actual in tier_files:
        exp = expected(tier)
        if actual != exp:
            missing = sorted(exp - actual)   # in manifest for this tier, missing from the file
            extra = sorted(actual - exp)     # in the file, not assigned to this tier in the manifest
            msg = f"{tier}: allowlist disagrees with the manifest"
            if missing:
                msg += f"\n      missing from file: {missing}"
            if extra:
                msg += f"\n      not in manifest:   {extra}"
            problems.append(msg)

    if problems:
        print("Config consistency FAILED:")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("Config consistency OK: secret lists agree; no forbidden domains; "
          "allowlists match the manifest.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
