# Universal Sandboxing: `srt` and the Raw Seatbelt Fallback

When a tool has no built-in sandbox (Copilot CLI pre-GA, any other CLI), or you want one consistent wrapper for everything, two native-macOS options live here. Both follow the same proven architecture:

> **Seatbelt is configured to block direct egress at the kernel; a proxy outside the sandbox enforces the domain allowlist.** Seatbelt itself cannot filter by hostname — the kernel sees sockets, not DNS names. A program that ignores `HTTPS_PROXY` doesn't escape the allowlist; it simply has no network. The design fails closed — assuming the profile loads and the kernel boundary holds.

## Option A (preferred): Anthropic `sandbox-runtime` (`srt`)

[`@anthropic-ai/sandbox-runtime`](https://github.com/anthropic-experimental/sandbox-runtime) is the open-source engine behind Claude Code's `/sandbox`, usable standalone to wrap **any** command. It packages the Seatbelt profile, the localhost-pinned egress, and a domain-filtering HTTP CONNECT + SOCKS5 proxy in one tool.

```bash
npm install -g @anthropic-ai/sandbox-runtime
```

Create `~/.srt-settings.json`:

```json
{
  "network": {
    "allowedDomains": [
      "github.com",
      "api.github.com",
      "codeload.github.com",
      "objects.githubusercontent.com",
      "raw.githubusercontent.com",
      "registry.npmjs.org"
    ]
  },
  "filesystem": {
    "denyRead": ["~/.ssh", "~/.aws", "~/.azure", "~/.config/gcloud", "~/.kube", "~/.gnupg", "~/.netrc", "~/.npmrc", "~/.pypirc", "~/.docker", "~/Library/Keychains", "~/.config/sops", "~/.bash_history", "~/.zsh_history"],
    "allowWrite": [".", "/tmp"],
    "denyWrite": [".env", ".env.*"]
  }
}
```

Run anything under it:

```bash
srt "npm install"
srt "copilot"                 # wrap a whole agent session
srt --settings ./project-srt.json "pytest"
```

Wildcards like `*.npmjs.org` work in `allowedDomains`; `deniedDomains` exists but per our [default-deny posture](threat-model.md) you shouldn't need it — keep the allowlist short instead.

## Option B (reference/fallback): raw `sandbox-exec`

[`configs/seatbelt/agent.sb`](../configs/seatbelt/agent.sb) + [`configs/seatbelt/run-sandboxed.sh`](../configs/seatbelt/run-sandboxed.sh) is our minimal, dependency-free wrapper. It exists so you can read exactly what a Seatbelt policy does, and for machines where installing npm packages isn't an option.

```bash
# No network at all (default), workspace-write, sanitized env:
configs/seatbelt/run-sandboxed.sh -- npm test

# Network only via a domain-filtering proxy you run on localhost:8888:
configs/seatbelt/run-sandboxed.sh --allow-net-proxy 8888 --pass-env GH_TOKEN -- gh pr list
```

What it enforces (all verified by live test on macOS — see [troubleshooting.md](troubleshooting.md#verifying-your-sandbox) for the test commands):

| Property | Mechanism |
|----------|-----------|
| Writes only in workspace + temp | `(deny default)` + explicit `file-write*` allows |
| `~/.ssh`, `~/.aws`, `~/.kube`, `~/.config/sops`, `~/.bash_history`, `~/.zsh_history`, … unreadable | deny rules placed **last** (Seatbelt is last-match-wins) |
| `*.key`, vim swap files (`*.sw[a-p]`) unreadable anywhere | `(regex …)` denies — extension-matched, so they catch these types even inside the workspace. (`srt`'s/Claude Code's `denyRead` is literal-path-only and can't express extension globs; this is the OS-level equivalent.) |
| Keychain unreachable | securityd Mach services deliberately absent from the `mach-lookup` allowlist — blocking the files isn't enough, the `security` CLI talks to the daemon over Mach IPC |
| No network (or localhost-proxy-only) | `(deny default)`; optional `(allow network-outbound (remote tcp "localhost:PORT"))` appended by the wrapper |
| Shell env doesn't leak | wrapper starts from `env -i` with an explicit allowlist; secrets pass only via `--pass-env` |

For the proxy in `--allow-net-proxy` mode, run any domain-filtering forward proxy on localhost — e.g. `mitmproxy --mode regular --listen-port 8888 --allow-hosts '^(.*\.)?(github\.com|npmjs\.org)(:443)?$'`. The Seatbelt side guarantees the proxy is the only path out.

**Caveats of Option B** (why A is preferred): `sandbox-exec` is deprecated by Apple (still shipped, still what Codex/Chrome build on, but carries long-term uncertainty); the Mach-service allowlist in `agent.sb` is minimal and some tools may need additions; you must bring your own proxy for network use.

## Giving the wrapped command git credentials

The wrapper inherits **no** environment by default — it starts from `env -i` with a fixed allowlist — so a token is present inside the sandbox only because you named it with `--pass-env`. That's the whole credential-delivery story for the `srt`/`run-sandboxed.sh` tiers:

```bash
# One-time on the host: let gh act as git's credential helper.
gh auth setup-git

# Per session: pass a scoped, short-lived token in explicitly.
GH_TOKEN=$(gh auth token) \
  configs/seatbelt/run-sandboxed.sh --allow-net-proxy 8888 --pass-env GH_TOKEN -- gh pr list
```

`git push`/`gh` inside the sandbox read `GH_TOKEN`; nothing else leaks in. The token **must** be a fine-grained PAT scoped to the repos in play (ideally a ~1-hour GitHub App installation token) — within one user account the agent can read whatever git can, so scope, not secrecy, is what bounds a leak. Full rationale and the per-tier alternatives (including "don't put the token in the sandbox at all") are in [network-allowlists.md → Git credentials](network-allowlists.md#git-credentials-https--scoped-pats). Never point the osxkeychain credential helper into the sandbox.

## When to use which

| Situation | Use |
|-----------|-----|
| Wrapping Copilot CLI until its sandbox GA's | `srt` |
| Wrapping miscellaneous CLIs/scripts an agent generates | `srt` |
| Understanding/auditing what Seatbelt actually enforces | `agent.sb` (read it — it's ~70 lines) |
| Locked-down machine, no npm allowed | `run-sandboxed.sh` |
| Everything, uniformly, including IDEs | [devcontainer](devcontainer.md) |
