# CLAUDE.md

Guidance for AI agents (and humans) working in this repo. This is a
**documentation + configuration** project — guides and runnable configs for
sandboxing AI coding assistants on macOS. There is no application to build.

## Before you commit

Run the same checks CI runs (all from the repo root):

```bash
python3 scripts/validate-docs.py            # intra-doc links + heading anchors
python3 scripts/check-config-consistency.py # secret-list drift + forbidden domains
bash scripts/test-merge.sh                  # setup.sh JSON deep-merge behavior
find . -name '*.sh' -print0 | xargs -0 -n1 bash -n   # shell syntax
# JSON: python3 -c "import json;json.load(open(F))"  for each configs/**/*.json
# TOML: python3 -c "import tomllib;tomllib.load(open(F,'rb'))" for each *.toml
```

If you edited a `.sb` Seatbelt profile, smoke-test it against **real** `/Users`
paths (not a `mktemp` HOME — `/var/folders` canonicalizes to `/private/var`,
which makes path-based denies look broken when they aren't).

## Layout invariants (don't break these)

- `setup.sh` and `.merge-json.py` live at the **repo root**; `scripts/`,
  `configs/`, `docs/`, `.github/` are directly beneath it. The shell scripts are
  **self-locating** (`SCRIPT_DIR` from `$BASH_SOURCE`) and assume this layout —
  e.g. `configs/docker-sandbox/apply-policy.sh` reads
  `../devcontainer/allowed-domains.txt`.
- `.merge-json.py` and `.github/` are dot-prefixed — easy to miss in a plain
  `ls`. Don't drop them when moving files.

## Rules that protect the security posture

- **Never allowlist cloud-provider storage or paste domains** (`*.amazonaws.com`,
  `*.googleapis.com`, `*.blob.core.windows.net`, `*.cloudfront.net`,
  `pastebin.com`, …). The consistency check enforces this for config files.
- **Secret-path `denyRead` lists must stay identical** across
  `managed-settings.json`, `managed-settings.scoped-pat.json`,
  `settings.user.json`, `agent.sb`, and the `srt` example. Canonical set = the
  14 home-anchored paths in `agent.sb`. `~/.gitconfig` is **deliberately not
  denied** (git needs it for commit identity; its write is already blocked) —
  don't "fix" that. File-*type* denials (`*.key`, vim swap `*.sw[a-p]`) are
  **not** in this canonical list: `denyRead` is literal-path-only (no globs), so
  they live in `permissions.deny` (Claude Code) and as `(regex …)` rules in
  `agent.sb`. Adding a new file type means editing both layers, not `denyRead`.
- **Domain allowlists are duplicated** across several files by format necessity.
  Changing one usually means changing the others; the network-allowlists doc has
  the list of files. Call out cross-file edits in the PR.
- The repo slug appears in exactly **one** place (README "Quick install"). The
  setup flow is otherwise URL-free by design.

## When tools change

The configs encode vendor-specific keys, domains, and behaviors that move. When
bumping a tool version, re-verify against the "source of truth" links at the
bottom of each tool's doc. Bump **"last reviewed"** in the README when you do.

## Tone

This repo is **experimental** and honest about residual risk (see
`docs/threat-model.md`). Prefer accuracy over reassurance; if something is
unverified, say so rather than implying it's guaranteed.
