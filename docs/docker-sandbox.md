# Docker Sandboxes (`sbx`): Preferred Tier 2 Where Docker Is Available

For developers who have Docker, **Docker Sandboxes** is the strongest Tier 2 option available — and on two axes it is better than our hand-rolled [devcontainer firewall](devcontainer.md). It runs each agent in a **microVM** (its own kernel, filesystem, and network — a harder boundary than container namespaces), and its built-in host proxy does **TLS-terminating, hostname-level egress filtering** with a default-deny preset. Use it as a drop-in replacement for the devcontainer tier where it's available.

It is **not** the fleet default: it covers the developers who have it installed. The native built-ins (Claude Code, Codex) remain the everyday low-friction path for everyone else.

## Why it's better than the devcontainer firewall

| Concern | Devcontainer (`init-firewall.sh`) | Docker Sandboxes (`sbx`) |
|---------|-----------------------------------|--------------------------|
| Egress filtering | IP-based: `dig` resolves domains to IPs at start → drifts on CDN rotation, over-permits broad ranges | **Hostname-level, TLS-terminating proxy** — genuine layer-7 filtering, no IP drift |
| Isolation boundary | Container namespaces (shared host kernel) | **microVM** — own kernel, own daemon, own network |
| Credential exposure | Token injected into the container env (agent can read it) | **Host proxy injects the auth header; the raw token never enters the VM** |
| Maintenance | You maintain the firewall script + IP logic | Built-in; you maintain only the domain allowlist |

The credential point is the standout: it resolves the [core constraint](network-allowlists.md#the-core-constraint-read-before-choosing-a-recipe) we documented for every other tier. Elsewhere, "anything `git` can read, the agent can read." Here the secret is stored in the host OS keychain and the proxy attaches it to outbound requests matching the right host — so a hijacked agent inside the VM has no token to exfiltrate. (Scope the credential anyway; see [caveats](#caveats-be-honest-in-the-compliance-record).)

## 5-minute setup

Docker Sandboxes ships as a standalone CLI (`sbx`); it does **not** require Docker Desktop (any Docker-compatible runtime works). It is **free for commercial and professional use as of July 2026** — it needs only a **free Docker account** to sign in (`sbx login`), with no per-seat fee, and it is not tied to Docker Desktop licensing. The one thing that is **not** free is the org governance tier ([below](#fleet-enforcement-requires-the-org-governance-tier)) — that's a separate paid subscription. Terms can change; verify against Docker's FAQ: https://docs.docker.com/ai/sandboxes/faq/

```bash
brew install docker/tap/sbx
sbx login

# Store credentials in the host keychain — the proxy injects them; they never enter the VM.
sbx secret set -g anthropic
sbx secret set -g github -t      # paste a repo-scoped fine-grained PAT

# Lock egress to default-deny + our allowlist (see the policy script below).
configs/docker-sandbox/apply-policy.sh

# Run an agent against the current project, in clone mode (recommended — see caveats).
cd ~/my-project
sbx run --clone --name my-task claude     # or: codex, copilot
```

That's a more contained session: microVM isolation, the host filesystem not mounted and the credential kept out of the VM, egress restricted to the allowlist — subject to the [caveats below](#caveats-be-honest-in-the-compliance-record) (TLS interception, `--clone` vs. mount, still-scope-the-token).

## Network policy: default-deny + our allowlist

The proxy listens on the host and is the only way out of the sandbox (it also blocks UDP/ICMP entirely). It has three presets:

- **open** — all outbound allowed (don't use)
- **balanced** — **default-deny with a baseline allowlist for AI-provider APIs** (our base)
- **locked down** — all outbound blocked

[`configs/docker-sandbox/apply-policy.sh`](../configs/docker-sandbox/apply-policy.sh) sets the default to `balanced` and then adds our allowlisted domains via the `sbx policy` CLI, reading the same [`allowed-domains.txt`](../configs/devcontainer/allowed-domains.txt) the devcontainer firewall uses (the shared list for the container-style tiers — see the [sync note](network-allowlists.md#keeping-the-allowlists-in-sync)). Rules accept exact hostnames, wildcard subdomains, an optional `:port`, and CIDR ranges; **deny always wins** over allow. The same never-allowlist rule applies — no cloud-provider storage domains ([why](network-allowlists.md#never-allowlisted--and-why)).

> **Note on the policy store.** We drive policy through the documented `sbx policy` CLI rather than a config file: as of this writing the on-disk format of the *local* policy store isn't documented, so a hand-authored file would be guesswork. The CLI is the supported, stable interface.

## Fleet enforcement requires the org governance tier

By default, `sbx policy` rules are **user-local and the developer can change them** — fine for the trusted subset, but not "enforced." To make the policy non-overridable, you need Docker's **paid org governance subscription**: an org policy set in the Docker **Admin Console → AI governance** becomes *the only policy in effect* (local rules are ignored, deny still wins, changes propagate in ~5 min). That's the analog of managed settings / `requirements.toml` for this tier. See [enforcement.md](enforcement.md) for where it sits relative to the other tiers.

## Caveats (be honest in the compliance record)

- **The governance console is Docker-hosted SaaS, and Docker Sandboxes has no stated FedRAMP/federal authorization.** Before relying on it for federal work, clear the Admin Console / Governance API against your data-residency and authorization requirements. This is the gating question for federal use — settle it first.
- **Use `--clone`, not direct mount, for anything untrusted.** Direct mount edits your working tree live and lets files that execute implicitly during development (git hooks, `Makefile`, `package.json` scripts) affect the host. Clone mode mounts the repo read-only and works on a private copy.
- **TLS interception is how hostname enforcement works.** The proxy is a man-in-the-middle with its own CA that the sandbox trusts — that's what makes layer-7 hostname filtering and credential injection possible (and is *stronger* than the built-in tool proxies, which don't inspect TLS). But certificate-pinned hosts require a bypass mode that skips inspection — document any host you put in bypass as a policy gap. Install internal corporate CAs into the sandbox trust store properly; don't override `SSL_CERT_FILE` (it breaks the credential proxy).
- **Still scope the credential.** Token injection means the raw value doesn't enter the VM, but an injected credential can still authenticate a push to any repo it's authorized for. Keep using a [repo-scoped fine-grained PAT](network-allowlists.md#git-credentials-https--scoped-pats) so the blast radius stays bounded.
- **macOS and Windows at launch; Linux was roadmap.** Fine for this all-macOS fleet; confirm before assuming Linux CI parity.

## References (source of truth)

- Overview: https://docs.docker.com/ai/sandboxes/
- Pricing / licensing FAQ (free for commercial use; paid governance): https://docs.docker.com/ai/sandboxes/faq/
- Get started / CLI / secrets: https://docs.docker.com/ai/sandboxes/get-started/
- Security model (isolation, mounts, credential injection): https://docs.docker.com/ai/sandboxes/security/
- Network policy (presets, `sbx policy`, proxy): https://docs.docker.com/ai/sandboxes/security/policy/
- Org governance (admin-enforced policy, rule syntax, precedence): https://docs.docker.com/ai/sandboxes/security/governance/
- Supported agents: https://docs.docker.com/ai/sandboxes/agents/
- microVM architecture: https://www.docker.com/blog/why-microvms-the-architecture-behind-docker-sandboxes/
