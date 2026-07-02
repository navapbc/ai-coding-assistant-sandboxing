# Apple `container`: Emerging Tier 2 microVM (Watch This Space)

Apple's [`container`](https://github.com/apple/container) reached **v1.0.0 on
2026-06-09** (Apache-2.0, written in Swift, Apple-silicon only). It runs Linux
workloads in **per-container microVMs** on the macOS Virtualization framework —
an isolation boundary in the same class as [Docker Sandboxes](docker-sandbox.md)
and Firecracker. It's promising for agent sandboxing, but it is **not yet a
recommended primary tier** here: it has no built-in egress filtering, needs a
very recent macOS, and Apple itself calls its security isolation still-maturing.
Treat this page as a "watch this space," not a setup recipe.

> [!CAUTION]
> **There are two different Apple things, and only one is a sandbox.** Apple
> `container` (ephemeral, below) is the isolation-relevant one. Apple's
> **Container Machine** (the persistent "WSL-for-Mac" flavor) is **not a
> sandbox for agents** — see [the warning below](#container-machine-is-not-an-agent-sandbox).

## The isolation model (ephemeral `container`)

Each container runs in its **own lightweight VM** with its **own Linux kernel**
(an optimized Kata-derived kernel booted by a minimal Swift init, `vminitd`),
started through Apple's Virtualization framework. Unlike shared-kernel container
namespaces, a container escape has to beat a **hypervisor**, not just namespaces
— the same argument Docker Sandboxes and Firecracker make. By default it does
**not** mount your macOS home directory into the guest, so `~/.ssh`, `~/.aws`,
`~/.config/sops`, and shell histories aren't exposed the way they would be under
a home-mounted VM. Boot is sub-second, and resources are released on shutdown.

## Why it isn't a recommended primary tier yet

- **No built-in egress filtering.** Neither `container` nor Container Machine
  ships a hostname-level, default-deny egress proxy like Docker Sandboxes'
  TLS-terminating filter. **Default-deny egress is a core requirement here**
  ([principles](../README.md#principles)), so you'd have to layer it yourself —
  a filtering proxy in front of the guest, or a `vmnet`-level firewall — which
  is exactly the hand-rolled work the [devcontainer](devcontainer.md) tier
  already does and Docker Sandboxes does for you. Until that story is built in,
  `container` alone does not deliver the network posture this repo insists on.
- **Very recent macOS only.** Full functionality (including container-to-container
  networking via `vmnet`) needs **macOS 26 (Tahoe)** on Apple silicon. It
  installs on macOS 15 but core features are gated to 26, and the project
  doesn't track issues on older releases.
- **Linux workloads, like the other container tiers.** The agent runs inside
  Linux (Ubuntu/Debian/Alpine images), not native macOS — same operating model
  as the devcontainer and Docker Sandboxes tiers, not the native Seatbelt tiers.
- **Security isolation is still maturing.** Apple lists memory reclamation,
  security isolation, and image compatibility as areas with room to improve, and
  it is **not yet a built-in macOS system component**. Verify before you rely on
  it — consistent with this repo's [verify-everything stance](../README.md).

## Container Machine is NOT an agent sandbox

Apple introduced **Container Machine** at WWDC 2026 — a *persistent* Linux VM
with tight host integration, positioned as a "WSL for Mac." That integration is
precisely what makes it **unsafe for running an untrusted or agent workload**:

- It **mounts your macOS home directory** into the Linux environment.
- The login user **matches your Mac account, with passwordless `sudo`**.
- The filesystem **persists** across sessions.

For everyday dev that's the feature. For a hijacked agent it's a straight path
to `~/.ssh`, `~/.aws`, `~/.config/sops`, and everything else this repo's
`denyRead` set exists to block — the microVM protects the host *kernel* but does
nothing for your *secrets*, which is the exact thing our [threat
model](threat-model.md) defends. **Do not run agents in a Container Machine.**
If you strip the home mount and lock down the mounts to make it safe, you've
discarded what makes it a Container Machine and you're really back to ephemeral
`container` above.

## If you want to experiment today

Use **ephemeral `container`** (not Container Machine), on macOS 26 + Apple
silicon, and **put a default-deny egress filter in front of it** (proxy or
`vmnet` firewall) before trusting it with anything — otherwise the network side
is wide open. Until built-in hostname egress filtering lands, [Docker
Sandboxes](docker-sandbox.md) remains the recommended microVM option because it
provides that filtering (and credential injection) out of the box. **Verify the
default mount and network behavior hands-on** on your own macOS 26 machine — the
facts here are drawn from Apple's docs and release notes, not yet from testing
on this repo's fleet.

## References (source of truth)

- Project + docs: https://github.com/apple/container
- Containerization framework: https://github.com/apple/containerization
