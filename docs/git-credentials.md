# Git Credentials: Least-Privilege Tokens, Out of Your Environment

A hijacked agent can use whatever `git` can. Two rules shrink that blast radius to almost nothing:

1. **Least privilege** — authenticate with a repo-scoped GitHub **fine-grained PAT**, never a classic or org-wide token.
2. **Never in the environment** — no `export GITHUB_TOKEN`/`GH_TOKEN` in `~/.zshrc`, `~/.zprofile`, `~/.bashrc`, or `.env`, and never a token committed to a repo. Store it in a credential store and let `git`/`gh` fetch it on demand.

> [!WARNING]
> **Why not an env var?** Environment variables are inherited by **every child process** — including the Bash commands your AI agent runs. The OS sandboxes confine the filesystem and network but **not the environment**, so a token exported in your shell is readable by any sandboxed command. This is verified, not theoretical: Claude Code's `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` does **not** catch GitHub PATs, Codex passes the full environment through by default, and Copilot scrubs nothing. A credential store keeps the secret out of that inheritance path entirely. See [threat-model.md](threat-model.md#controls-and-what-they-enforce).

## 1. Mint a least-privilege fine-grained PAT

**GitHub → Settings → Developer settings → Fine-grained tokens.**

- **Resource owner:** your org. **Repository access: Only select repositories** — the ones for this work. Never "All repositories"; never a classic token.
- **Permissions:** `Contents: Read and write` (clone/fetch/push); `Metadata: Read` is added automatically. Add `Pull requests: Read and write` **only** if you open PRs via `gh`/the API.
- **Expiration:** the shortest that's practical, within your org's max-lifetime policy. Rotate. A leaked repo-scoped, short-lived token can at worst push to repos you already work on.
- Your org may **require admin approval** and **SSO authorization** for the token — both are by design.

## 2. Store it — pick one, never the shell

| | **1Password** (recommended) | **macOS Keychain** (fallback) |
|---|---|---|
| Setup | `op plugin init gh` + source `plugins.sh` | `git config --global credential.helper osxkeychain` (native) |
| In env/dotfile? | No — injected only at invocation | No — stored as a Keychain item |
| Central mgmt / rotation / audit | Yes | No (local only) |
| Per-use approval | Biometric prompt (see caveat) | None — any `git` call gets it silently once unlocked |

### Recommended — 1Password

You already have it, and it adds central management, rotation, audit, and a biometric gate.

1. Save the PAT in a 1Password item (e.g. field `token`).
2. `op plugin init gh` — wires the GitHub CLI to read the token from 1Password, injected as `GH_TOKEN` **only when a `gh` command runs**, behind a biometric/system-auth prompt. Nothing lands in a dotfile. Source the generated `~/.config/op/plugins.sh` from your shell rc (that line is config, not a secret).
3. To make plain `git push`/`pull` over HTTPS use the same path, point git at `gh` as its helper:
   ```bash
   git config --global --unset-all credential.helper                       # clear osxkeychain if set
   git config --global credential."https://github.com".helper '!gh auth git-credential'
   ```
   Use the bare `!gh …` form (not the absolute path `gh auth setup-git` writes) so it flows through the 1Password wrapper. Verify with a `git pull` on a private repo. *(This `gh`→`git` bridge is community-documented, not in 1Password's docs — test it on your setup.)*

> **Caveat:** 1Password's biometric prompt is per-use only while the app is locked; within an unlocked window, commands may proceed without a fresh prompt. Still far better than a silently-readable Keychain item — and the token never enters your environment.

### Fallback — macOS Keychain

Native, zero extra tooling:

```bash
git config --global credential.helper osxkeychain
```

The helper ships with Apple Git. On your next `git push`, paste the PAT once; git stores it as an Internet password for `github.com`. No env var, no dotfile — good. The trade-off: once your Keychain is unlocked, **git hands the token to any `git` invocation with no prompt**, including one a hijacked process aims at a different remote. Rule 1 (repo-scoping) is what makes this acceptable rather than dangerous.

## What not to do

- ❌ `export GITHUB_TOKEN=…` / `GH_TOKEN=…` in any shell rc/profile, or a token in `.env`. (See the warning above.)
- ❌ Classic or org-wide PATs — they grant every repo you can touch; a leak is catastrophic.
- ❌ Tokens committed to a repo or written to a tracked file.
- ❌ The `osxkeychain` helper **inside a sandbox** — it hands the token to any `git` call, including one aimed at an attacker's remote. For agent-run git, see the per-tier recipes in [network-allowlists.md](network-allowlists.md#git-credentials-https--scoped-pats).

## SSH? Not the standard here

1Password's SSH agent gives excellent per-use biometric consent, but an SSH key authorizes **every** repo your account can reach (no per-repo scoping), and SSH bypasses the hostname-filtering proxies the sandboxes depend on. We standardize on **HTTPS + fine-grained PATs** for least privilege — see [network-allowlists.md](network-allowlists.md#git-credentials-https--scoped-pats).

## See also

- [network-allowlists.md](network-allowlists.md#git-credentials-https--scoped-pats) — per-tier recipes for when the **agent itself** must run authenticated git inside a sandbox (push from the unsandboxed side, inject a scoped token with `--pass-env`, or Docker Sandboxes' proxy injection where the token never enters the VM).
- [threat-model.md](threat-model.md#residual-risks--read-this-before-calling-anything-secure) — why `github.com` push rights are an exfiltration channel, and why scoping is the control that closes it.
- [troubleshooting.md](troubleshooting.md#opening-a-pr-or-other-github-api-work-when-gh-fails-tls) — `gh pr create` fails TLS under the sandbox (`x509: OSStatus -26276`); use the `curl`/REST route to open the PR instead.

## References (source of truth)

- Fine-grained PATs: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens
- Permissions for fine-grained PATs: https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens
- Org PAT policy / max-lifetime: https://docs.github.com/en/organizations/managing-programmatic-access-to-your-organization/setting-a-personal-access-token-policy-for-your-organization
- Git credential helpers: https://git-scm.com/doc/credential-helpers
- 1Password GitHub CLI shell plugin: https://developer.1password.com/docs/cli/shell-plugins/github/
