# Devcontainer: Uniform Isolation with Default-Deny Egress

The container tier puts the **entire agent process** — not just its shell commands — behind one boundary, with default-deny egress (a hostname-filtering proxy by default; an IP firewall as the validated fallback). It is the only approach that covers all three tools identically, and the sanctioned way to run **Copilot agent mode in JetBrains** (which has no native sandbox).

Based on Anthropic's reference implementation ([anthropics/claude-code/.devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer)), extended to bundle all three CLIs and bake in our managed policy.

> **If you have Docker, prefer [Docker Sandboxes (`sbx`)](docker-sandbox.md) instead.** It delivers the same whole-process containment with a stronger boundary (microVM) and tighter egress control (TLS-*terminating* hostname filtering vs. this tier's non-terminating CONNECT proxy / IP firewall). This hand-rolled devcontainer remains the option when Docker isn't available, or when you specifically want the VS Code/JetBrains devcontainer IDE-backend experience.

## What you get

- All three CLIs (`claude`, `codex`, `copilot`) installed in an Ubuntu container; the agent, its MCP servers, hooks — everything — runs inside.
- **Default-deny egress**: the shipped default is a hostname-filtering **CONNECT proxy** (`EGRESS_MODE=proxy`, [details](../configs/devcontainer/egress-proxy/README.md)); the validated fallback is an **IP firewall** (`init-firewall.sh` resolves `allowed-domains.txt` to IPs + GitHub ranges, `DROP` policy). Either mode **self-tests** at start (must reach `api.github.com`, must fail `example.com`) and refuses to run if egress isn't actually contained.
- Managed policy baked into the image (`/etc/claude-code/managed-settings.json`, `/etc/codex/requirements.toml`) — not overridable from inside.
- Host filesystem exposure limited to the bind-mounted workspace. Your `~/.ssh`, keychain, and shell env never enter the container.
- Auto-approval (`claude --dangerously-skip-permissions`, Copilot `--allow-all-tools`) is more defensible here than on the host — **inside this container only** — because the container is the boundary and the non-root user satisfies Claude Code's root check. The blast radius is what the container can reach, not zero.

## Quick start (~10 minutes — mostly the one-time image build)

**Prerequisites:** a container runtime + your IDE.
- **Runtime:** [Colima](https://github.com/abiosoft/colima) (`brew install colima docker && colima start`) — free, no Docker Desktop license; or Docker Desktop.
- **IDE:** VS Code (Dev Containers extension), JetBrains (Gateway → Dev Containers), or the `@devcontainers/cli`.

1. **Copy the devcontainer into your repo:**
   ```bash
   mkdir -p .devcontainer
   cp -r configs/devcontainer/{devcontainer.json,Dockerfile,init-firewall.sh,allowed-domains.txt,egress-proxy} .devcontainer/
   cp configs/claude-code/managed-settings.json .devcontainer/
   cp configs/codex/requirements.toml .devcontainer/
   ```
2. **Trim `allowed-domains.txt`** to the registries your project uses — it is the entire egress policy (changes go through PR review like any code).
3. **Open it in your IDE:**
   - **VS Code:** Command Palette → *Dev Containers: Reopen in Container*.
   - **JetBrains:** Gateway → Dev Containers (runs the IDE backend *inside* the container — this is what contains Copilot agent mode, which has no native sandbox).
   - **CLI:** `npm i -g @devcontainers/cli && devcontainer up --workspace-folder .`
4. **Confirm the egress self-test passed** in the startup log (reaches `api.github.com`, blocked from `example.com`). If it fails, the container refuses to pretend it's protected — see the fallback below.
5. **Pick your assistant and log in** (first run only; credentials persist in named volumes, never on the host):
   Claude Code → `claude` · Codex → `codex login` · Copilot → `copilot` then `/login`.

You're done: the agent — and its MCP servers/hooks — can reach only the allowlisted domains and can't see your host secrets. Auto-approval (`claude --dangerously-skip-permissions`, Copilot `--allow-all-tools`) is safe **inside this container**.

> [!IMPORTANT]
> **Egress mode = CONNECT proxy (experimental).** This devcontainer ships the hostname-filtering [CONNECT proxy](../configs/devcontainer/egress-proxy/README.md) by default (`EGRESS_MODE=proxy`) — no IP drift, robust to ECH. It is **not yet validated on a real build**; step 4's self-test tells you whether it's working. **If the image build fails (installing Envoy) or the self-test fails, fall back to the validated IP firewall:** in `.devcontainer/devcontainer.json` set `"EGRESS_MODE": "ipset"` and `build.args.EGRESS_PROXY` to `"false"`, then rebuild. The IP firewall is the proven path and the rest of this page describes it.

## How the firewall works (and its honest limits)

*This describes the **fallback IP-firewall mode** (`EGRESS_MODE=ipset`). The shipped default is the hostname-filtering [CONNECT proxy](../configs/devcontainer/egress-proxy/README.md) — see the quick-start callout above.*

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

**These trade-offs are why the shipped default is the [CONNECT proxy](../configs/devcontainer/egress-proxy/README.md), not this IP firewall.** The proxy matches by hostname (no drift, no CDN-range over-permit) and is ECH-robust, with an optional TLS-terminating sub-mode that also defeats domain fronting ([residual risk #2](threat-model.md#residual-risks--read-this-before-calling-anything-secure)). Use this IP-firewall mode (`EGRESS_MODE=ipset`) when you want the **simplest, proven, no-MITM** path, or if the (experimental) proxy doesn't come up. Either way, for the strongest egress with the least effort, **[Docker Sandboxes](docker-sandbox.md)** TLS-terminates out of the box.

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
