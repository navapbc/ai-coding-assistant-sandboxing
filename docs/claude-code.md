# Claude Code: Built-in Sandbox

Claude Code ships an OS-level Bash sandbox (Seatbelt on macOS) with a domain-filtering network proxy. It applies identically in the CLI, the VS Code extension, and the JetBrains plugin — the IDE integrations run the same engine with the same settings.

**Status: Approved** on all surfaces with the configuration below. See [policy-matrix.md](policy-matrix.md).

## 5-minute setup

1. In any Claude Code session, run:

   ```
   /sandbox
   ```

   On the **Mode** tab choose **auto-allow** (sandboxed commands run without prompts — the boundary is the control). On macOS there is nothing to install; it uses the built-in Seatbelt framework.

2. Copy the baseline user settings so the sandbox is on for *all* your projects, with secret directories unreadable:

   ```bash
   mkdir -p ~/.claude
   cp configs/claude-code/settings.user.json ~/.claude/settings.json
   ```

   Already have a `~/.claude/settings.json`? Don't overwrite it — run [`setup.sh`](../README.md#quick-install-one-prompt--restart), which deep-merges the baseline in (your keys preserved) and shows a diff before writing, or merge the keys by hand.

3. Verify it's working — ask Claude to run these and watch them fail:

   ```
   Run: cat ~/.ssh/id_ed25519.pub        → blocked (denyRead)
   Run: curl https://example.com         → blocked (domain not allowed)
   Run: npm test                          → runs without a prompt
   ```

## What the baseline config does

[`configs/claude-code/settings.user.json`](../configs/claude-code/settings.user.json):

- **`sandbox.enabled: true`, `autoAllowBashIfSandboxed: true`** — every Bash command runs inside Seatbelt, auto-approved because the boundary contains it.
- **`allowUnsandboxedCommands: false`** — disables the escape hatch where a failed command is retried *outside* the sandbox ("strict sandbox mode").
- **`filesystem.denyRead`** — blocks the credential paths `~/.ssh`, `~/.aws`, `~/.azure`, `~/.config/gcloud`, `~/.kube`, `~/.gnupg`, `~/.netrc`, `~/.npmrc`, `~/.pypirc`, `~/.docker`, `~/Library/Keychains`. **This matters because the sandbox default allows reading your whole disk** — write scope is narrow by default, read scope is not. (`~/.gitconfig` is deliberately *not* on this list: git needs it for commit identity, and its write is already blocked, which is what stops malicious credential-helper injection — just don't store tokens in it.)
- **`network.allowedDomains`** — Anthropic endpoints + the five exact GitHub hosts. Everything else is blocked or prompts, depending on mode. No domains are pre-allowed by the product; this list *is* your egress policy.
- **`permissions.ask`** — `git push`, `gh pr create`, `gh repo`, `npm publish` always prompt, even in auto-allow mode (content-scoped ask rules survive sandboxing). The `git push` prompt can be dropped fleet-wide once repo-scoped PATs are deployed — see [enforcement.md](enforcement.md#relaxing-the-git-push-prompt-after-scoped-pats).
- **`env`** — `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (no Statsig/Sentry telemetry, so those domains never need allowlisting) and `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` (strips credential env vars from subprocesses).

Per-project additions (package registries, dev-server port binding) go in the repo's `.claude/settings.json` — see [`configs/claude-code/settings.json`](../configs/claude-code/settings.json) for a committed example with a tight read scope (`denyRead: ["~/"]`, `allowRead: ["."]`).

## Scope: what the sandbox does and doesn't cover

| Surface | Covered? |
|---------|----------|
| Bash commands + all their child processes | ✅ OS-enforced (Seatbelt) |
| Built-in Read/Edit/Write tools | ⚠️ Permission rules, not OS sandbox — hence the `permissions.deny` Read rules in our config |
| MCP servers | ❌ Run unsandboxed with your user's privileges — treat like production dependencies |
| Hooks | ❌ Run unsandboxed |
| The Claude Code process itself | ❌ Outside the sandbox (it *operates* the sandbox) |

If your project needs MCP servers or you want the whole process contained, use the [devcontainer](devcontainer.md).

## Known compatibility notes

- `docker` can't run inside the sandbox. Don't add it to `excludedCommands` casually — that runs it **unsandboxed**. Prefer the ask-prompt fallback, or do container work in the devcontainer tier.
- `jest` hangs with watchman: use `jest --no-watchman`.
- Go-based CLIs (`gh`, `terraform`) may fail TLS verification under Seatbelt in some setups — see [troubleshooting.md](troubleshooting.md) before reaching for `excludedCommands`.

## For the platform team

Fleet enforcement (sandbox always on, domain list locked, escape hatches disabled) is done with [`configs/claude-code/managed-settings.json`](../configs/claude-code/managed-settings.json) deployed to `/Library/Application Support/ClaudeCode/managed-settings.json` via MDM — covered in [enforcement.md](enforcement.md).

## References (source of truth)

- Sandboxing: https://code.claude.com/docs/en/sandboxing
- Settings reference: https://code.claude.com/docs/en/settings
- Network requirements: https://code.claude.com/docs/en/network-config
- Official example configs: https://github.com/anthropics/claude-code/tree/main/examples/settings
