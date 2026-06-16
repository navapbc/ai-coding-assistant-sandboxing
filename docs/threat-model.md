# Threat Model

What we are defending against, what each control actually does, and — just as important — what none of this solves.

## The scenario

An AI coding agent reads untrusted text constantly: repo files, dependency READMEs, issue threads, web pages, tool output. Any of it can carry a **prompt injection** — instructions that hijack the agent into acting against you. OWASP ranks prompt injection the #1 LLM risk, and it is the dominant agentic failure mode observed in production. Real-world precedent justifies the paranoia: CVE-2025-59532 (Codex CLI agent output could redefine its own sandbox boundary) and CVE-2026-22708 (Cursor: an allowlisted `git branch` command weaponized via a poisoned execution environment).

A hijacked agent on an unprotected workstation has everything its user has. On our machines that could include credentials with privileged access to systems holding beneficiary data. That is the blast radius we are shrinking.

## What the attacker wants (exfiltration targets on a dev Mac)

| Target | Why it matters |
|--------|----------------|
| `~/.ssh/` | Keys to servers and git remotes |
| `~/.aws/`, `~/.config/gcloud/`, `~/.azure/` | Cloud credentials — potentially production access |
| `~/.kube/config` | Cluster credentials |
| `~/.netrc`, `~/.npmrc`, `~/.pypirc`, `~/.gitconfig` | Embedded tokens; publish rights (`.netrc`/`.npmrc`/`.pypirc` are `denyRead`; `.gitconfig` read is intentionally allowed for git identity, with write blocked — don't store tokens there) |
| Environment variables | API keys exported in the shell — inherited by every child process by default |
| macOS Keychain | Stored passwords/tokens — reachable via the `security` CLI over Mach IPC, **not only via file reads** |
| Git credential helpers | `osxkeychain` hands stored credentials to any `git` invocation against an attacker-controlled remote |
| `/var/run/docker.sock` | Access to the Docker socket is effectively host root |

## The two-sided rule

**Filesystem isolation and network isolation are both mandatory. Either alone is exploitable:**

- Filesystem isolation without network control: the agent can't read `~/.ssh`, but it can still POST the contents of your workspace — including any secrets committed or generated there — anywhere on the internet.
- Network control without filesystem isolation: the agent can't reach evil.example, but it can backdoor your `~/.zshrc` or a `$PATH` binary, and the *next* unsandboxed process does the exfiltration.

Every configuration in this repo enforces both sides. When you widen one side (an `allowWrite` path, a new domain, an excluded command), check that it doesn't undo the other.

## Controls and what they enforce

| Control | Boundary | Enforced by |
|---------|----------|-------------|
| Workspace-scoped writes | Commands write only to the project dir + session temp | macOS Seatbelt (kernel) |
| Secret-path read denial | `~/.ssh`, `~/.aws`, etc. unreadable even though broad read is allowed | Seatbelt / tool config (`denyRead`) |
| Default-deny egress | Only allowlisted domains reachable — **but for Claude Code this holds only under the strict posture** (`allowManagedDomainsOnly: true`) or when a human denies the prompt; under the standard posture an auto-allowed/agent session reaches *unlisted* domains unprompted ([decision](enforcement.md#the-strict-vs-standard-domain-decision)). The devcontainer (iptables) and `srt` proxy are unconditional default-deny. | Filtering proxy outside the sandbox (built-in tools, `srt`) or iptables (devcontainer) |
| Sanitized environment | Secrets in your shell env don't reach agent subprocesses | `env -i` in our wrapper (deny-by-default allowlist — fully enforces this); `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` is best-effort only — it strips Anthropic/cloud-provider creds but **not** GitHub PATs (`GITHUB_TOKEN`/`GH_TOKEN`) |
| Human-approval ask-list | `git push`, `gh pr create`, `npm publish`, `docker` prompt before running | Tool permission rules |

A key architectural fact: **macOS Seatbelt cannot filter by domain.** The kernel sees IP addresses and ports, never hostnames. Every serious implementation (Claude Code's `/sandbox`, Codex, `srt`) therefore blocks all direct egress at the kernel and routes traffic through a proxy *outside* the sandbox that enforces the domain allowlist. A tool that ignores the proxy doesn't escape — it simply has no network. Failure is closed.

## Why no cloud-provider domains, ever

`*.amazonaws.com`, `*.googleapis.com`, `*.blob.core.windows.net`, `*.cloudfront.net`, `transfer.sh`, `pastebin.com` — these are multi-tenant: an attacker can stand up a bucket or paste target on the same domain your allowlist trusts. Allowlisting them converts your egress control into a formality. They are excluded from every allowlist in this repo, including entries that appear in vendors' own published lists (e.g. Copilot's Azure-hosted usage-report endpoints, which only matter to admins, not clients).

## Residual risks — read this before calling anything "secure"

1. **Allowed domains are still channels.** `github.com` is multi-tenant too: a hijacked agent with push credentials can exfiltrate to *any* repo or gist. Mitigations: fine-grained PATs scoped to the repos you actually work on, no credential helper inside sandboxes, and the `git push` ask-rule.
2. **Most hostname filtering doesn't inspect TLS.** The built-in proxies (Claude Code, `srt`) allow/deny by client-supplied hostname without terminating TLS, so domain fronting and similar techniques are theoretically available to sophisticated payloads. If your threat model requires it, deploy a TLS-terminating inspection proxy (`sandbox.network.httpProxyPort` in Claude Code points at one) — or use Docker Sandboxes, which TLS-terminates by default.
3. **IP-resolved firewalls drift.** The devcontainer firewall resolves domains to IPs at start; CDN rotation can break (or, with broad ranges, over-permit) later. Hostname-aware filtering doesn't drift — the built-in proxy tiers and **Docker Sandboxes** (which TLS-*terminates*) already match by hostname, and the devcontainer ships an experimental opt-in [CONNECT-proxy egress mode](../configs/devcontainer/egress-proxy/README.md) (Envoy explicit forward proxy, hostname-matched, no IP resolution — and robust to ECH, since the destination is the cleartext `CONNECT` host) for teams that want the same on the container tier. It still doesn't defeat domain fronting (see #2) — the inner `Host` can differ on a shared CDN, which only TLS termination catches — so the default IP firewall trades hostname precision for simple, uniform, no-MITM coverage.
4. **The agent process itself runs outside the Bash sandbox.** For Claude Code and Codex, the built-in sandbox confines *shell commands the agent runs*, not the agent binary, its MCP servers, or its hooks. MCP servers run with your user's full privileges — **treat adding an MCP server like adding a production dependency**. The devcontainer is the tier that puts the entire process inside the boundary.
5. **`excludedCommands` is a hole in the wall.** Anything listed there runs unsandboxed. Keep the list empty or near-empty, managed-controlled, and code-reviewed.
6. **Unix sockets pierce the boundary.** Never allow `/var/run/docker.sock` or similar through `allowUnixSockets`.
7. **DNS can be an exfil channel the IP allowlist doesn't see — handled in layers in the devcontainer tier.** An IP-enforced domain allowlist doesn't inspect DNS, so DNS tunneling (smuggling data in subdomain lookups resolved to an attacker's authoritative nameserver) is a classic channel. `init-firewall.sh` addresses it in two layers: **Layer 1 (default)** pins DNS egress to the container's configured resolver(s), which blocks talking straight to an arbitrary resolver but *not* recursive tunneling through an allowed one; **Layer 2 (`ENABLE_DNS_ALLOWLIST=true`, opt-in)** runs a local dnsmasq that resolves only allowlisted domains and refuses the rest, which *does* close recursive tunneling. Layer 2 is a currently **untested** reference — validate resolution before relying on it. The built-in proxy tiers (Claude Code, `srt`) avoid the hole entirely (the sandboxed process has no raw network, only the localhost proxy) and Docker Sandboxes blocks UDP outright.
8. **Workspace poisoning — payloads that run *later*, outside the sandbox.** The agent can write to the workspace by design, so it can plant code that executes in a *less*-contained context afterward: a `.git/hooks/` script, a `package.json`/`Makefile`/`npm postinstall` target, a `.vscode`/IDE task, or a CI config. The sandbox contains the agent's *own* run, not what your CI, a teammate, or your IDE does with the resulting files. Mitigations: **review agent diffs** with extra scrutiny on hooks, build scripts, and CI config (the `chat.tools.edits.autoApprove` globs force manual approval on some of these); don't auto-run untrusted post-clone steps; and prefer Docker Sandboxes **`--clone` mode**, which works on a read-only copy rather than your live tree.

## What sandboxing does NOT solve

- **Bad code merged because nobody reviewed it.** Sandboxing constrains the agent's runtime, not the quality or intent of its diffs. Code review remains the control for what lands in `main`.
- **Data already in the workspace.** If beneficiary data sits in the repo the agent works on, the agent can read it — that's its job. Don't point agents at production data; sanitize fixtures.
- **Supply-chain attacks you install on purpose.** `npm install` of a malicious package executes inside the sandbox today, but ships to CI and production later. Registry allowlisting + an internal artifact proxy reduce, not remove, this.
