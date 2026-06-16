# Devcontainer: Uniform Isolation with Default-Deny Egress

The container tier puts the **entire agent process** — not just its shell commands — behind one boundary, with an iptables firewall that drops every packet not destined for the allowlist. It is the only approach that covers all three tools identically, and the sanctioned way to run **Copilot agent mode in JetBrains** (which has no native sandbox).

Based on Anthropic's reference implementation ([anthropics/claude-code/.devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer)), extended to bundle all three CLIs and bake in our managed policy.

> **If you have Docker, prefer [Docker Sandboxes (`sbx`)](docker-sandbox.md) instead.** It delivers the same whole-process containment with a stronger boundary (microVM) and tighter egress control (hostname-level, TLS-terminating proxy vs. this tier's IP-resolved firewall). This hand-rolled devcontainer remains the option when Docker isn't available, or when you specifically want the VS Code/JetBrains devcontainer IDE-backend experience.

## What you get

- All three CLIs (`claude`, `codex`, `copilot`) installed in an Ubuntu container; the agent, its MCP servers, hooks — everything — runs inside.
- **Default-deny egress**: at container start, `init-firewall.sh` resolves the domains in `allowed-domains.txt` to IPs, adds GitHub's published web/api/git ranges, sets `DROP` policies, and **self-tests** (must fail to reach `example.com`, must reach `api.github.com`) before declaring success.
- Managed policy baked into the image (`/etc/claude-code/managed-settings.json`, `/etc/codex/requirements.toml`) — not overridable from inside.
- Host filesystem exposure limited to the bind-mounted workspace. Your `~/.ssh`, keychain, and shell env never enter the container.
- Safe to run agents with auto-approval (`claude --dangerously-skip-permissions`, Copilot `--allow-all-tools`) **inside this container only** — the boundary is the container, and the non-root user satisfies Claude Code's root check.

## Setup

1. **Container runtime.** Any Docker-compatible runtime works. Note Docker Desktop requires a paid license at organizations >250 employees/$10M revenue; **Colima** (`brew install colima docker && colima start`) is the free, scriptable alternative we default to.

2. **Copy the six files into your repo** as `.devcontainer/` (the Dockerfile bakes the last two into the image):

   ```bash
   mkdir -p .devcontainer
   cp -r configs/devcontainer/{devcontainer.json,Dockerfile,init-firewall.sh,allowed-domains.txt,egress-proxy} .devcontainer/
   cp configs/claude-code/managed-settings.json .devcontainer/
   cp configs/codex/requirements.toml .devcontainer/
   ```

3. **Adjust `allowed-domains.txt`** for the project's stack (keep only the registries you use). This file is the project's entire egress policy — changes to it go through PR review like any code.

4. **Open in the container:**
   - VS Code: "Dev Containers: Reopen in Container"
   - IntelliJ/JetBrains: Settings → Dev Containers, or the Gateway; JetBrains' devcontainer support runs the IDE backend inside the container, which is exactly what contains Copilot agent mode
   - CLI only: `devcontainer up --workspace-folder .` (`npm i -g @devcontainers/cli`)

5. **Authenticate the tools inside the container** (first run only; credentials persist in the named volumes, never on the host): `claude` → login flow, `codex login`, `copilot` → `/login`.

Watch the `postStartCommand` output: if the firewall self-test fails, the container refuses to pretend it's protected — fix before working.

## How the firewall works (and its honest limits)

```
allowed-domains.txt ──▶ dig (resolve at start) ──▶ ipset allowed-domains
api.github.com/meta ──▶ GitHub CIDR ranges     ──▶        │
                                                          ▼
                          iptables: OUTPUT policy DROP;
                          ACCEPT only --match-set allowed-domains;
                          REJECT everything else (fail fast, clear error)
```

Trade-offs versus the hostname-filtering proxies of Tier 1, stated plainly:

1. **IP drift.** Domains resolve once at start. A CDN-backed domain that rotates IPs can stop working mid-session — rerun `sudo /usr/local/bin/init-firewall.sh` to re-resolve. (This fails *closed*: drift blocks, never opens.)
2. **Range over-permission.** GitHub's published CIDR ranges allow all of GitHub — consistent with our policy, but remember [the residual risk](threat-model.md#residual-risks--read-this-before-calling-anything-secure): allowed multi-tenant hosts are still exfil channels.
3. **DNS needs its own control (layered here).** The IP-based allowlist doesn't inspect DNS. By default the firewall now pins DNS egress to the container's configured resolver(s) — blocking direct queries to an arbitrary resolver. For full coverage, set `ENABLE_DNS_ALLOWLIST=true` to run a local dnsmasq that resolves only allowlisted domains and refuses the rest, which closes recursive DNS tunneling (opt-in, requires the bundled dnsmasq, currently **untested** — verify resolution first). The built-in proxy tiers and Docker Sandboxes still handle DNS more cleanly ([details](threat-model.md#residual-risks--read-this-before-calling-anything-secure)).

**Want hostname filtering on this tier?** Trade-offs 1–2 are inherent to IP matching. Two ways to get hostname-based egress instead: use **[Docker Sandboxes](docker-sandbox.md)** (TLS-*terminating* hostname filtering — the strongest option, and the preferred Tier 2 where Docker is available), or enable the devcontainer's **experimental, opt-in [SNI-proxy egress mode](../configs/devcontainer/egress-proxy/README.md)** — an Envoy that matches the allowlist by TLS **SNI** (no IP resolution, so no drift), regenerated from the same `allowed-domains.txt`. SNI matching still doesn't defeat domain fronting or ECH ([residual risk #2](threat-model.md#residual-risks--read-this-before-calling-anything-secure)) — only TLS termination does — so the default IP firewall stays the simple, no-MITM baseline.

**Enterprise GitHub caveat.** The `api.github.com/meta` fetch above is correct only for public `github.com`. On a self-hosted GitHub Enterprise Server, run the firewall with `SKIP_GITHUB_META=true`, `EXTRA_CIDRS="<your-server-CIDR>"`, and `VERIFY_REACHABLE_URL="https://<your-host>"` (all read from the environment — no script edit). See [Enterprise GitHub](network-allowlists.md#enterprise-github) for the hostnames to add alongside it.

`docker` inside the container: not available by default, deliberately — mounting the host's Docker socket would hand the container host-level access and void the boundary. If a project truly needs containers-in-container, raise it as an exception (see [policy-matrix.md](policy-matrix.md)).

## When to choose this tier

| Choose devcontainer when… | Stay on Tier 1 built-ins when… |
|---------------------------|--------------------------------|
| Copilot agent mode in JetBrains (mandatory) | Claude Code / Codex CLI day-to-day work |
| Project uses MCP servers or hooks | No MCP, standard workflows |
| Unattended/auto-approved agent runs | Interactive sessions |
| You want one team-standard environment in-repo | Solo or ad-hoc work |

Costs to expect: container startup time, macOS bind-mount I/O overhead on large repos, and maintaining the Dockerfile like any other piece of infrastructure.
