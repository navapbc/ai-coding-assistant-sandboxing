# GitHub Copilot: Sandbox Options and the JetBrains Gap

Copilot's local isolation story is the youngest of the three tools, and it varies sharply by surface. Read the verdicts before the setup steps.

| Surface | OS sandbox? | Verdict |
|---------|-------------|---------|
| Copilot CLI with `/sandbox enable` | ✅ Seatbelt + HTTP proxy (public preview, June 2026) | ✅ Approved with sandbox enabled |
| Copilot CLI without sandbox | ❌ Permission prompts only — shell commands run with your full account | ❌ Not approved for agentic use |
| VS Code agent mode + terminal sandbox setting | ✅ Seatbelt (preview) | ✅ Approved with the setting on |
| VS Code agent mode, setting off | ❌ Approval prompts + workspace trust only | ❌ Not approved |
| **JetBrains (IntelliJ) agent mode** | ❌ **None** — git-worktree isolation is change isolation, not security isolation | ❌ **Not approved on the host. Use the [devcontainer](devcontainer.md).** |
| Copilot coding agent (cloud, assign-an-issue) | ✅ GitHub Actions runners with default-on egress firewall | ✅ Approved (cloud-side; not a local concern) |
| Code completions (non-agentic, all IDEs) | n/a — suggests text, executes nothing | ✅ Approved |

## Copilot CLI: 5-minute setup

1. Inside a `copilot` session, enable the local sandbox (public preview since 2026-06-02; built on Seatbelt plus an HTTP proxy on macOS):

   ```
   /sandbox enable
   ```

2. Keep the tool-permission layer for outward-acting commands. Launch with deny rules rather than blanket allows:

   ```bash
   copilot --deny-tool 'shell(git push)' --deny-tool 'shell(npm publish)'
   ```

   Never use `--allow-all-tools` / `--yolo` outside a devcontainer.

3. Trusted directories persist in `~/.copilot/config.json` (key: `trustedFolders` — example in [`configs/copilot/config.json`](../configs/copilot/config.json)). Only add project workspaces; never your home directory.

Because the sandbox is **opt-in and per-session** during the preview, treat it as a developer habit reinforced by policy, not a guarantee. Enterprise enforcement lands via Microsoft Intune/MDM (see [enforcement.md](enforcement.md)); until your MDM supports it, the devcontainer is the enforceable option for Copilot.

## VS Code agent mode

Apply [`configs/copilot/vscode-settings.json`](../configs/copilot/vscode-settings.json) (User settings, or better, pushed via your VS Code settings management):

- **`chat.tools.terminal.sandbox.enabled: true`** — kernel-level Seatbelt sandbox for agent-executed terminal commands; default scope is read/write the workspace only, all network blocked (preview feature).
- **`chat.tools.edits.autoApprove`** — globs that always require manual approval: `.env*`, key material, `secrets/`, and the AI tools' own config files (an agent must not edit its own policy).
- Organizations can additionally restrict domains via the managed `chat.agent.networkFilter` setting.

**Read restrictions — what you can and can't configure.** Copilot exposes **no per-path read-deny list** (unlike Claude Code's `denyRead` / `permissions.deny` or Codex's permission profiles). What you get:

- **Home-dir secrets are covered automatically.** The terminal sandbox denies file reads under `$HOME`, so `~/.ssh`, `~/.aws`, **`~/.config/sops` (SOPS age keys), and `~/.bash_history`/`~/.zsh_history`** on disk are unreadable to agent-run commands — without any setting.
- **Workspace file-types are not configurable.** There is no knob to deny reading `*.key` or vim swap files (`*.sw[a-p]`) *inside* the workspace, which the sandbox treats as readable. `chat.tools.edits.autoApprove` only gates **edits**, not reads. For OS-level read denial of those types, run Copilot under the [universal `srt` wrapper](universal-sandbox-srt.md) — its Seatbelt profile denies them by regex. This is another reason the wrapper/devcontainer is the enforceable answer for Copilot.

## JetBrains: the gap, plainly

Copilot agent mode in IntelliJ executes on your host with your privileges and offers **no OS-level sandbox**. Its "isolation modes" (git worktree vs. workspace) isolate *changes*, not *capabilities*. Until GitHub ships an equivalent of the VS Code terminal sandbox for JetBrains:

- **Agentic Copilot in IntelliJ is not approved on the host.**
- The sanctioned paths: open the project in the [devcontainer](devcontainer.md) (JetBrains supports devcontainers; the firewall contains everything inside), or use Copilot **CLI** with `/sandbox enable` in a terminal next to the IDE.
- Completions (non-agentic) in IntelliJ remain fine — they execute nothing.

## Network endpoints

Copilot needs `github.com` auth paths, `api.github.com`, `*.githubcopilot.com`, `copilot-proxy.githubusercontent.com`, `origin-tracker.githubusercontent.com`, and `default.exp-tas.com`. We deliberately **exclude** the Azure-hosted usage-report endpoints in GitHub's published list (`usagereports*.blob.core.windows.net`, `copilot-reports-*.b01.azurefd.net`) — they violate the no-cloud-storage rule and are only used by admin reporting. Full tables with sources: [network-allowlists.md](network-allowlists.md).

## Environment variables (no native protection)

Copilot's local sandbox is the **weakest of the three on this axis**: [Codex](codex.md#environment-variables-dont-trust-the-defaults) (with our `inherit = "core"`) is the strictest — a true deny-by-default allowlist — Claude Code's scrub is a partial fixed heuristic, and Copilot scrubs nothing. Seatbelt confines filesystem and network but not the environment, and Copilot adds **no automatic env scrubbing** on either surface — sandboxed terminal commands inherit your full shell environment, including `GITHUB_TOKEN`, `AWS_ACCESS_KEY_ID`, and the like.

- **VS Code agent mode:** **no** env-scrubbing setting exists. The sandbox denies *file* reads under `$HOME` (so `~/.aws/credentials` on disk is protected), but does nothing about the same secret exported as an env var.
- **Copilot CLI:** has an opt-in `--secret-env-vars` flag. By default it only **redacts** `GITHUB_TOKEN`/`COPILOT_GITHUB_TOKEN` *values in its output/logs* — which does not stop a command from reading them. Whether naming additional vars also *strips* them from the command environment (vs. log-redaction only) is documented **inconsistently** by GitHub's own sources, so don't rely on it without testing your installed version.
- **Cloud-provider creds (AWS/GCP/Azure):** not protected by default on either surface.

Net: treat the Copilot local sandbox as **not** protecting secrets held in environment variables. This reinforces the devcontainer recommendation above — and, as everywhere, the durable fix is to not export long-lived secrets into your shell.

## References (source of truth)

- Local/cloud sandboxes changelog: https://github.blog/changelog/2026-06-02-cloud-and-local-sandboxes-for-github-copilot-now-in-public-preview/
- CLI tool permissions: https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/allowing-tools
- CLI configuration: https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/configure-copilot-cli
- VS Code agent security: https://code.visualstudio.com/docs/agents/security
- Copilot allowlist reference: https://docs.github.com/en/copilot/reference/copilot-allowlist-reference
