# Enforcement: Making the Policy Stick (Platform/Security Team Guide)

Tier 1 and 2 protect a developer who opts in. This tier makes opting out impossible — or at least loud. The principle: **defaults at the repo and user level, enforcement at the managed level.**

## The defense-in-depth layering

| Layer | File | Who controls | Role |
|-------|------|--------------|------|
| Managed (MDM) | per-tool paths below | Platform team | **Enforcement** — cannot be overridden |
| User | `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.copilot/config.json` | Developer | Personal baseline across all repos |
| Project | `.claude/settings.json`, `.codex/config.toml`, `.devcontainer/` | Team via PR | Per-stack additions (registries), committed and reviewed |
| Local | `.claude/settings.local.json` | Developer | Scratch, not committed |

A hybrid of all layers is the goal: the repo carries reviewed, project-appropriate defaults that work out of the box; the user file covers ad-hoc work outside managed repos; the managed file guarantees the floor. Claude Code precedence: **managed > CLI args > local > project > user** — and for boolean keys the managed value simply wins, while array keys *merge* across scopes unless locked (below).

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
| `allowManagedDomainsOnly: false` (shipped default) | Standard posture: the managed `allowedDomains` are the baseline, and projects can *add* domains via reviewed PRs; anything still unlisted **prompts** the developer rather than silently blocking. Set to `true` to harden into the strict posture (see below) |
| `allowManagedReadPathsOnly: true` | Locks filesystem `allowRead` to managed entries — developers cannot widen read access past the secret-path denials. This stays on; it is the secret-path floor |
| `permissions.disableBypassPermissionsMode: "disable"` | `--dangerously-skip-permissions` is unavailable on the host |
| `permissions.ask` (git push, gh pr/repo/release/gist, npm publish, docker) | The outward-acting ask-list. Permission rules merge across scopes (union), so a lower scope can't *remove* an entry — relaxing any of these is a managed-file edit (see [the push relaxation](#relaxing-the-git-push-prompt-after-scoped-pats)) |
| `env`: `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`, `DISABLE_AUTOUPDATER`, telemetry off | Hygiene baked in; updates flow through MDM, not self-update |

**The strict-vs-standard domain decision.** The shipped managed file uses the **standard** posture (`allowManagedDomainsOnly: false`) deliberately: a developer who hits a not-yet-allowed domain gets a visible, attributable prompt, and a project can add a domain through a reviewed one-line PR to its `.claude/settings.json` — same business day, no MDM cycle. Default-deny is fully preserved — nothing is reachable without either an allowlist entry or an explicit human approval, and those approvals can be logged via OTEL telemetry for monitoring. The **strict** posture (`allowManagedDomainsOnly: true`) removes the per-developer approval entirely: only the managed `allowedDomains` count, every addition — including per-project registries — goes through an MDM push, and unlisted domains hard-block instead of prompting. Start standard; tighten to strict only if monitoring shows approvals being granted that shouldn't be, and budget for the MDM turnaround if you do. Whichever you pick, make it a recorded decision rather than a drift.

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
- **File fallback:** `/etc/codex/requirements.toml`, root-owned.

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
