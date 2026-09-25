# Docker Sandboxes (`sbx`): The Recommended Way to Get Started

**If you can run Docker, start here.** Docker Sandboxes is the sandboxing option we recommend reaching for first — ahead of the built-in sandboxes shipped with Claude Code, Codex, and the other AI coding assistants. It runs each agent in a **microVM** (its own kernel, filesystem, and network — a harder boundary than the built-ins' host-level containment or container namespaces), and its built-in host proxy does **TLS-terminating, hostname-level egress filtering** with a default-deny preset. It's tool-agnostic — the same sandbox wraps Claude Code, Codex, and Copilot — so you get one strong boundary instead of a different, weaker one per tool. As with every tier in this repo: it raises the cost of an attack rather than removing it, and it comes with [caveats](#caveats-be-honest-in-the-compliance-record) you should read before relying on it.

Why prefer it over the native built-ins? The built-in sandboxes are convenient because they ship with the tool, but they contain the agent within the *host* OS (a Seatbelt/namespace boundary sharing your kernel) and generally can't keep credentials out of the agent's reach. Docker Sandboxes gives you a genuinely stronger isolation boundary (microVM), true layer-7 egress control, and **keeps the credential out of the VM entirely** — for a few minutes of one-time setup. Reach for a tool's built-in sandbox only when Docker isn't available; see the [Tier 1 built-ins](../README.md#three-tiers) as the fallback path, and the [`srt` wrapper](universal-sandbox-srt.md) when you want one tool-agnostic boundary without Docker.

> **Already set up?** The [`sbx` cheat sheet](sbx-cheatsheet.md) is the one-to-two-page command reference for day-to-day use, including the dashboard (TUI).

## Credentials never enter the VM

This is the standout: it resolves the [core constraint](network-allowlists.md#the-core-constraint-read-before-choosing-a-recipe) we documented for every other tier. Elsewhere, "anything `git` can read, the agent can read." Here the secret is stored in the host OS keychain and the proxy attaches it to outbound requests matching the right host — so a hijacked agent inside the VM has no token to exfiltrate. (Scope the credential anyway; see [caveats](#caveats-be-honest-in-the-compliance-record).)

## Getting started, step by step

Docker Sandboxes ships as a standalone CLI (`sbx`); it does **not** require Docker Desktop (any Docker-compatible runtime works). It is **free for commercial and professional use as of July 2026** — it needs only a **free Docker account** to sign in (`sbx login`), with no per-seat fee, and it is not tied to Docker Desktop licensing. The one thing that is **not** free is the org governance tier ([below](#fleet-enforcement-requires-the-org-governance-tier)) — that's a separate paid subscription. Terms can change; verify against Docker's FAQ: https://docs.docker.com/ai/sandboxes/faq/

Requirements: macOS 14 (Sonoma) or later on Apple silicon. (Windows 11 and Ubuntu 24.04+ are also supported, but this repo targets a macOS fleet.)

1. **Install the CLI:**

   ```bash
   brew trust docker/tap && brew install docker/tap/sbx
   ```

2. **Sign in** — opens a browser for Docker-account OAuth, then asks you to pick a network preset. **Choose `Locked Down`** (deny-all) — `apply-policy.sh` in step 4 then adds only this repo's allowlist. Don't pick `Balanced`: it ships Docker's own baseline allowlist, which includes cloud storage ([why that matters](#network-policy-default-deny--our-allowlist)).

   ```bash
   sbx login
   ```

3. **Store credentials** — service secrets are **global by default** (every sandbox gets them), and adding, updating, or removing one takes effect in existing sandboxes without a restart. To scope one to a single sandbox, add `--sandbox <name>`; a sandbox-scoped secret overrides the global one. Use the prompt, a pipe, or a stored reference so the token never touches your shell history — see [the secrets section below](#secrets-from-the-keychain-or-1password-nothing-in-your-history-or-logs).

   ```bash
   sbx secret set anthropic      # paste at the hidden prompt (skip if you use /login instead)
   sbx secret set github         # paste a repo-scoped fine-grained PAT
   ```

   (Older guides, including earlier versions of this one, write `sbx secret set -g …`. Docker's current CLI reference doesn't list `-g`: global is simply the default.)

4. **Lock egress to default-deny + our allowlist** (details in the [network policy section](#network-policy-default-deny--our-allowlist)):

   ```bash
   configs/docker-sandbox/apply-policy.sh
   ```

5. **Run an agent** against your project, in clone mode (recommended — see [the trade-offs](#clone-mode-vs-direct-mount-the-trade-offs)):

   ```bash
   cd ~/my-project
   sbx run --clone --name my-task claude     # or: codex, copilot
   ```

   `sbx ls` lists your sandboxes; `sbx tui` opens an interactive dashboard for attaching to agents and shells. Day-two commands (stop, resume, remove) are [below](#managing-sandboxes-stop-resume-remove).

6. **Verify the isolation is actually working** — don't skip this. Per the repo's standing rule, assume nothing is enforced until you have watched it block something: [verification commands below](#verify-the-isolation-is-working).

One thing to be clear-eyed about: by default `sbx` launches the agents in their permission-free modes (`claude --dangerously-skip-permissions`, `codex --dangerously-bypass-approvals-and-sandbox`, `copilot --yolo`). That is the [contain-don't-enumerate model](../README.md#principles) working as intended — the microVM boundary and egress policy replace the permission prompts — but it's also exactly why the egress policy, `--clone`, and credential scoping in this guide matter: inside the boundary, nothing else is asking for confirmation.

## Secrets from the Keychain or 1Password (nothing in your history or logs)

Never pass a token as a command-line argument — it lands in your shell history and is visible to other processes via `ps` while the command runs. There *is* a `-t/--token` flag, but Docker's own help text labels it "less secure: visible in shell history" — skip it and use the interactive prompt, a pipe, or a stored reference instead. Good patterns:

**macOS Keychain.** Store the PAT once (the `-w` flag with no value prompts interactively, so the secret never appears on the command line), then pipe it in:

```bash
security add-generic-password -s my-gh-token -a "$USER" -U -w    # prompts for the secret
security find-generic-password -s my-gh-token -w | sbx secret set github
```

**1Password CLI.** Read the field by secret reference and pipe it in (biometric-gated, nothing in history):

```bash
op read "op://Private/GitHub/token" | sbx secret set github
# or, by item and field name:
op item get GitHub --fields token --reveal | sbx secret set github
```

**Or store a reference instead of the value.** With `--ref` (a 1Password `op://` reference or an AWS Secrets Manager ARN) or `--command` (any host command that prints the secret), `sbx` keeps only the *source* and resolves it on the host when the proxy needs it, caching the value for 55 minutes by default (`--refresh` changes that; `--refresh on-demand` resolves on every use). Rotating the token in 1Password then needs no `sbx` step. The `op`/`aws` CLI must be installed and signed in on the host.

```bash
sbx secret set github --ref 'op://Private/GitHub/token'
sbx secret set github --command '/usr/bin/security find-generic-password -s my-gh-token -w'
```

Docker's cautions for `--command`: the command text is stored and replayed, so never embed a secret in it; it runs on the host, unconfined, from a temporary directory, so use an absolute path, and keep the helper (and anything it loads) **outside any workspace a sandbox can write** — otherwise the agent could rewrite the command that fetches your token.

The same patterns work for the other services (`sbx secret set anthropic`, `openai`, …). If you must go fastest, `gh auth token | sbx secret set github` also avoids history — but the gh CLI's OAuth token is broadly scoped; a [repo-scoped fine-grained PAT](git-credentials.md) remains the recommendation, because injection protects the token's *confidentiality*, not what it's authorized to do.

We verified the stdin-pipe form against Docker's documentation, but as with everything here: run `sbx secret set --help` and confirm the behavior on your machine before trusting it. However you set it, the payoff is the same — the proxy injects the auth header on matching outbound requests, and inside the VM the agent sees only a sentinel value, not the token.

## Environment variables: fine for config, never for secrets

Host environment variables are **not forwarded into the sandbox wholesale** — which is a feature: it's the same reason the [README warns](../README.md#three-tiers) that tokens exported in your `~/.zshrc` defeat every other sandbox tier. A variable reaches the sandbox only if you pass it explicitly:

- **`-e`/`--env` and `--env-file`** on `sbx run` / `sbx create` (`sbx` 0.39.0+): `-e LOG_LEVEL=debug`, or a bare `-e NAME` to copy that variable's value from your host shell. When the command creates the sandbox, the variables are stored with it. Everything passed this way is **plainly readable inside the VM** — so `-e GH_TOKEN` would hand the agent your real token and undo credential injection. Config only.
- **Non-secret configuration** — a [kit](https://docs.docker.com/ai/sandboxes/customize/kits/) can set env vars declaratively (`environment.variables` in its `spec.yaml`): useful for tool paths, feature flags, workspace conventions. Docker's docs carry an explicit warning we'll repeat: **don't put secret values in kit env vars — they are plainly visible to the agent inside the VM**, which throws away the credential-injection benefit that makes this tier worth using.
- **Credentials** never go through the options above. Use `sbx secret set` (for services the proxy doesn't know, `sbx secret set-custom` maps a domain + env-var name and likewise exposes only a placeholder inside the VM). If your keys are already exported in your shell, `sbx secret import` copies the known ones (`ANTHROPIC_API_KEY`, `GH_TOKEN`, …) into the keychain after confirming each — then delete the `export` lines from your dotfiles.

Rule of thumb: if the value would hurt you in a log line, it goes through `sbx secret set`, never through `-e`, an env file, or a kit.

## Network policy: default-deny + our allowlist

The proxy listens on the host and is the only way out of the sandbox. ICMP is blocked, and so is UDP unless you turn on Docker's experimental outbound-UDP option. It has three presets:

- **open** (`allow-all`) — all outbound allowed (don't use)
- **balanced** — default-deny, plus Docker's baseline allowlist: "AI provider APIs, package managers, code hosts, container registries, and common cloud services". As of v0.35.0 that explicitly includes Azure Blob Storage (`*.blob.core.windows.net`). **We don't use it** — that baseline allows domains on our [never-allowlist](network-allowlists.md#never-allowlisted--and-why), and Docker doesn't publish the full list (only `sbx policy ls` shows it), so you can't review it in advance. If you're weighing it anyway, see [the trade-offs](#if-youre-evaluating-the-balanced-preset).
- **locked down** (`deny-all`) — no baseline allow rules (**our base**)

[`configs/docker-sandbox/apply-policy.sh`](../configs/docker-sandbox/apply-policy.sh) initializes the global policy to `deny-all` and then adds our allowlisted domains via the `sbx policy` CLI, reading [`allowed-domains.txt`](../configs/docker-sandbox/allowed-domains.txt) next to it (kept in sync with the tool-level lists — see the [sync note](network-allowlists.md#keeping-the-allowlists-in-sync)). `sbx policy init` is one-time: if you already chose Locked Down at `sbx login`, the script notes that and skips it; if you chose `Balanced` earlier, switch with `apply-policy.sh --reset`. That runs `sbx policy reset`, which asks to confirm, **stops running sandboxes**, and then prompts you for a preset itself: **pick "3. Locked Down"**. The script ends by printing the policy table (`sbx policy ls`): on deny-all it lists only `local` and `kit` policies (plus `org` under org governance), and `local` holds exactly the allowlist's rules. Treat any other row as a sign a preset baseline may still be active. We've verified what the table looks like on Locked Down, but not yet how Balanced appears in it.

**Kits can still add rules.** Even under `deny-all`, built-in agent kits (the `claude`, `codex`, … agents) and any kit you pass with `--kit` add their own **per-sandbox** allow rules — typically for their own API. Review them once per agent, and treat anything outside our allowlist as a finding: `sbx policy ls <sandbox> --source kit --type network --wide`. A global `sbx policy deny network <host>` overrides a kit's allow if you need to remove one.

Rules accept exact hostnames, wildcard subdomains (`*.example.com` matches one level, `**.example.com` any depth, and neither matches `example.com` itself), an optional `:port`, and CIDR ranges. **Deny takes precedence over allow** for the same host. The same never-allowlist rule applies — no cloud-provider storage domains ([why](network-allowlists.md#never-allowlisted--and-why)).

> **Note on the policy store.** We drive policy through the documented `sbx policy` CLI rather than a config file: as of this writing the on-disk format of the *local* policy store isn't documented, so a hand-authored file would be guesswork. The CLI is the supported, stable interface.

### If you're evaluating the Balanced preset

This isn't a recommendation. Locked Down plus our allowlist is the default this repo supports. But Balanced is the option `sbx login` highlights, and it's a reasonable thing to weigh, so here are the trade-offs as we understand them.

**What you gain:**

- **Less friction.** Docker's baseline covers the everyday development traffic ("AI provider APIs, package managers, code hosts, container registries, and common cloud services", plus VS Code domains as of v0.35.0). Installs, image pulls, and editor tooling that would hit a 403 under Locked Down tend to just work.
- **Someone else maintains it.** Docker updates the baseline as ecosystems move (for example, a later release added the NodeSource APT repository), so you're not waiting on a PR to this repo when a registry changes hosts.

**What you give up:**

- **It allows domains on our never-list.** The baseline explicitly includes Azure Blob Storage (`*.blob.core.windows.net`), and "common cloud services" is broad. Multi-tenant storage is a ready-made exfiltration channel: an attacker can receive data on their own bucket under the same domain ([why](network-allowlists.md#never-allowlisted--and-why)).
- **You can't review it in advance, and it changes under you.** The full list isn't published, and it's tied to the `sbx` version. A routine `brew upgrade` can widen your egress with no change to your config and no PR anyone reviews.
- **Your allowlist stops being the source of truth.** Under Locked Down, "what can the agent reach?" has a short answer: our allowlist plus the kit rules. Under Balanced, the answer is our allowlist plus the kit rules plus whatever this release of Docker's baseline contains.

**If you evaluate it anyway,** treat it as a deliberate, recorded decision rather than a default:

1. List the baseline on your installed version with `sbx policy ls --wide` and compare it against the [never-list](network-allowlists.md#never-allowlisted--and-why).
2. Add explicit denies for the never-list. Docker documents that deny rules take precedence over allow rules for the same host. We haven't confirmed that a wildcard deny beats a more specific baseline allow, so step 3 is where you confirm it. Use `**.` wildcards, because `*.` matches only one subdomain level (S3 hosts look like `bucket.s3.us-east-1.amazonaws.com`) and neither form matches the bare domain:

   ```bash
   sbx policy deny network "**.amazonaws.com,**.googleapis.com,**.blob.core.windows.net,**.azurefd.net,**.cloudfront.net,**.r2.dev"
   sbx policy deny network "pastebin.com,transfer.sh,file.io"
   ```

3. Confirm the denies hold: `sbx policy check network example.blob.core.windows.net` should report denied, and the [egress checks](#verify-the-isolation-is-working) should fail for those hosts.
4. Repeat steps 1–3 after every `sbx` upgrade, since the baseline can change between releases.

Two caveats. **Denying a whole cloud domain also blocks whatever legitimately runs there**; it may be why some of those domains are in the baseline to begin with (VS Code extension downloads and some registries' layer storage are plausible examples, which we haven't verified). And **this repo doesn't test Balanced**: we haven't confirmed the full baseline contents, how its rules appear in `sbx policy ls`, or that the deny list above is complete. On a fleet, make this call in the org governance policy rather than per laptop: under org governance only org allow rules grant access, though local denies still apply ([below](#fleet-enforcement-requires-the-org-governance-tier)).

## Adding your own allowed domains

Local rules are **additive**: they stack on top of the `deny-all` baseline and the allowlist applied by `apply-policy.sh`, and they take effect **immediately** — no sandbox restart. So when an agent hits a blocked domain mid-task (the request fails with a structured `403` naming the rule), you can unblock it from the host and let the agent retry:

```bash
sbx policy allow network api.example.com                           # all sandboxes
sbx policy allow network --sandbox <sandbox-name> api.example.com  # just one sandbox
sbx policy allow network "api.example.com,*.example.org"           # several at once
```

Prefer the `--sandbox` form for one-off, project-specific needs — it keeps the global policy short and reviewable. Inspect and prune with:

```bash
sbx policy ls          # active rules and where each came from (--include-inactive for the rest)
sbx policy log         # recent connections: host, matching rule, allowed/blocked, request count
sbx policy rm network --resource api.example.com    # remove a rule (or: --id <uuid>)
```

Niche, personal-use domains are exactly what this local path is for — they don't need to go into the repo's core allowlist. Two rules still stand, though: **never allow cloud-provider storage or paste domains** ([why](network-allowlists.md#never-allowlisted--and-why)) — don't add allow rules for them, even though deny-all would otherwise block them — and remember these rules are **user-local and developer-changeable**, so they're convenience, not enforcement ([governance below](#fleet-enforcement-requires-the-org-governance-tier)). One reset caveat: `sbx policy reset` deletes every local rule and the preset choice — re-run `apply-policy.sh` afterwards.

## Clone mode vs. direct mount: the trade-offs

`sbx run` has two ways of exposing your project, and the choice matters more than any other flag:

**Direct mode (the default)** mounts your working tree into the VM — the agent edits your real files, live. That's convenient for interactive, trusted work (your IDE sees every change instantly), but it means anything that executes implicitly during development — git hooks, a `Makefile`, `package.json` scripts — is operating on files your host tools will also execute. A compromised agent can plant changes that run *on the host* the next time you build.

**Clone mode (`--clone`, recommended)** gives the agent a private Git clone inside the VM, with your host repository mounted **read-only** alongside it. The agent can trash its copy without touching your working tree. The costs and mechanics to know:

- **No working branch is created for you** — the clone starts on whatever the host had checked out. Have the agent `git checkout -b <branch>` before it changes anything.
- **Commits stay inside the sandbox until you fetch them.** The CLI exposes each sandbox as a Git remote on the host: `git fetch sandbox-<name>`, then review and merge like any branch. **Removing the sandbox loses any commits you haven't fetched or pushed** — treat sandbox removal like deleting an unpushed branch.
- **Your remotes come along.** Non-local remotes (`origin`, `upstream`, a fork) are copied into the clone, so the agent can push and open PRs from inside the sandbox — through the proxy, with the injected credential.
- **The read-only mount includes untracked and gitignored files.** A `.env` sitting in the repo directory is readable from inside the sandbox even in clone mode (known upstream issue). Clone mode protects your working tree's *integrity*, not the *confidentiality* of what's in the directory — which is one more reason for the repo-wide rule: no real secrets or sensitive data anywhere an agent can see.
- **Requires a Git repo**, and doesn't work from a secondary `git worktree` checkout.

The honest summary: direct mode for short, interactive, trusted sessions where live edits are the point; `--clone` for everything else — long-running tasks, anything touching untrusted inputs, and any workflow where you want to review the agent's work as a diff before it exists on your machine.

## Verify the isolation is working

Before trusting any of this, watch it work. From a shell **inside the sandbox** (ask the agent to run these, open a shell through the `sbx tui` dashboard, or start an agent-less sandbox with `sbx run shell`):

```bash
# Egress: default-deny is real only if unlisted domains fail…
curl -s -o /dev/null -w '%{http_code}\n' https://www.cms.gov    # expect 403 (blocked)
curl -sS https://example.com                                     # expect a 403 with a structured
                                                                 # body naming the policy/rule
curl -s -o /dev/null -w '%{http_code}\n' https://example.blob.core.windows.net
                                                                 # expect 403 — this one is allowed
                                                                 # under Balanced, so a 403 proves
                                                                 # you're really on deny-all
# …and allowlisted ones succeed:
curl -s https://api.github.com/zen                               # expect a 200 and a koan

# Boundary: you're in a microVM, not on your Mac
uname -a                # a Linux kernel, not Darwin
ls /Users               # host home directories aren't there

# Credentials: the token never entered the VM
env | grep -iE 'token|api_key'   # expect sentinel/placeholder values, not real secrets
```

Meanwhile **on the host**, `sbx policy log` should show those blocked requests with the rule that matched — that's your evidence the proxy, not luck, stopped them. You can also ask the policy engine directly, without a sandbox: `sbx policy check network example.blob.core.windows.net` should report it denied. This is the same egress check we use for the other tiers ([troubleshooting](troubleshooting.md#verify-your-egress-is-actually-default-deny)); re-run it after CLI updates and preset changes, not just once.

## Managing sandboxes: stop, resume, remove

Sandboxes are cheap to create and meant to be disposable — but they hold state, so know the lifecycle before you clean house:

```bash
sbx ls                        # every sandbox: agent, status, published ports, workspace
sbx stop my-task              # stop the VM; state is retained
sbx run --name my-task        # resume it (there is no `sbx start` — `sbx run` reattaches;
                              #  running `sbx run` from the same workspace also reconnects)
sbx rm my-task                # remove — irreversible; asks for confirmation (-f to skip)
sbx rm --all                  # remove every sandbox
```

What persists across `stop`/`run`: the sandbox filesystem — installed packages, Docker images, configuration, command history, and any auth the agent did *inside* the VM (e.g. Claude Code's `/login`), for the sandbox's lifetime; published ports are re-published on restart. What `rm` destroys: everything inside the VM — only your workspace files on the host remain. **In clone mode, fetch before you remove** (`git fetch sandbox-<name>` on the host): unfetched commits die with the sandbox, though `sbx rm` does warn you about them.

Housekeeping notes:

- Each sandbox defaults to **half your host's memory (capped at 32 GiB) and all CPUs** — size long-lived ones explicitly with `sbx run -m 8g --cpus 4 …`.
- Old sandboxes accumulate disk (their filesystems live on until `rm`). Make `sbx ls` → fetch → `sbx rm` a habit at the end of a task rather than letting stopped sandboxes pile up.
- The nuclear option is `sbx reset` — stops all VMs and deletes **all** sandbox data (`--preserve-secrets` keeps your stored secrets). Also note `sbx logout` stops every running sandbox as a side effect.

## Per-agent notes: Claude Code, Codex, Copilot

One pass-through rule covers all three: **everything after `--` goes to the agent's own CLI.** A leading *flag* appends to the default flags `sbx` uses; a bare-word first argument *replaces* them entirely.

- **Claude Code** — if you set `sbx secret set anthropic`, the API key is injected and no login is needed. **Without an API key — i.e. you use a Claude subscription — run `/login` inside Claude Code on first use** to authenticate via OAuth; the agent will sit unauthenticated until you do. Pick a model at launch with a pass-through flag, or switch mid-session with `/model` (model IDs change as new models ship; `/model` lists the current ones):

  ```bash
  sbx run --clone claude -- --model claude-fable-5-1
  ```

- **Codex** — auth via `sbx secret set openai` (API key) or the `--oauth` variant of `secret set` to sign in with a ChatGPT account. Model selection is the same pass-through:

  ```bash
  sbx run --clone codex -- --model <model>
  ```

- **Copilot** — set the model at launch with `-- --model <model>` (or the `COPILOT_MODEL` environment variable); it can also be switched mid-session with `/model`. The launch flag is the dependable path if you want the session to start on the right model:

  ```bash
  sbx run --clone copilot -- --model <model>
  ```

The tool-level guides ([claude-code](claude-code.md) · [codex](codex.md) · [copilot](copilot.md)) still apply *inside* the VM — settings like Claude Code's deny lists are defense-in-depth on top of the microVM, not redundant with it.

## What's in the box: base image and customization

Sandboxes boot from per-agent template images, `docker/sandbox-templates:<agent>` (e.g. `:claude-code`, `:codex`) — **Ubuntu-based**, per Docker's docs, on a recent release (check for yourself: `cat /etc/os-release` inside a sandbox). The agent runs as an unprivileged `agent` user with common developer tooling preinstalled.

Two supported ways to customize:

- **A template image** — a Dockerfile that starts `FROM docker/sandbox-templates:claude-code`, switches to `root` for `apt-get`, then **back to the `agent` user** for user-level tools (or they land in `/root/` where the agent can't use them). Run with `sbx run --template <your-image> claude`; keep the agent matched to the base variant you extended.
- **Kits** — a declarative bundle (local dir, zip, `git+URL`, or OCI ref) of tools, env vars, files, network rules, and startup commands: `sbx run claude --kit <ref>`. Lighter-weight than a custom image for per-project needs.

If you add network rules via a template or kit, the same allowlist rules in this repo apply — review them like you'd review a PR against [`allowed-domains.txt`](../configs/docker-sandbox/allowed-domains.txt).

## Using it with an IDE (VS Code, JetBrains)

Be aware of the gap: **there is no official IDE-attach integration** for `sbx` sandboxes — no Dev Containers "attach", no JetBrains Gateway target (verified against Docker's docs as of this writing; the deprecated Docker-Desktop `docker sandbox` integration is not this). What works today:

- **Keep your IDE on the host; run the agent in the sandbox.** This is the workflow we actually recommend. In `--clone` mode, review the agent's output in your IDE via `git fetch sandbox-<name>` and diff it like a PR before merging. In direct-mount mode, edits appear in your IDE live (with the [trade-offs above](#clone-mode-vs-direct-mount-the-trade-offs)).
- **code-server kit** — Docker's community kit repo ([docker/sbx-kits-contrib](https://github.com/docker/sbx-kits-contrib)) includes a kit that runs web-based VS Code *inside* the sandbox; you then publish its port to the host. Functional, but it's a community kit, not a supported IDE integration — evaluate it accordingly.
- **If in-IDE agent + strong isolation is a hard requirement** (e.g. Copilot agent mode in JetBrains), this repo has **no sandboxed option** for it today. Use the tool's CLI in the sandbox instead (e.g. Copilot CLI), or disable IDE agent mode via org policy ([enforcement](enforcement.md)).

## Fleet enforcement requires the org governance tier

By default, `sbx policy` rules are **user-local and the developer can change them** — fine for the trusted subset, but not "enforced." To make the policy non-overridable, you need Docker's **paid org governance subscription**: once an org policy is set in the Docker **Admin Console → AI governance**, only org allow rules grant access: local allow rules go inactive, while local deny rules still apply on top (a developer can restrict further, never widen). Changes propagate in ~5 min. That's the analog of managed settings / `requirements.toml` for this tier. See [enforcement.md](enforcement.md) for where it sits relative to the other tiers.

## Caveats (be honest in the compliance record)

- **The governance console is Docker-hosted SaaS, and Docker Sandboxes has no stated FedRAMP/federal authorization.** Before relying on it for federal work, clear the Admin Console / Governance API against your data-residency and authorization requirements. This is the gating question for federal use — settle it first.
- **Use `--clone`, not direct mount, for anything untrusted** — and know that even clone mode leaves untracked files *readable*. See [the trade-offs](#clone-mode-vs-direct-mount-the-trade-offs).
- **TLS interception is how hostname enforcement works.** The proxy is a man-in-the-middle with its own CA that the sandbox trusts — that's what makes layer-7 hostname filtering and credential injection possible (and is *stronger* than the built-in tool proxies, which don't inspect TLS). But certificate-pinned hosts require a bypass mode that skips inspection — document any host you put in bypass as a policy gap. Install internal corporate CAs into the sandbox trust store properly; don't override `SSL_CERT_FILE` (it breaks the credential proxy).
- **Still scope the credential.** Token injection means the raw value doesn't enter the VM, but an injected credential can still authenticate a push to any repo it's authorized for. Keep using a [repo-scoped fine-grained PAT](network-allowlists.md#git-credentials-https--scoped-pats) so the blast radius stays bounded.
- **The default agent invocations are permission-free** (`--dangerously-skip-permissions` and friends). Inside the boundary that's the intended model, but it means the boundary is doing *all* the work — which is why the verification step isn't optional.
- **macOS and Windows at launch; Linux support has since shipped (Ubuntu 24.04+).** Verify your platform against Docker's requirements before assuming CI parity.

## References (source of truth)

- Overview: https://docs.docker.com/ai/sandboxes/
- Pricing / licensing FAQ (free for commercial use; paid governance): https://docs.docker.com/ai/sandboxes/faq/
- Get started (install, login, requirements): https://docs.docker.com/ai/sandboxes/get-started/
- Usage (clone vs. direct mode, fetching work back): https://docs.docker.com/ai/sandboxes/usage/
- Security model (isolation, mounts, credential injection): https://docs.docker.com/ai/sandboxes/security/
- Credentials / secrets: https://docs.docker.com/ai/sandboxes/security/credentials/
- Network policy (presets, `sbx policy`, proxy): https://docs.docker.com/ai/sandboxes/security/policy/
- CLI reference (`sbx policy allow/rm/log`, `sbx secret set`): https://docs.docker.com/reference/cli/sbx/
- Org governance (admin-enforced policy, rule syntax, precedence): https://docs.docker.com/ai/sandboxes/security/governance/
- Supported agents (incl. per-agent pages for Claude Code, Codex, Copilot): https://docs.docker.com/ai/sandboxes/agents/
- Templates and kits (base images, customization): https://docs.docker.com/ai/sandboxes/customize/
- microVM architecture: https://www.docker.com/blog/why-microvms-the-architecture-behind-docker-sandboxes/
