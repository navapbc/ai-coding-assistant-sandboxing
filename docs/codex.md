# OpenAI Codex: Built-in Sandbox

Codex CLI sandboxes every shell command it executes using macOS Seatbelt (`sandbox-exec` under the hood), with network **off by default** in its standard mode. The same sandbox applies in the Codex VS Code extension.

**Status: Approved** (CLI and VS Code) with the configuration below; `danger-full-access` is **not approved** and is pinned off by enforcement. See [policy-matrix.md](policy-matrix.md).

## 5-minute setup

```bash
mkdir -p ~/.codex
cp configs/codex/config.toml ~/.codex/config.toml
```

**Already have a `~/.codex/config.toml`?** Don't blind-copy over it — that wipes your model provider, profiles, MCP servers, etc. Instead, merge these keys in by hand (the baseline is small — see below), or let [`setup.sh`](../README.md#quick-install-one-prompt--restart) drop a `config.toml.sandbox-baseline` sidecar next to your file so you can diff and copy the keys across. TOML has no safe automatic merge, which is why neither the copy above nor the installer ever overwrites an existing config.

That's it. The baseline gives you:

- **`sandbox_mode = "workspace-write"`** — read access broadly, write access only to the workspace and temp dirs. Codex additionally keeps `.git/`, `.codex/`, and `.agents/` read-only even inside writable roots, so a hijacked command can't rewrite git hooks or the agent's own config.
- **`network_access = false`** — commands Codex runs have *no* network. Codex itself (the agent process) still talks to its API. `npm install` and similar will prompt for approval and run with your consent rather than silently fetching.
- **`approval_policy = "on-request"`** — the agent asks when it needs something outside the sandbox; you stay in the loop exactly where the boundary can't decide for you.

Verify:

```bash
codex exec "run: cat ~/.ssh/id_ed25519.pub"   # the command errors under Seatbelt
codex exec "run: curl https://example.com"     # no network inside the sandbox
```

## Sandbox modes (what's approved)

| Mode | Behavior | Verdict |
|------|----------|---------|
| `read-only` | Inspect only; every change/command needs approval | ✅ Approved (good for code review sessions) |
| `workspace-write` | Workspace+temp writes, network off by default | ✅ Approved — our baseline |
| `danger-full-access` | No sandbox at all | ❌ **Not approved.** Pinned off via `requirements.toml` |

## Domain-level network allowlisting (newer permission profiles)

Codex's newer **permission profiles** replace `sandbox_mode` (configure one system, never both) and add proxy-enforced domain allowlists — the commented block in [`configs/codex/config.toml`](../configs/codex/config.toml) shows a profile that enables network for exactly our allowed registries and GitHub hosts, with deny-wins semantics. Use it when a project genuinely needs sandboxed commands to fetch dependencies without per-command approval; otherwise stay on the simpler `network_access = false` baseline.

⚠️ **macOS caveat:** older Codex releases silently ignored `network_access = true` in the Seatbelt profile ([openai/codex#10390](https://github.com/openai/codex/issues/10390)). Our baseline keeps network off, so the bug can't *weaken* this posture — but if you enable network or profiles, verify against your installed version (`codex --version`, then test that an allowed domain works and a non-allowed one fails).

## Scope: what's covered

Like Claude Code, Codex sandboxes **the commands it runs, not itself**: the CLI process and any MCP servers it spawns run with your user's privileges. Protected-path enforcement, workspace scoping, and the network switch apply to agent-executed shell commands and their children. For whole-process containment, use the [devcontainer](devcontainer.md).

## Environment variables (don't trust the defaults)

Seatbelt confines filesystem and network, **not the environment**. By default Codex passes your **entire shell environment** through to every sandboxed command — `inherit = "all"` with the built-in `*KEY*`/`*SECRET*`/`*TOKEN*` name filter **off** (`ignore_default_excludes = true`). So `GITHUB_TOKEN`, `AWS_ACCESS_KEY_ID`, and anything else you've exported are readable by a hijacked command, sandbox or not.

Codex is, however, the **only** one of the three tools with a native deny-by-default env control: the `[shell_environment_policy]` block. Our baseline sets `inherit = "core"` (rebuild a minimal allowlist — `PATH`, `SHELL`, `TMPDIR`, `HOME`, `LANG`, `USER`, …, the same posture as the seatbelt wrapper's `env -i`) plus `ignore_default_excludes = false` as a belt-and-suspenders name filter. Caveats:

- The name filter is **pattern-based**: it catches `GITHUB_TOKEN`/`GH_TOKEN`/`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` but misses creds without `KEY`/`SECRET`/`TOKEN` in the name (e.g. `GOOGLE_APPLICATION_CREDENTIALS`). `inherit = "core"` is what actually closes that gap.
- These defaults are **verified against the [openai/codex](https://github.com/openai/codex) source**, not the docs — the official config-reference documents the fields but does not publish their default values, and several third-party blogs state them incorrectly (they claim the name filter is on by default; it is not).
- The durable fix is still to **not export long-lived secrets into your shell** in the first place.

## For the platform team

[`configs/codex/requirements.toml`](../configs/codex/requirements.toml) makes the policy non-overridable: `allowed_sandbox_modes` excludes `danger-full-access`, approval policy `never` is forbidden, web search and browser use are disabled. Deploy via MDM (`com.openai.codex` → `requirements_toml_base64`) or `/etc/codex/requirements.toml` — details in [enforcement.md](enforcement.md). Single machine without MDM: `./setup.sh --managed` installs it (alongside the Claude Code policy) — see [Single machine](enforcement.md#single-machine-solo-developer-no-mdm). Project-level `.codex/config.toml` files load only for trusted projects and cannot change model endpoints or providers.

## References (source of truth)

- Sandboxing concepts: https://developers.openai.com/codex/concepts/sandboxing
- Approvals & security: https://developers.openai.com/codex/agent-approvals-security
- Config reference: https://developers.openai.com/codex/config-reference
- Permission profiles: https://developers.openai.com/codex/permissions
- Managed configuration: https://developers.openai.com/codex/enterprise/managed-configuration
