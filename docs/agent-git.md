# Agent Git Across the Tiers

For an AI agent to do version control — **commit, branch** — without friction, two conditions must hold in **every** tier. They're the same everywhere; only the knob to satisfy them differs, which is the inconsistency this page exists to flatten.

1. **The repo's `.git` is inside the sandbox's writable scope.** Every tier scopes writes to a *workspace*. Launching the agent in a **monorepo subdirectory** — so `.git` sits at the root, a level up — puts `.git` *outside* that scope and breaks every git write (`commit`, `checkout -b`, any ref lock) with `Operation not permitted`, even though editing files in the subdir works. This is **universal**. Fix: put the **git root** in the writable scope.
2. **Push is controlled.** Push is the real exfiltration concern, so each tier gates it (prompt / deny / approval / scoped credential). Pair any with **repo-scoped fine-grained PATs** ([git-credentials](network-allowlists.md#git-credentials-https--scoped-pats)) so an approved or automatic push can only reach repos you already work on.

## The one rule that makes it consistent

> **Root the agent at the git root, or explicitly add the git root's `.git` to the writable scope.** Then commit/branch work everywhere. **Don't** allowlist individual `.git` subpaths — git writes an operation-dependent set (`MERGE_HEAD`, `rebase-merge/`, `packed-refs`, reflogs, lockfiles, …), so a partial list breaks merge/rebase/gc with cryptic errors. Allow the **whole** `.git`.

## Per-tier matrix

| Tier | Agent commit/branch | `.git` default | Get the git root in scope (monorepo fix) | Push control |
|------|:---:|---|---|---|
| **Claude Code** (CLI + IDE ext) | ✅ | writable | launch at the repo root, or `sandbox.filesystem.allowWrite: ["<root>/.git"]` in personal `settings.local.json` | `git push` ask-prompt |
| **Codex** (CLI + VS Code) | ✅ *(opt-in)* | **read-only by default** | add the root to `writable_roots` **and** a profile rule: `[permissions.<p>.filesystem.":workspace_roots"]` → `".git/" = "write"` | network off in baseline; `--ask-for-approval on-request` prompts on push |
| **Copilot CLI** (`/sandbox enable`) | ✅ | writable | `/add-dir <repo-root>` (or the `/sandbox` Filesystem tab) | `--deny-tool 'shell(git push)'` (hard deny) or the default per-call prompt |
| **Copilot VS Code** (agent mode) | ✅ | writable | `chat.agent.sandbox.fileSystem.mac` → `allowWrite: ["<root>/.git"]` | default-deny egress (push fails unless the host is allowlisted); no per-command prompt |
| **Docker Sandbox** (`sbx`, direct mode) | ✅ | writable (virtiofs RW) | point the **primary workspace at the repo root** — a subdir-only mount means "the agent can't use git at all" | host proxy injects a scoped credential (token never enters the VM); egress deny-by-default |
| **Docker Sandbox** (`--clone`) | ✅ (in-VM clone) | host `.git` read-only | run from the **main checkout**; commits land in the in-VM clone, pulled back via the `sandbox-<name>` git remote | same (credential injection) |
| **Devcontainer** | ✅ | writable (bind mount) | open the repo **root** as the devcontainer workspace | container-local creds + egress firewall |
| **JetBrains + Copilot** | ❌ no host sandbox | — | use the [devcontainer](devcontainer.md) | → devcontainer |

## Codex is the one default-restrictive tier

Codex keeps `.git/` (and `.codex/`, `.agents/`) **read-only by default** even inside writable roots — its anti-tampering stance. Every *other* tier is writable by default, so the agent commits out of the box. To give Codex the same agent-commit behavior, add the explicit permission-profile write rule above; note that adding the repo to `writable_roots` **alone does not** re-enable `.git` writes — you need the per-path `".git/" = "write"` rule. (Verified against the `openai/codex` permission-profile mechanism.) If you don't grant it, the Codex pattern is "agent edits, a human or CI commits."

## Push, consistently

Push is controlled in every tier; the mechanism differs, so match it to your tier and keep it:

- **Prompt / approval:** Claude Code (`git push` ask-rule), Codex (`--ask-for-approval on-request`), Copilot CLI (default per-call prompt).
- **Hard deny:** Copilot CLI `--deny-tool 'shell(git push)'`.
- **Network + credential boundary:** Copilot VS Code (egress default-deny), Docker Sandbox and the devcontainer (egress allowlist + a scoped/injected credential) — a push can only reach an allowlisted host, and only with a repo-scoped token.

Whichever it is, the **repo-scoped fine-grained PAT** is the backstop that bounds a push's blast radius — see [git-credentials](network-allowlists.md#git-credentials-https--scoped-pats).

## A note on friction vs. tampering

Allowing the whole `.git` re-opens one vector: a hijacked agent could plant a `.git/hooks` script or a `.git/config` `credential.helper`/`core.hooksPath` that executes **later, in your unsandboxed shell**. The friction-first stance (recommended) accepts this — it's bounded by push-gating and default-deny egress — and *not* allowlisting `.git` subpaths. If that vector is in your threat model, add `denyWrite` for `…/.git/hooks` and `…/.git/config`, but know the cost: `git config`, `git remote`, `git push -u`/tracking, and hook installers (husky, pre-commit) stop working. Most teams won't want it.

## Per-repo strict vs. machine-wide

Want hard default-deny on *one* repo but normal git/egress elsewhere? **Managed settings are machine-wide** ([enforcement.md](enforcement.md#managed-settings-apply-machine-wide)) — they can't be scoped per-repo. For a single repo, use the [devcontainer](devcontainer.md) (per-project, containerized, default-deny) rather than a machine-wide managed deploy.
