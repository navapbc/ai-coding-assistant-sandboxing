# Sandboxing AI Coding Assistants on macOS

> [!WARNING]
> **Experimental — work in progress.** This repo is an early, evolving reference, not a finished standard. Expect breaking changes; feedback and PRs welcome.
>
> **These sandboxing tools are immature and have real limitations.** The mechanisms this repo relies on (Copilot's local sandbox, Docker Sandboxes, Seatbelt profiles, hostname-based egress proxies) are new, changing fast, and **not designed to contain a determined adversary**. Where they help, they raise the cost of an attack rather than remove it — and whether any given config helps *at all* depends on your version, your setup, and bugs neither you nor the vendor have found yet. Treat the configs here as starting points to review and adapt, **not drop-in guarantees**.
>
> **Do not develop a false sense of security.** A sandbox that is enabled is not the same as a sandbox that is working as you assume, and "more secure than nothing" is not a property you can take for granted. **Verify every claim before you rely on it** — against the linked vendor docs *and* by testing the actual behavior on your own machine (see the [egress check](docs/troubleshooting.md#verify-your-egress-is-actually-default-deny) and [threat-model.md](docs/threat-model.md)). Vendor docs can be wrong or out of date, defaults change between versions, and a config that protected you yesterday may silently stop doing so after an update. Assume nothing is enforced until you have watched it block something.

**Status:** experimental · last reviewed 2026-06-13

Guides and runnable configurations for using **Claude Code**, **OpenAI Codex**, and **GitHub Copilot** safely on developer Macs in an environment that handles sensitive beneficiary data. The goal: an agent that is compromised by prompt injection **cannot read host secrets and cannot exfiltrate data** — while staying pleasant enough to use that nobody routes around it.

## The model in one paragraph

We do not try to predict what commands an agent will run. We **contain** what any command can touch: the filesystem is scoped to the workspace, network egress is **default-deny** against a short, code-reviewed domain allowlist, and a handful of outward-acting commands (`git push`, `gh pr create`, `npm publish`) keep a human approval step. Everything else runs without prompts, because the OS-enforced boundary — not a permission dialog — is what protects you. Anthropic measured ~84% fewer permission prompts under this model while containing a deliberately compromised agent.

## Three tiers

| Tier | What | Covers | Start here |
|------|------|--------|------------|
| **1 — Hardened built-ins** | Each tool's own OS-level sandbox, configured tight | Claude Code (CLI + IDEs), Codex (CLI + VS Code), Copilot CLI (preview) | [claude-code](docs/claude-code.md) · [codex](docs/codex.md) · [copilot](docs/copilot.md) |
| **2 — Universal isolation** | Devcontainer with default-deny firewall, the `srt` wrapper, or Docker Sandboxes (`sbx`) for the Docker-licensed subset | **All three tools**, including the gaps (Copilot in JetBrains) | [devcontainer](docs/devcontainer.md) · [srt](docs/universal-sandbox-srt.md) · [docker-sandbox](docs/docker-sandbox.md) |
| **3 — Org enforcement** | MDM-deployed managed settings that developers can't override | Fleet-wide | [enforcement](docs/enforcement.md) |

Tiers compose: a developer on Tier 1 today is protected; Tier 3 makes sure it stays on; Tier 2 covers the tools and IDE surfaces that have no built-in story.

> [!WARNING]
> **Secrets in your shell environment defeat the sandbox.** The OS sandboxes confine the filesystem and network but **not environment variables** — a `GITHUB_TOKEN` (or AWS key) exported in your `~/.zshrc` is inherited by every command the agent runs, sandbox or not. Don't put tokens in dotfiles or the environment. Use a repo-scoped, least-privilege credential kept in a credential store: **[Git credentials guide](docs/git-credentials.md)**.

## Platform support

| Mechanism | Supported on |
|-----------|--------------|
| Seatbelt built-ins (`/sandbox`, Codex, `srt`, `agent.sb`) | macOS 13+ (Ventura and later), Apple Silicon and Intel |
| Docker Sandboxes (`sbx`) | macOS per Docker's requirements (recent macOS, Apple Silicon) — verify your version |
| Devcontainer | any Docker-compatible runtime (Colima, Docker Desktop, …) |

Two caveats worth knowing: Apple has **deprecated `sandbox-exec`** (still shipped and used by Codex/Chrome, but a long-term risk — the `srt` and built-in tiers don't depend on the CLI), and **native Windows isn't covered** by these built-in sandboxes (Claude Code needs WSL2). This repo targets an all-macOS fleet.

## Quick install (one prompt + restart)

From inside Claude Code or Codex — or any coding agent with a terminal — paste this prompt:

> Clone `navapbc/ai-coding-assistant-sandboxing` with `gh repo clone`, then run `./setup.sh` from the checkout and tell me which tools to restart.

The agent clones the repo, runs the installer, and reports back; you restart the tool and you're done. `setup.sh` detects which tools you have, installs the user-level baselines from `configs/`, and prints what to restart. Run `./setup.sh --dry-run` first to preview, and re-run after a `git pull` to update.

The installer configures **Claude Code and Codex**. **Copilot is not file-configured** — there's nothing safe to write unattended, so `setup.sh` only prints guidance. Enable Copilot's sandbox separately: `/sandbox enable` per session in the CLI, or the VS Code terminal-sandbox setting — see [Manual setup](#manual-setup-per-tool) and [copilot.md](docs/copilot.md).

> [!IMPORTANT]
> **That baseline is not default-deny egress on its own** — `allowedDomains` in user settings only *pre-allows* (skips prompts); an auto-allowed agent can still reach unlisted domains. For **host-level default-deny** (what most solo devs want), run `./setup.sh --managed` **yourself in a terminal** afterward — it deploys the strict managed policy (Claude Code + Codex) and needs `sudo`, so the agent above can't do it. Verify with the [egress check](docs/troubleshooting.md#verify-your-egress-is-actually-default-deny) (`cms.gov` must fail). Details: [Single machine](docs/enforcement.md#single-machine-solo-developer-no-mdm). Prefer not to touch system files? The [devcontainer](docs/devcontainer.md) tier is default-deny without it.

It never destroys an existing config. For Claude Code's JSON it **deep-merges** the baseline into your file (our security keys win on conflicts, lists are unioned, your other settings are preserved), shows a **diff**, and **asks before writing — defaulting to no**, backing up the original first; `--yes` applies without prompting. For Codex's TOML there's no safe automatic merge, so an existing config is **left completely untouched** — the installer drops a `config.toml.sandbox-baseline` sidecar and shows which keys to add. Real Codex enforcement comes from MDM-deployed `requirements.toml` ([enforcement](docs/enforcement.md)), not from editing each developer's `config.toml`.

Two design notes so this stays robust:

- **Private repo:** `gh repo clone` uses the developer's existing GitHub auth, so a private repo just works — no special handling, and only authorized people can pull it.
- **No URL in the flow:** the slug above is the *only* reference to the repo's location, and it lives in this one place. Once cloned, `setup.sh` installs from the files next to it and never refers back to where it came from — so the repo moving (or being renamed; `gh` follows GitHub's rename redirects) doesn't break anything.

## Manual setup (per tool)

- **Claude Code** → run `/sandbox`, then copy [`configs/claude-code/settings.user.json`](configs/claude-code/settings.user.json) to `~/.claude/settings.json`. Done in 5 minutes. **For host-level default-deny egress (most solo devs want this), also run `./setup.sh --managed`** — the user baseline alone is *not* default-deny ([why & how](docs/enforcement.md#single-machine-solo-developer-no-mdm)). [Guide](docs/claude-code.md)
- **Codex CLI** → copy [`configs/codex/config.toml`](configs/codex/config.toml) to `~/.codex/config.toml`. [Guide](docs/codex.md)
- **Copilot CLI** → run `/sandbox enable` in a session (public preview); for VS Code set [`configs/copilot/vscode-settings.json`](configs/copilot/vscode-settings.json). **Copilot agent mode in JetBrains has no sandbox — use the [devcontainer](docs/devcontainer.md).** [Guide](docs/copilot.md)
- **Any tool, any IDE — strongest isolation** → the [devcontainer](docs/devcontainer.md) ([`configs/devcontainer/`](configs/devcontainer/)): a **~10-minute [quick start](docs/devcontainer.md#quick-start-10-minutes--mostly-the-one-time-image-build)** to a sandboxed agent in VS Code or JetBrains — the whole process behind default-deny egress. Or — if you have Docker — [Docker Sandboxes](docs/docker-sandbox.md) (`sbx`), the preferred Tier 2 for that subset.

## Documentation map

**Most developers need only two things: the [Quick install](#quick-install-one-prompt--restart) above and their tool's guide ([Claude Code](docs/claude-code.md) · [Codex](docs/codex.md) · [Copilot](docs/copilot.md)).** Everything below is reference — reach for it when you hit a wall or you're on the platform/security team.

| Doc | Read it when |
|-----|--------------|
| [threat-model.md](docs/threat-model.md) | You want to know exactly what we're defending against — and what sandboxing does *not* solve |
| [claude-code.md](docs/claude-code.md) | Setting up Claude Code's built-in sandbox (CLI, VS Code, JetBrains) |
| [codex.md](docs/codex.md) | Setting up Codex's sandbox modes and permission profiles |
| [copilot.md](docs/copilot.md) | Copilot CLI/VS Code sandboxing and the JetBrains gap |
| [universal-sandbox-srt.md](docs/universal-sandbox-srt.md) | Wrapping *any* CLI in a Seatbelt + filtering-proxy sandbox (`srt`), plus our raw `sandbox-exec` fallback |
| [devcontainer.md](docs/devcontainer.md) | Running agents in a container with a default-deny egress firewall |
| [docker-sandbox.md](docs/docker-sandbox.md) | Docker Sandboxes (`sbx`) — microVM + hostname-filtering proxy, for the Docker-licensed subset |
| [git-credentials.md](docs/git-credentials.md) | Storing least-privilege GitHub tokens on macOS (1Password / Keychain) — and keeping them out of your shell environment |
| [agent-git.md](docs/agent-git.md) | How an agent commits/branches in each tier, the monorepo `.git`-in-workspace fix, and how push is gated — consistently across tools |
| [network-allowlists.md](docs/network-allowlists.md) | The full domain reference: what's allowed, what's never allowed, and why |
| [enforcement.md](docs/enforcement.md) | Platform team: MDM, managed settings, config precedence, defense-in-depth layering |
| [policy-matrix.md](docs/policy-matrix.md) | The one-page approved / not-approved matrix per tool and surface |
| [troubleshooting.md](docs/troubleshooting.md) | Something was blocked, or a tool fails inside the sandbox |

## Principles

1. **Default-deny egress, everywhere.** There is no deny list — anything not on the short allowlist is blocked. Cloud-provider storage domains (`*.amazonaws.com`, `*.googleapis.com`, `*.blob.core.windows.net`, …) are **never** allowlisted: they are multi-tenant endpoints where an attacker controls a bucket.
2. **Contain, don't enumerate.** No command allowlisting. The bet is that the sandbox boundary — not a list of approved commands — is what limits the blast radius, so commands run freely *within* it; only boundary-piercing (`docker`) and outward-acting (`git push`) commands keep a human in the loop. How much that contains depends on the boundary actually holding — see principle 4.
3. **Fast unblock or it doesn't survive.** Allowlist changes are a one-line, code-reviewed PR — hours, not tickets. A slow exception process is how developers end up disabling security tools.
4. **Honest about residual risk.** The built-in proxies filter by hostname without inspecting TLS (Docker Sandboxes is the exception — it TLS-terminates); `github.com` is itself multi-tenant. See [threat-model.md](docs/threat-model.md) before treating any of this as absolute.
