# Network Allowlists: The Complete Reference

Every domain any of our sandboxes may permit, with purpose and source. **Default-deny is the rule everywhere: this document is exhaustive — if a domain isn't here, it isn't allowed.** There is no deny list, because a deny list can never be complete; protection against over-allowlisting is structural (managed-settings locks, PR review of these files), not enumerative.

Vendors change endpoints; the *Source* links are the authority. Re-verify when bumping tool versions.

## Baseline: AI assistant endpoints

### Anthropic / Claude Code
*Source: https://code.claude.com/docs/en/network-config*

| Domain | Purpose |
|--------|---------|
| `api.anthropic.com` | Claude API inference |
| `claude.ai` | claude.ai account authentication |
| `platform.claude.com` | Anthropic Console authentication |
| `downloads.claude.ai` | Plugin downloads, native installer/updater |
| `raw.githubusercontent.com` | Changelog feed, plugin marketplace metadata |

Deliberately **not** allowlisted: Statsig/Sentry telemetry (disabled via `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`); `storage.googleapis.com` (legacy updater on versions < 2.1.116 — keep tools current instead; it's also a multi-tenant bucket host); `bridge.claudeusercontent.com` (Chrome extension — not used here).

### OpenAI / Codex
*Source: https://developers.openai.com/codex/enterprise/admin-setup*

| Domain | Purpose |
|--------|---------|
| `chatgpt.com` | ChatGPT-account auth and agent traffic (incl. WebSocket over 443) |
| `auth.openai.com` | Authentication flow |
| `api.openai.com` | API-key-based access |

Deliberately **not** allowlisted: `platform.openai.com` (admin console — browser use by admins, not needed by the agent).

### GitHub Copilot
*Source: https://docs.github.com/en/copilot/reference/copilot-allowlist-reference*

| Domain | Purpose |
|--------|---------|
| `github.com` | Auth (`/login/*`), platform |
| `api.github.com` | User/entitlement checks (`/user`, `/copilot_internal/*`) |
| `*.githubcopilot.com` | Completions/chat API (wildcard per GitHub's own reference; covers `api.`, `*.individual.`, `*.business.`, `*.enterprise.`) |
| `copilot-proxy.githubusercontent.com` | Suggestions proxy |
| `origin-tracker.githubusercontent.com` | Service infrastructure |
| `default.exp-tas.com` | Experimentation service |
| `collector.github.com`, `copilot-telemetry.githubusercontent.com` | Telemetry — optional; include only if your Copilot policy requires telemetry |

Deliberately **not** allowlisted despite appearing in GitHub's reference: `usagereports*.blob.core.windows.net`, `copilot-reports-*.b01.azurefd.net` (Azure storage/CDN — multi-tenant cloud hosts, used only for admin usage reporting, never needed by the client).

## Baseline: GitHub for git + `gh` CLI

Exact hosts, no broad wildcards — `*.githubusercontent.com` would sweep in user content, avatars, and pages.

| Domain | Purpose |
|--------|---------|
| `github.com` | git-over-HTTPS, auth, web API redirects |
| `api.github.com` | REST/GraphQL API (`gh`) |
| `codeload.github.com` | Tarball/zipball downloads |
| `objects.githubusercontent.com` | Release assets, LFS objects |
| `raw.githubusercontent.com` | Raw file content |

### Git credentials: HTTPS + scoped PATs

**SSH is not approved inside sandboxes.** `git@github.com` (port 22) and `ssh.github.com:443` bypass hostname-filtering proxies entirely. Use HTTPS remotes with a fine-grained PAT instead.

Scope the PAT to the repositories the developer actually works on — not an org-wide or classic token. This is the control that closes the push-as-exfil channel: `github.com` is multi-tenant, so a token with broad push rights lets a hijacked agent push your workspace to *any* repo on that allowed host ([residual risk](threat-model.md#residual-risks--read-this-before-calling-anything-secure)). A repo-scoped fine-grained PAT makes a push to anywhere else fail authentication, no matter what the agent runs.

Provision the token once:

- **GitHub → Settings → Developer settings → Fine-grained tokens.** Set *Resource owner* to your org, *Repository access* to **Only select repositories** (the ones for this work). Avoid "All repositories" and never use a classic token.
- **Permissions:** `Contents: read/write` (clone, fetch, push). Add `Pull requests: write` if you want `gh pr create` to work — pushing the branch uses Contents, but the API call that opens the PR needs the Pull requests permission, so a contents-only token pushes fine but **fails at PR creation**. Grant only what the workflow needs.
- Prefer short expirations and rotation; a leaked repo-scoped, short-lived token is a far smaller blast radius than a broad one.

#### The core constraint (read before choosing a recipe)

Within a single macOS user account, **anything `git` can read to authenticate, an agent-spawned process can read too.** You cannot both let `git push` work frictionlessly *and* hide the token from a hijacked agent in the same context. So the design choice is **where the credential boundary sits** — and how small the blast radius is when the token does leak. That's why repo-scoping (and ideally short-lived tokens) is non-negotiable: it bounds the worst case to "a push to a repo the developer already works on" instead of "an org-wide credential walked out the door."

Pick the recipe for your tier:

#### Tier 1 — Claude Code / Codex CLI and IDEs: keep the token *out* of the sandbox (recommended, lowest friction)

These sandboxes confine only the **agent's Bash subprocesses** — your own terminal and the IDE's Source Control panel are not sandboxed. So let the agent stage commits and push from the unsandboxed side:

- The developer pushes from a normal shell, or the VS Code / JetBrains git UI, using their existing osxkeychain credentials. The token never enters the agent's reach.
- Friction is near zero: pushing is already a deliberate, human-initiated step (it's on the `git push` ask-list anyway).
- The same boundary covers **`gh pr create`** and authenticated **`fetch`/`pull`/`clone`** of private repos: done outside by default. To have the *agent* do them inside the sandbox, use the scoped-token recipe below — `gh pr create` additionally needs `Pull requests: write` on the PAT and stays on the approval ask-list.
- Nothing to build. This is the default path; reach for the next recipe only when the agent itself must run authenticated git.

#### Tier 2 — agent must run authenticated git inside the sandbox: inject a scoped, short-lived token

Use the explicit pass-through already built into [`run-sandboxed.sh`](../configs/seatbelt/run-sandboxed.sh) (`--pass-env`) or srt's settings — nothing is inherited by default, so the token is present only because you named it:

```bash
# gh as git's credential helper (one-time, on the host):  gh auth setup-git
GH_TOKEN=$(gh auth token) \
  configs/seatbelt/run-sandboxed.sh --allow-net-proxy 8888 --pass-env GH_TOKEN -- <agent-or-command>
```

`git push` inside the sandbox calls `gh`, which reads `GH_TOKEN`. The token is reachable by git in the sandbox — accepted, because it's repo-scoped (a leak can only push to repos already in scope). The strongest form mints a **GitHub App installation token** (auto-expires ~1 hour, scoped to selected repos) per session; the pragmatic form is a fine-grained PAT with a short expiry. It lives in process env for the session only — never written to the host's general credential store.

#### Docker Sandboxes (`sbx`) — the token never enters the sandbox at all

If you're on the [Docker Sandboxes tier](docker-sandbox.md), this is the best of the lot: the credential is stored in the host OS keychain (`sbx secret set -g github -t`) and the **host proxy injects the auth header into matching outbound requests — the raw token never enters the microVM.** A hijacked agent inside the sandbox has no token to read or exfiltrate. Still use a repo-scoped fine-grained PAT: injection protects the secret's *confidentiality*, but an injected credential can still authenticate a push to any repo it's authorized for, so scoping is what bounds the blast radius.

#### Tier 3 — devcontainer: container-local credentials, authenticate once

Store the token in a *container-local* credential store. The [devcontainer.json](../configs/devcontainer/devcontainer.json) already mounts named volumes for the tools' config, so the developer logs in once (`gh auth login` inside the container) and it persists across rebuilds — never touching the host filesystem or keychain. A credential helper inside the container is acceptable here: the container boundary, the default-deny egress firewall, and repo-scoping together mean a leaked token can't even reach a non-allowlisted host to be exfiltrated.

#### Prohibited in every tier

- The **osxkeychain git credential helper inside a sandbox** — it hands the token to any `git` invocation, including one aimed at an attacker remote.
- **Classic or org-wide tokens** — they defeat the scoping that bounds the blast radius.
- Tokens **written into the repo**, into `.env`, or passed in without `--pass-env`.

Once scoped PATs are the norm, the platform team can drop the `git push` approval prompt — see [Relaxing the git push prompt](enforcement.md#relaxing-the-git-push-prompt-after-scoped-pats). The credential scoping is the enabling control; do not relax the prompt without it.

### Enterprise GitHub

The GitHub hosts above assume **public `github.com`**. If your org uses an enterprise GitHub, what you allowlist depends on which kind — and for the devcontainer tier there's an extra step. Add the entries to the same places any GitHub host goes (`allowedDomains`, `allowed-domains.txt`, `sbx policy`); the no-cloud-storage rule still applies.

| Your setup | What to allowlist | Notes |
|------------|-------------------|-------|
| **Enterprise Cloud on `github.com`** (typical GHEC) | Nothing new — the public hosts above are correct | Auth difference only: the fine-grained PAT must be **SSO/SAML-authorized for the enterprise org** ("Configure SSO" on the token). EMU usernames take the `_shortcode` form |
| **Enterprise Server, self-hosted** (your org's GitHub hostname, e.g. `github.agency.gov`) | That hostname; if **subdomain isolation** is enabled, also `render.`, `codeload.`, `uploads.`, `raw.`, `assets.`, `media.<host>` | REST API is `https://<host>/api/v3` — a path on the same host, so the hostname entry covers it. Ask your GHES admin for the exact hostname set. Copilot (via GitHub Connect) still uses `*.githubcopilot.com` |

**Built-in proxy tiers (Claude Code, `srt`) and Docker Sandboxes** filter by hostname, so adding the hostnames above is the whole job.

**Devcontainer tier needs one more change.** `init-firewall.sh` fetches GitHub's published IP ranges from `api.github.com/meta`, which is correct **only for public github.com**. For a self-hosted server, set these env vars (no script edit needed): `SKIP_GITHUB_META=true`, `EXTRA_CIDRS="<your-GHES-server-CIDR>"`, and `VERIFY_REACHABLE_URL="https://<your-host>"` so the self-test checks the right host. See [devcontainer.md](devcontainer.md#how-the-firewall-works-and-its-honest-limits).

## Per-stack: package registries (project-level opt-in)

Add only the stacks the project uses, in the project's config (`.claude/settings.json`, Codex profile, or `.devcontainer/allowed-domains.txt`) — not in the global baseline.

| Stack | Domains |
|-------|---------|
| npm | `registry.npmjs.org` |
| Python | `pypi.org`, `files.pythonhosted.org` |
| Java/Gradle | `repo.maven.apache.org`, `repo1.maven.org`, `services.gradle.org`, `plugins.gradle.org` |
| Go | `proxy.golang.org`, `sum.golang.org` |
| Ruby | `rubygems.org` |
| Rust | `crates.io`, `static.crates.io`, `index.crates.io` |

If the organization runs an internal artifact proxy (Artifactory/Nexus), **prefer it as the single registry endpoint** and drop the public registries from allowlists: one domain, organization-curated packages, and no public-registry publish channel.

## Devcontainer-only: image build and OS packages

Needed during `docker build` / container start, not by the agent at runtime:

| Domain | Purpose |
|--------|---------|
| `mcr.microsoft.com`, `*.data.mcr.microsoft.com` | Devcontainer base images |
| `deb.nodesource.com` | Node.js apt repo (Dockerfile) |
| `deb.debian.org`, `archive.ubuntu.com`, `security.ubuntu.com`, `ports.ubuntu.com` | OS packages |
| `ghcr.io`, `pkg-containers.githubusercontent.com` | GitHub container registry (if used) |
| `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` | Docker Hub (if used) |

## Never allowlisted — and why

These will appear in error messages, tutorials, and even vendor docs. The answer is no:

| Domain pattern | Why refused |
|----------------|-------------|
| `*.amazonaws.com` (S3 etc.) | Attacker-controlled buckets on the same domain — a primary exfiltration channel |
| `*.googleapis.com`, `storage.googleapis.com` | Same: multi-tenant storage |
| `*.blob.core.windows.net`, `*.azurefd.net` | Same: Azure storage/CDN |
| `*.cloudfront.net`, `*.r2.dev` | Generic CDN/storage fronts |
| `pastebin.com`, `transfer.sh`, `file.io`, webhook collectors | Purpose-built data drops |

This is also a deliberate isolation stance: **agent sandboxes get no path to cloud-provider APIs.** Work that legitimately needs AWS/GCP/Azure access happens outside agent sandboxes, with credentials the agent never sees.

## Keeping the allowlists in sync

The allowlist is not yet stored in one place. The domains live in several files by necessity, because each tool reads its own format:

- `configs/devcontainer/allowed-domains.txt` — the shared list for the **container-style tiers** (the devcontainer firewall and Docker Sandboxes' `apply-policy.sh` both read it).
- `configs/claude-code/*.json` (`sandbox.network.allowedDomains`) and `configs/codex/config.toml` — the **built-in-tool tiers** keep their own copies.
- The reference tables in this document.

So a domain change may need to land in more than one file. Until a generator/check enforces it, treat this as a **review checklist item**: when you change one allowlist, confirm whether the others need the same edit, and call it out in the PR. Closing this gap (a single source file that renders the per-tool configs, plus a CI drift check) is a tracked follow-up.

The same applies to the **secret-path `denyRead` lists** (`~/.ssh`, `~/.aws`, `~/.npmrc`, …), which are duplicated across `managed-settings.json`, `settings.user.json`, `agent.sb`, and the `srt` example. The canonical set is the 11 paths in `agent.sb`; keep the others aligned to it. (`~/.gitconfig` is deliberately excluded — see the note in `agent.sb`.)

## Change process

Allowlists are repo-committed, code-reviewed files. To add a domain: one-line PR with a justification line in the PR description (what breaks without it, why the domain isn't multi-tenant storage), one reviewer from the platform/security group, target turnaround same business day. See [troubleshooting.md](troubleshooting.md).
