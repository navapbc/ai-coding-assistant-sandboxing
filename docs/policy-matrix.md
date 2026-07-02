# Status Matrix: Sandboxing by Tool and Surface

A one-page snapshot of **what sandboxing posture each tool and surface can reach today**, and the configuration that gets it there. This is an **experimental status page, not an approval or authorization** — nothing here is formally "signed off," and (per the [warning in the README](../README.md)) none of it is a guarantee. Read a ✅ as *"a sandbox boundary is **available** for this surface with the linked config, once you've verified it holds on your own machine"* — not as a blessing to skip that check. Surfaces not listed simply haven't been assessed.

**Legend:** ✅ **sandbox available** — a boundary can be configured (link shows how) · ⚠️ **conditional** — only under a stated constraint (container-only, per-session, …) · ❌ **no sandbox** — no boundary available for this surface today, or a mode that removes it.

## Status by surface

| Tool / surface | Status | Configuration / notes |
|----------------|--------|-----------------------|
| Claude Code CLI | ✅ Sandbox available | Sandbox on, auto-allow, [user settings baseline](../configs/claude-code/settings.user.json) + [managed settings](../configs/claude-code/managed-settings.json) ([guide](claude-code.md)) |
| Claude Code in VS Code / JetBrains | ✅ Sandbox available | Same engine, same settings as CLI |
| Claude Code with MCP servers | ⚠️ Conditional | MCP servers run **unsandboxed** on the host → sandbox only in the [devcontainer](devcontainer.md), with each server reviewed like a dependency |
| Codex CLI / VS Code extension | ✅ Sandbox available | `workspace-write`, network off ([config](../configs/codex/config.toml)), [requirements.toml](../configs/codex/requirements.toml) enforced ([guide](codex.md)) |
| Codex `danger-full-access` | ❌ No sandbox | This mode removes the sandbox entirely; pinned off by requirements.toml — don't enable it on host machines |
| Copilot CLI, sandbox enabled | ✅ Sandbox available | `/sandbox enable` each session (preview); deny-tool rules for push/publish ([guide](copilot.md)) |
| Copilot CLI, no sandbox | ❌ No sandbox | To get a boundary: enable the sandbox, wrap in [`srt`](universal-sandbox-srt.md), or use the devcontainer |
| Copilot agent mode, VS Code | ✅ Sandbox available | `chat.tools.terminal.sandbox.enabled: true` ([settings](../configs/copilot/vscode-settings.json)) |
| Copilot agent mode, JetBrains, on host | ❌ **No sandbox** | No OS sandbox exists for this surface. To get a boundary: run the project in the [devcontainer](devcontainer.md) (JetBrains supports it) or use Copilot CLI with sandbox. Org policy can disable IDE agent mode ([enforcement](enforcement.md)) |
| Copilot completions (any IDE) | ✅ Nothing to sandbox | Completions suggest text and execute nothing |
| Copilot coding agent (cloud) | ✅ Sandboxed (cloud-side) | GitHub-side Actions sandbox with default-on firewall; keep "Recommended allowlist" on |
| Docker Sandboxes (`sbx`), Docker-licensed subset | ✅ Sandbox available | `balanced` (default-deny) policy + allowlist, `--clone` mode ([guide](docker-sandbox.md)). Federal gate: clear the Docker-hosted governance SaaS for data residency/authorization before relying on enforced org policy |
| Any other CLI agent / unlisted tool | ❌ Not assessed | Path to a boundary: wrap in [`srt`](universal-sandbox-srt.md) or the devcontainer, then add a row here via PR |
| Unattended / auto-approved agent runs | ⚠️ Conditional | Only inside the [devcontainer](devcontainer.md); never on the host (`disableBypassPermissionsMode` enforces this for Claude Code) |

## Is it sandboxed by default once configured?

A ✅ above means the boundary *can* be turned on; this table answers whether, once you've done the setup, a fresh session is sandboxed **automatically** or still needs a per-session action. Two things decide it: the surface, and the **scope** you put the config at.

| Tool / surface | Default-on after config? | What makes it (not) automatic |
|----------------|--------------------------|-------------------------------|
| Claude Code CLI | ✅ Yes | `sandbox.enabled: true` in **user or managed** settings persists across every session; no per-session step |
| Claude Code VS Code + JetBrains | ✅ Yes | Same engine, same `settings.json` — no IDE-specific exemption |
| Codex CLI | ✅ Yes | `workspace-write` is the default mode; once in `config.toml`/`requirements.toml` it applies every session |
| Codex VS Code extension | ✅ Yes | Same modes apply across Codex local surfaces |
| Copilot CLI | ❌ No — **per-session opt-in** | `/sandbox enable` must be run each session (public preview); off until you run it |
| Copilot agent mode, VS Code | ⚠️ Once the setting is set | `chat.tools.terminal.sandbox.enabled` persists, but it's preview and user-toggleable (no documented MDM lock yet) |
| Copilot agent mode, JetBrains | ❌ Never | No OS sandbox exists for this surface — config cannot turn one on |
| `srt` / `sandbox-exec` wrapper | ⚠️ Only when launched through it | Running the bare CLI bypasses it — not automatic |
| Devcontainer | ✅ While working in the container | But the project must be opened in the container first |
| Docker Sandboxes (`sbx`) | ✅ While running via `sbx run` | Per-session policy is developer-changeable unless an **org governance policy** is set (then it's the only policy in effect) |

Two gotchas behind the table:

1. **Scope decides "default" for the built-ins.** Claude Code is default-on across *all* repos only when `sandbox.enabled` lives in **user** (`~/.claude/settings.json`) or **managed** settings. Selecting a mode from the `/sandbox` panel writes `.claude/settings.local.json` (project-local) — it won't follow the developer to another repo. **Managed** scope (with `failIfUnavailable: true`) is the only one a developer can't switch off; the same logic makes Codex's `requirements.toml` the non-overridable floor versus an editable user `config.toml`. See [enforcement.md](enforcement.md).
2. **Wrapper and container tiers aren't intercepting.** `srt` / `run-sandboxed.sh` protect only the command launched *through* them — nothing stops a bare `claude`/`copilot`. For Claude Code and Codex, managed settings make the protection travel with the tool; the wrapper approaches have no OS-level "always intercept," so in a locked-down setup they have to be the only sanctioned entry point.

Net: **Claude Code and Codex can be genuinely default-on and enforced — including in IntelliJ and VS Code — via managed settings.** Copilot cannot be made default-on across the board today (per-session CLI toggle, no JetBrains sandbox), which is why Copilot-in-IntelliJ routes to the devcontainer and the org-level "disable IDE agent mode" policy covers surfaces you can't sandbox.

## Cross-cutting requirements (all tools)

| Requirement | Where enforced |
|-------------|----------------|
| Default-deny egress; allowlist per [network-allowlists.md](network-allowlists.md) | Tool sandbox config / srt / container firewall |
| No cloud-provider storage domains, ever | Allowlist review; managed domain locks |
| Secret paths unreadable (`~/.ssh`, `~/.aws`, `~/.kube`, keychain, …) | `denyRead` / Seatbelt profile / container boundary |
| Human approval for `git push`, `gh pr create`, `gh repo *`, `npm publish`, `docker` | permissions.ask / approval policy / deny-tool flags. `git push` may be relaxed **only after** repo-scoped PATs are deployed ([how](enforcement.md#relaxing-the-git-push-prompt-after-scoped-pats)) |
| HTTPS + fine-grained PAT scoped to the developer's repos for git (`Contents: read/write`, plus `Pull requests: write` for `gh pr create`); no SSH inside sandboxes | [network-allowlists.md](network-allowlists.md#git-credentials-https--scoped-pats) |
| **Never** put production or sensitive data in an agent workspace | Process/policy — sandboxing **cannot** enforce this; the agent can read anything in its workspace by design, so this is a significant risk it does not mitigate ([threat model](threat-model.md#what-sandboxing-does-not-solve)) |
| Sandbox-weakening keys (`excludedCommands`, `allowAllUnixSockets`, …) flagged in code review | CI grep + review norms ([enforcement](enforcement.md#auditing-the-floor)) |
| Install never destroys existing developer config | [`setup.sh`](../README.md#quick-install-one-prompt--restart): Claude Code JSON is deep-merged (your keys preserved) with a diff + confirm (default no) and a backup; Codex TOML is never overwritten (fresh-install only, else a `.sandbox-baseline` sidecar); Copilot writes nothing. Non-interactive runs default to no |

## Exception process

A ❌ row means there's **no sandbox boundary for that surface today** — so if you need to use it anyway, don't just turn the tool loose. This repo can't "approve" anything for you; what it can offer is a sensible path: (1) write down why you need it, (2) put a compensating control from this repo's tiers in front of it (usually the [devcontainer](devcontainer.md)), (3) get whoever owns security decisions in your org to sign off — that judgment lives with them, not with this repo, and (4) open a PR adding or updating the row so the decision is visible and time-boxed. Re-visit when vendor capabilities change — Copilot's sandbox GA and JetBrains support are the rows most likely to move.
