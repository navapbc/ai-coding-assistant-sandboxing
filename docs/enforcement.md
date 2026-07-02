# Enforcement: Making the Policy Stick (Platform/Security Team Guide)

Tier 1 and 2 protect a developer who opts in. This tier makes opting out impossible — or at least loud. The principle: **defaults at the repo and user level, enforcement at the managed level.**

## The defense-in-depth layering

| Layer | File | Who controls | Role |
|-------|------|--------------|------|
| Managed (MDM) | per-tool paths below | Platform team | **Enforcement** — cannot be overridden |
| User | `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.copilot/config.json` | Developer | Personal baseline across all repos |
| Project | `.claude/settings.json`, `.codex/config.toml`, `.devcontainer/` | Team via PR | Per-stack additions (registries), committed and reviewed |
| Local | `.claude/settings.local.json` | Developer | Scratch, not committed |

A hybrid of all layers is the goal: the repo carries reviewed, project-appropriate defaults that work out of the box; the user file covers ad-hoc work outside managed repos; the managed file sets the floor developers can't override (as far as the tool honors it). Claude Code precedence: **managed > CLI args > local > project > user** — and for boolean keys the managed value simply wins, while array keys *merge* across scopes unless locked (below).

## Claude Code

Deploy [`configs/claude-code/managed-settings.json`](../configs/claude-code/managed-settings.json) to:

```
/Library/Application Support/ClaudeCode/managed-settings.json
```

via MDM (Jamf/Kandji/Intune file deployment), root-owned, mode 644. What it enforces:

| Key | Effect |
|-----|--------|
| `sandbox.enabled` + `failIfUnavailable` | Sandbox always on; Claude Code refuses to start if it can't initialize (security gate, not a warning) |
| `allowUnsandboxedCommands: false` | The retry-outside-the-sandbox escape hatch is dead |
| `allowManagedDomainsOnly: true` (shipped default) | **Strict posture:** only the managed `allowedDomains` count, and an unlisted domain **hard-blocks with no prompt** — the only posture that delivers default-deny for an unattended/agent session. Adding a domain is an MDM edit to this file. Set to `false` for the standard posture (per-project PRs + prompts), acceptable only for human-interactive use (see below) |
| `allowManagedReadPathsOnly: true` | Locks filesystem `allowRead` to managed entries — developers cannot widen read access past the secret-path denials. This stays on; it is the secret-path floor |
| `permissions.disableBypassPermissionsMode: "disable"` | `--dangerously-skip-permissions` is unavailable on the host |
| `permissions.ask` (git push, gh pr/repo/release/gist, npm publish, docker) | The outward-acting ask-list. Permission rules merge across scopes (union), so a lower scope can't *remove* an entry — relaxing any of these is a managed-file edit (see [the push relaxation](#relaxing-the-git-push-prompt-after-scoped-pats)) |
| `env`: `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`, `DISABLE_AUTOUPDATER`, telemetry off | Hygiene baked in; updates flow through MDM, not self-update |

### The strict-vs-standard domain decision

The shipped managed file uses the **strict** posture (`allowManagedDomainsOnly: true`, honored from managed settings only): only the managed `allowedDomains` count, and an unlisted domain **hard-blocks with no prompt**. This is the only posture that delivers default-deny for an **unattended or auto-allowed agent** session — exactly this repo's [threat model](threat-model.md). The cost is centralized control: adding a domain (including a per-project registry) is an edit to the managed `allowedDomains` pushed via MDM, not a per-project PR — so keep your MDM turnaround for allowlist additions fast (the same-business-day target at the top of [troubleshooting.md](troubleshooting.md)).

> [!WARNING]
> **Don't relax to the standard posture (`allowManagedDomainsOnly: false`) for agent use.** Standard lets a project add domains via a reviewed one-line PR to its `.claude/settings.json` and turns an unlisted domain into a *prompt* instead of a hard block — convenient, but the prompt is a **human** approval step. In an auto-allowed (`autoAllowBashIfSandboxed: true` — our own baseline) or headless/agent session there is no one to answer it, and we have observed unlisted domains (e.g. `cms.gov`, `example.com`) reaching the network with **no prompt and no block** under standard posture. So standard is acceptable **only** where a human answers every egress prompt; for any unattended/agent/fleet use, keep the shipped strict default. Confirm with the [egress check](troubleshooting.md#verify-your-egress-is-actually-default-deny).

Whichever posture you run, make it a recorded decision rather than a drift, and re-run the egress check after deploying. **Note:** `allowManagedDomainsOnly` is honored *only* from managed settings — a solo developer using just `~/.claude/settings.json` cannot reach strict default-deny from user settings alone. Deploy this managed file (MDM, or `sudo` for a single machine — see below) or use the [devcontainer](devcontainer.md) / `srt` tier, which are unconditional default-deny regardless of posture.

### Managed settings apply machine-wide

The managed file governs **every project on the machine**, non-overridably — there is no per-repo managed scope. This is deliberate (it's the fleet floor), and it has a direct consequence: because `allowManagedDomainsOnly` is managed-only, **hard default-deny egress on the host built-in sandbox *requires* this machine-wide file.** You can't get strict, allowlist-enforced egress in Claude Code's built-in tier any other way — so if that's a hard requirement, keep the managed file; it will (correctly) apply to all your repos.

The collateral that surprises solo devs — and how to keep the hard egress while removing the friction (you don't have to choose):

- **Other repos hit the allowlist.** Every repo is now clamped to the managed `allowedDomains`. Fix: make the allowlist cover what your repos legitimately fetch — add domains to [`configs/allowed-domains.manifest.json`](../configs/allowed-domains.manifest.json) and the managed file (the manifest + `check-config-consistency.py` keep them in sync). The allowlist breadth is the maintenance cost of machine-wide strict; it does **not** require relaxing egress.
- **Monorepo git breaks** (agent launched in a subdir, `.git` a level up). Fix per-repo: add the git root's `.git` to `sandbox.filesystem.allowWrite` in that repo's `.claude/settings.local.json`. Write-allow arrays **merge across scopes** (see the precedence note above), so this takes effect *even under* the machine-wide managed file — no egress change. See [agent-git.md](agent-git.md).

If instead you want hard egress on **only some** repos (not the whole machine), don't use machine-wide managed at all — run those repos in the [devcontainer](devcontainer.md) / Docker Sandboxes / `srt`, which enforce default-deny egress **per project**, in-container, without governing the rest of your machine.

### Single machine (solo developer, no MDM)

This isn't only a fleet concern — **most solo developers want host-level default-deny and have no MDM.** The managed file is still how you get it; just deploy it locally with `sudo` instead of a push. The installer has an opt-in flag:

```bash
./setup.sh --managed
```

That sudo-installs **both** enforcement policies (root-owned, mode 644) — the same files MDM would push:
- Claude Code → `/Library/Application Support/ClaudeCode/managed-settings.json` (strict default-deny egress + `failIfUnavailable`)
- Codex → `/etc/codex/requirements.toml` (the sandbox floor — no `danger-full-access`)

By hand it's:

```bash
sudo mkdir -p "/Library/Application Support/ClaudeCode" /etc/codex
sudo install -m 644 configs/claude-code/managed-settings.json "/Library/Application Support/ClaudeCode/managed-settings.json"
sudo install -m 644 configs/codex/requirements.toml /etc/codex/requirements.toml
```

Restart Claude Code and confirm with the [egress check](troubleshooting.md#verify-your-egress-is-actually-default-deny) (`cms.gov` must fail, `api.github.com` must succeed). Root ownership is the point: a hijacked agent running as you can't edit the policy back. The user-scope baseline from the [5-minute setup](claude-code.md) **cannot** substitute for this — the flag is managed-only. To add a domain later, edit this file's `allowedDomains` (with `sudo`) and restart.

**Known soft spot:** `excludedCommands` (commands that run *unsandboxed*) has no managed-only lock — a developer can append entries in lower scopes. Keep the managed list empty, and treat `excludedCommands` appearing in a repo's `.claude/settings.json` as a code-review flag. Cheap detection: a CI grep over repo settings files for `excludedCommands`, `allowAllUnixSockets`, `enableWeakerNetworkIsolation`.

### Relaxing the git push prompt (after scoped PATs)

The default managed file keeps `Bash(git push *)` on the ask-list because, on a shared `github.com` allowlist entry, a hijacked agent with broad push credentials could push your workspace to an attacker's repo. The prompt is the compensating control for that — and it's the highest-*frequency* friction developers feel.

The principled way to remove it is to **close the channel at the credential layer instead**: issue developers GitHub **fine-grained PATs scoped to the specific repos they work on**, and stop storing broad credentials in the agent's reach. With a repo-scoped PAT, a push to any other repo simply fails authentication — regardless of what the agent was tricked into running — so the prompt is no longer the only thing standing between injection and exfiltration. See [the scoped-PAT setup](network-allowlists.md#git-credentials-https--scoped-pats) for how to provision and store them.

**Precondition, not a shortcut.** Do this only *after* scoped PATs are actually deployed, and even then:

- Keep `gh repo *`, `gh release *`, `gh gist *`, `npm publish *`, and `docker *` on the ask-list — those create new outward destinations a repo-scoped PAT does not constrain.
- Do **not** instead try to allow only `Bash(git push origin *)`. A path/pattern allow is spoofable: an agent can re-point `origin` at another repo first, then push. The scoped *credential* is what makes the push safe; the pattern is not.

When the precondition holds, deploy [`configs/claude-code/managed-settings.scoped-pat.json`](../configs/claude-code/managed-settings.scoped-pat.json) instead of the default `managed-settings.json`. It is byte-identical except that `Bash(git push *)` is dropped from `permissions.ask`. The Codex and Copilot equivalents (drop the `git push` approval rule / the `--deny-tool 'shell(git push)'` flag) follow the same precondition.

## Codex

Deploy [`configs/codex/requirements.toml`](../configs/codex/requirements.toml) — requirements are **non-overridable** by users. Precedence: cloud-managed (ChatGPT Business/Enterprise admin console) > MDM > file.

- **MDM (preferred on macOS):** preference domain `com.openai.codex`, key `requirements_toml_base64` containing `base64 < requirements.toml`. Push as a configuration profile.
- **File fallback:** `/etc/codex/requirements.toml`, root-owned. Single machine without MDM: `./setup.sh --managed` deploys it (see [Single machine](#single-machine-solo-developer-no-mdm)).

Enforced: `danger-full-access` forbidden, approval policy `never` forbidden, web search and browser use disabled. Project `.codex/config.toml` files load only for trusted projects and cannot change model providers/endpoints, so a malicious repo can't redirect Codex traffic.

## Copilot

The youngest enforcement story — be honest about it in your compliance docs:

- **IDE policy:** Copilot agent mode in the IDE can be disabled org-wide from the GitHub org **Policies** page (enterprise AI Controls override org). Use this to turn off agent mode on surfaces you can't sandbox — i.e., JetBrains — while leaving completions on.
- **Local sandbox enforcement** ships via Microsoft Intune/MDM with the June 2026 public preview. Until your MDM supports it and it GA's, the enforceable options are the org-level IDE policy plus the devcontainer.
- **VS Code:** `chat.agent.networkFilter` is an organization-managed setting for domain restriction; the terminal-sandbox setting itself is user-toggleable during preview.

## Devcontainer image policy

Bake enforcement into the image, not the instructions: the [Dockerfile](../configs/devcontainer/Dockerfile) copies `managed-settings.json` to `/etc/claude-code/` and `requirements.toml` to `/etc/codex/` inside the container, so even fully auto-approved agents inside the container operate under the same managed policy. Keep the Dockerfile and these policy files versioned in-repo so every rebuild reproduces the same enforced baseline.

## Measuring efficacy

"Looks deployed" isn't "working." Track a few signals so you know the sandbox is both containing threats and not silently driving people around it:

- **Containment, proven periodically.** Run a scripted **red-team check** (e.g. monthly) from inside an agent session: attempt to read `~/.ssh`/`~/.aws` and to `curl` a canary host you control, and assert both **fail**. This is the audit step below, automated and tracked over time — a green history is your evidence the control is live.
- **Friction, so adoption doesn't erode.** Watch the volume and turnaround of allowlist/exception PRs and break-glass announcements. Rising break-glass use or slow turnaround is the early warning that developers are about to route around the sandbox.
- **Prompt rate.** Claude Code can emit OpenTelemetry metrics (`CLAUDE_CODE_ENABLE_TELEMETRY=1` + `OTEL_*` exporters). A falling permission-prompt rate alongside stable task throughput is the signal the contain-don't-prompt model is paying off; a spike in *blocked-domain* events flags either a missing allowlist entry or an actual exfil attempt worth investigating.

Pick one owner for these; an unmonitored control quietly decays.

## Auditing the floor

Quarterly, per machine class:

1. `defaults read com.openai.codex requirements_toml_base64 | base64 -d` matches the canonical file.
2. `/Library/Application Support/ClaudeCode/managed-settings.json` hash matches.
3. Run the [sandbox verification commands](troubleshooting.md#verifying-your-sandbox) on a sample machine — confirm `~/.ssh` reads and `example.com` fetches fail *from inside an agent session*.
4. CI grep across repos for sandbox-weakening keys (see above).
