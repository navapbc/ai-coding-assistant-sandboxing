# `sbx` Cheat Sheet

A quick reference for working with Docker Sandboxes day to day. The reasoning, caveats, and security model live in the [full guide](docker-sandbox.md). Commands were checked against Docker's `sbx` CLI reference as of **v0.45.1** (September 2026). If your installed version behaves differently, `sbx <command> --help` is authoritative. Check yours with `sbx version`.

## One-time setup

```bash
brew trust docker/tap && brew install docker/tap/sbx
sbx login                                   # at the preset prompt, pick "3. Locked Down"
sbx secret set github                       # paste a repo-scoped fine-grained PAT (global by default)
configs/docker-sandbox/apply-policy.sh      # deny-all + this repo's allowlist (--reset to switch presets)
```

Then run the [isolation checks](docker-sandbox.md#verify-the-isolation-is-working) once before trusting it.

## Everyday loop

| Task | Command |
|------|---------|
| Start an agent on this repo (clone mode) | `sbx run --clone --name my-task claude` |
| …on another directory | `sbx run --clone --name my-task claude ~/proj` |
| Reattach later, from anywhere | `sbx run --name my-task` |
| Create without attaching | `sbx create --clone --name my-task claude .` |
| Pass flags to the agent | `sbx run --name my-task claude -- --continue` |
| Pick a model | `sbx run --clone claude -- --model <model>` |
| Two sandboxes, one repo | give each its own `--name` |
| Add one specific extra path, read-only | `sbx run claude . ../api-schemas/openapi:ro` |
| Size it | `sbx run -m 8g --cpus 4 …` |
| List sandboxes | `sbx ls` |
| Shell inside a sandbox | `sbx exec -it my-task bash` |
| Copy files in or out | `sbx cp ./file my-task:/path/` · `sbx cp my-task:/path/file ./` |
| Publish a port | `sbx ports my-task --publish 3000:8080` |

**Extra paths:** everything you mount is readable by the agent and can end up in model context, logs, or a diff. Mount only the specific directory or file the task needs — never your home directory, `~/Documents`, or a broad parent folder like `~/code`.

Agents: `claude`, `codex`, `copilot` (also `cursor`, `gemini`, `opencode`, `shell`, and others). Everything after `--` goes to the agent's own CLI. Leaving the agent doesn't delete anything: the sandbox keeps its state until you remove it.

## Getting work back (clone mode)

```bash
git fetch sandbox-my-task                   # on the host; the sandbox is a git remote
git log HEAD..sandbox-my-task/<branch>      # review before merging
```

Unfetched commits are lost when the sandbox is removed. Fetch (or have the agent push) first.

## Stop and clean up

| Task | Command |
|------|---------|
| Stop (state kept) | `sbx stop my-task` |
| Resume | `sbx run --name my-task` (there's no `sbx start`) |
| Remove one | `sbx rm my-task` (asks; `-f` skips) |
| Remove all stopped | `sbx prune --dry-run`, then `sbx prune` |
| Remove every sandbox | `sbx rm --all` |
| Start over completely | `sbx reset` (deletes **all** sandbox data; `--preserve-secrets` keeps secrets) |

`sbx logout` and `sbx policy reset` both stop running sandboxes.

## Network policy

| Task | Command |
|------|---------|
| What's allowed | `sbx policy ls` · detail: `sbx policy ls --wide` |
| What an agent kit added | `sbx policy ls my-task --source kit --type network --wide` |
| Recent connections and blocks | `sbx policy log` · `sbx policy log my-task --limit 20` |
| Would this host be allowed? | `sbx policy check network api.example.com` |
| Allow for all sandboxes | `sbx policy allow network api.example.com` |
| Allow for one sandbox | `sbx policy allow network --sandbox my-task api.example.com` |
| Block a host | `sbx policy deny network host.example.com` |
| Remove a rule | `sbx policy rm network --resource api.example.com` (add `--sandbox my-task` for scoped rules) |

Wildcards: `*.example.com` matches one subdomain level, `**.example.com` any depth; neither matches `example.com` itself. Rules apply immediately, no restart. Local rules are yours to change, so they're convenience, not enforcement. **Never allow cloud-storage or paste domains** (`*.amazonaws.com`, `*.blob.core.windows.net`, `pastebin.com`, … — [the full list](network-allowlists.md#never-allowlisted--and-why)). Team-wide additions go through a PR to [`allowed-domains.txt`](../configs/docker-sandbox/allowed-domains.txt).

## Secrets and environment variables

| Task | Command |
|------|---------|
| Store a secret (prompt) | `sbx secret set github` |
| From a pipe | `op read "op://Private/GitHub/token" \| sbx secret set github` |
| As a reference (resolved on the host when needed) | `sbx secret set github --ref 'op://Private/GitHub/token'` |
| One sandbox only | `sbx secret set github --sandbox my-task` |
| Move exported keys into the keychain | `sbx secret import` |
| List / remove | `sbx secret ls` · `sbx secret rm github` |
| Non-secret env var | `sbx run -e LOG_LEVEL=debug …` or `--env-file .env.sandbox` |

Secret changes reach existing sandboxes without a restart. Inside the VM the agent only sees a placeholder. Anything passed with `-e` or `--env-file` is readable inside the VM, so never use them for secrets.

## The dashboard (TUI)

Run `sbx` with no arguments (or `sbx tui`) for a terminal dashboard. Sandboxes appear as cards with live status, CPU, and memory.

| Key | Action |
|-----|--------|
| `c` | Create a sandbox |
| `s` | Start or stop the selected sandbox |
| `Enter` | Attach to its agent (same as `sbx run`) |
| `x` | Open a shell in it (same as `sbx exec`) |
| `r` | Remove it |
| `Tab` | Switch between the sandboxes panel and the network panel |
| `?` | Show all shortcuts |

The **network panel** shows connection logs and lets you allow or block hosts and add rules. Those are the same local rules as `sbx policy allow`, so the never-allowlist applies there too.

## When something goes wrong

| Symptom | Try |
|---------|-----|
| `Blocked by network policy … no matching allow rule` | Working as intended. If the host is legitimate and not on the never-list: `sbx policy allow network <host>` (or a PR to the allowlist) |
| `Blocked by org policy` | Your org's governance policy blocked it; ask your admin |
| Agent isn't authenticated | Check `sbx secret ls`. For a Claude subscription, run `/login` inside Claude Code |
| Policy seems wrong after `sbx login` or a reset | Re-run `configs/docker-sandbox/apply-policy.sh`; the table at the end should show only `local` and `kit` rows |
| Anything else odd | `sbx diagnose` · `sbx version` |

## Don't

- Pass tokens on the command line (`sbx secret set -t …`) or with `-e`.
- Allow cloud-storage or paste domains, even "just for now".
- Remove a clone-mode sandbox before fetching its commits.
- Use direct mode (no `--clone`) for untrusted or long-running work ([why](docker-sandbox.md#clone-mode-vs-direct-mount-the-trade-offs)).
