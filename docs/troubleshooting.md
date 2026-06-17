# Troubleshooting: When Something Is Blocked

Blocked-by-design is the system working; this page is about telling that apart from broken, and unblocking fast when the block is wrong. **Target turnaround for a legitimate allowlist addition: same business day.** A slow exception process is how security tools get bypassed — if you're waiting more than a day, escalate the process, not just the domain.

## "A command failed with a network error"

1. **Identify the domain.** The error usually names it (`Could not resolve host`, `403 from proxy`, `CONNECT tunnel failed, response 403`, `connection refused`). In Claude Code, the prompt names the domain when a new one is requested; in the devcontainer, the firewall REJECTs (not DROPs) so tools fail fast with `Network is unreachable`/admin-prohibited rather than hanging.
2. **Is it on the never-list?** Check [network-allowlists.md](network-allowlists.md#never-allowlisted--and-why). Cloud storage domains stay blocked — find another way (usually: that fetch shouldn't happen inside an agent sandbox).
3. **Legitimate need? Add it via the manifest.** Edit [`configs/allowed-domains.manifest.json`](../configs/allowed-domains.manifest.json) (add the domain with the right `tiers`), update the matching tier file(s), and run `python3 scripts/check-config-consistency.py` — it prints exactly which files are out of step. *Where* it lands depends on posture (the [shipped default is strict](enforcement.md#the-strict-vs-standard-domain-decision)):
   - **Strict (`allowManagedDomainsOnly: true`):** project/user `allowedDomains` are **ignored** — the domain must be in the **managed** tier. *Solo machine:* edit `/Library/Application Support/ClaudeCode/managed-settings.json` with `sudo`, then restart (this is why a `.claude/settings.json` edit appears to "do nothing" under strict). *Fleet:* PR it into `configs/claude-code/managed-settings.json` and push via MDM.
   - **Standard / devcontainer:** add at project scope (`.claude/settings.json`) or `.devcontainer/allowed-domains.txt`.
   Justify it (what breaks without it, what it serves, why it isn't multi-tenant storage), and never add a [never-listed](network-allowlists.md#never-allowlisted--and-why) domain. Common registries (PyPI, npm, Maven, Gradle, Rust, NuGet, Yarn, Ruby) are already in the default; GitHub Packages and the public Go proxy are [unsupported](network-allowlists.md#per-stack-package-registries) (they require banned cloud storage).
4. **Devcontainer special case — it worked this morning, fails now:** CDN IP rotation. Rerun `sudo /usr/local/bin/init-firewall.sh` to re-resolve. (Drift fails closed, never open.)

## "A command failed with Operation not permitted"

That's Seatbelt denying a filesystem operation.

- Writing outside the workspace? That's the boundary. If a tool legitimately needs a path (e.g. `~/.cache/<tool>`), add it narrowly: Claude Code `sandbox.filesystem.allowWrite`, Codex `writable_roots`, or the profile's write allows. Never add `~/`.
- Reading a secrets path? Working as intended. The agent does not need `~/.ssh` — see [the git/PAT setup](network-allowlists.md#git-credentials-https--scoped-pats).

### `git` fails in a monorepo (`cannot lock ref … .git/… Operation not permitted`)

The sandbox makes the directory you **launched the agent in** writable. In a monorepo, if you start the agent in a **subdirectory**, the repo's `.git/` is a level (or more) **up** — *outside* the writable workspace — so every git write (`commit`, `checkout -b`, anything that locks a ref) is denied, even though editing files in your subdir works fine. Confirm with `git rev-parse --git-dir`: if it resolves above your launch dir, that's the cause (not a `.git` protection or a `denyWrite`).

**Write scope and context scope are separable**, so choose by how much of the repo you're actually working in — don't just move the launch dir for git's sake:

- **Working within one package (keep context tight):** stay launched in the subdirectory and grant the sandbox write access to *just* the repo's `.git`. Because it's an absolute, per-developer path, put it in your personal `.claude/settings.local.json` (gitignored) — **not** the shared, committed `.claude/settings.json` (other devs have different home paths):
  ```json
  { "sandbox": { "filesystem": {
    "allowWrite": ["/abs/path/to/monorepo/.git"],
    "allowRead":  ["/abs/path/to/monorepo/.git"]
  } } }
  ```
  (Include `allowRead` only if your managed policy sets `allowManagedReadPathsOnly`.) **Allow the whole `.git`** so every git command just works — commit, branch, merge, rebase, stash, gc. *Don't* allowlist individual `.git` subpaths: git writes an operation-dependent set (`MERGE_HEAD`, `rebase-merge/`, `packed-refs`, reflogs, lockfiles, …), so a partial list breaks merge/rebase/gc with cryptic `Operation not permitted` errors. This still keeps the agent's *context* on your subdir — it's narrower than making the whole monorepo the workspace.
- **Working across packages:** launch from the repo root — git works out of the box, but accept the wider context (broader file search, every `CLAUDE.md`, more tokens). Right when the task genuinely spans packages; heavier than it's worth for a focused change.

> **Optional, higher-friction tightening — skip it unless this vector is in your threat model.** You can also `denyWrite` `…/.git/hooks` and `…/.git/config` to block tampering that executes later in your *unsandboxed* shell (a hook or `credential.helper` a hijacked agent plants there). The cost is real day-to-day friction: `git config`, `git remote`, `git push -u`/tracking, and hook installers (husky, pre-commit) stop working. With `git push` already gated and egress default-deny, most teams won't want it.

## Known Seatbelt-incompatible tools (sanctioned workarounds)

| Tool | Symptom | Sanctioned workaround |
|------|---------|----------------------|
| `docker` | Fails under any Seatbelt sandbox | Don't `excludedCommands` it (that runs it **unsandboxed**, with the full Docker-socket blast radius). Let it hit the ask-prompt for one-offs; move container-heavy work to the [devcontainer](devcontainer.md) tier |
| `jest` (watchman) | Hangs | `jest --no-watchman` |
| Go-based CLIs (`gh`, `terraform`, `gcloud`) | TLS verification failure on macOS (`x509: OSStatus -26276`). Go delegates cert verification to the macOS Security framework, which reaches for trust settings in the **user keychain the sandbox denies** (`~/Library/Keychains`); the failure is in trust *evaluation*, not the certificate. (Confirmed not a MITM: the proxy is a CONNECT pass-through and the genuine host cert reaches the client — `curl` validates it fine.) | For GitHub API work (e.g. opening a PR), use `curl` against the REST API — `curl` verifies via SecureTransport against the world-readable system root keychain, so it succeeds where `gh` fails ([recipe below](#opening-a-pr-or-other-github-api-work-when-gh-fails-tls)). Separately, for a *genuine* corporate CA/MITM proxy: `enableWeakerNetworkIsolation: true` (Claude Code). Prefer either over `excludedCommands` |
| Windows binaries under WSL2 | Blocked Unix-socket handoff | Out of scope for our macOS fleet; see Claude Code docs if relevant |

`excludedCommands` is always the last resort: every entry is a hole in the sandbox wall, it has no managed-scope lock, and it should appear in code review as a red flag.

### Opening a PR (or other GitHub API work) when `gh` fails TLS

`gh pr create` fails under the sandbox with `Post "https://api.github.com/graphql": tls: failed to verify certificate: x509: OSStatus -26276`. This is the Go-CLI TLS issue above — **not** an auth, network, or proxy-CA problem. The egress proxy is a CONNECT pass-through, so `gh` receives the genuine `api.github.com` certificate; it fails because Go's macOS trust evaluation needs the user keychain the sandbox denies. You don't need to weaken isolation or exclude the command — `curl` validates the same cert via SecureTransport against the (readable) system root keychain and reaches the *same* allowlisted host (`api.github.com`). So `git push` as normal, then create the PR through the REST API:

```bash
curl -sS -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/<owner>/<repo>/pulls \
  -d '{"title":"…","head":"<branch>","base":"main","body":"…"}'
```

For multi-line/Markdown bodies, build the JSON with `python3 -c 'import json,sys; ...'` into a file and pass `--data @file.json` rather than fighting shell quoting. Use a **repo-scoped fine-grained PAT** for `$TOKEN` ([git-credentials guidance](network-allowlists.md#git-credentials-https--scoped-pats)) — don't reach for a broad, long-lived token, and note this still routes through the same allowlisted GitHub host, so it's no new egress surface.

## Verifying your sandbox

Run these *through the agent* (ask it to run them) — all five must behave as stated, on every tier:

```text
cat ~/.ssh/id_ed25519.pub      → Operation not permitted / blocked
touch ~/sandbox-escape-test    → Operation not permitted / blocked
curl -s https://example.com    → blocked OR prompts — see the egress caveat below
curl -s https://api.github.com/zen → succeeds (allowlisted)
security list-keychains        → fails (keychain unreachable)
```

The `example.com` line is the subtle one — read the next section before trusting it.

### Verify your egress is actually default-deny

A non-allowlisted domain returning **HTTP 200** means your egress is **not** default-deny — and for Claude Code's **standard** posture in an auto-allowed/agent session that is exactly what happens (the "prompt" has no human to block it). Test it explicitly:

```text
curl -s -o /dev/null -w '%{http_code}\n' https://www.cms.gov   → expect a failure (000/blocked)
curl -s -o /dev/null -w '%{http_code}\n' https://example.com   → expect a failure (000/blocked)
curl -s -o /dev/null -w '%{http_code}\n' https://api.github.com/zen → expect 200 (allowlisted)
```

- If the first two **fail** and GitHub **succeeds**: egress is default-deny. ✅
- If the first two return **200**: the allowlist isn't gating egress. Your `allowedDomains` is only *pre-allowing* (skipping prompts) — it does **not** block unlisted domains on its own. Fix: deploy the **strict** posture (`allowManagedDomainsOnly: true` in *managed* settings — user/project settings can't set it), then restart and re-run. See [the strict-vs-standard decision](enforcement.md#the-strict-vs-standard-domain-decision).
- One more check — confirm the block is the *proxy*, not just a dead network: `curl --noproxy '*' https://example.com` should fail to even resolve (direct egress is killed; everything must go through the filtering proxy). If *that* succeeds, the sandbox isn't confining egress at all.

For the raw Seatbelt wrapper, the same five checks ran green on 2026-06-12 (macOS Darwin 25.3) — rerun them after any edit to `agent.sb`:

```bash
cd /tmp && mkdir -p sbx-test && cd sbx-test
RS=path/to/configs/seatbelt/run-sandboxed.sh
$RS -- /bin/sh -c 'ls ~/.ssh'                       # must fail
$RS -- /bin/sh -c 'touch ~/escape'                  # must fail
$RS -- /usr/bin/curl -s --connect-timeout 4 https://example.com  # must fail
$RS -- /usr/bin/security list-keychains              # must fail
$RS -- /bin/sh -c 'git init -q r && echo ok'         # must succeed
```

The devcontainer firewall self-tests on every start (reach `api.github.com`, fail `example.com`) and aborts loudly if the test fails.

## "The sandbox broke a tool I can't work without"

Don't disable the sandbox. In order of preference:

1. Narrow config fix (a write path, a domain, a flag like `--no-watchman`) — this page or the tool guide probably has it.
2. Move the workflow into the [devcontainer](devcontainer.md), where the boundary is the container and in-container restrictions are looser.
3. File an exception per [policy-matrix.md](policy-matrix.md#exception-process) — visible, time-boxed, signed off.

If developers are hitting the same block repeatedly, that's a defect in our defaults: PR the fix into `configs/` so the next person doesn't hit it.

## Break-glass (when you genuinely must bypass, now)

Sometimes there's a real deadline and options 1–3 are too slow. A sanctioned, **auditable** break-glass beats a silent workaround — because the failure mode we most want to avoid is developers quietly turning the sandbox off and never turning it back on. The rules:

1. **Prefer the smallest bypass.** Run the *one* blocked command unsandboxed (Claude Code's `dangerouslyDisableSandbox` retry, or the command in a plain terminal) — don't disable the sandbox wholesale for the session.
2. **Announce it.** Post in your team's security channel: what you bypassed, why, and for how long. This is the "glass breaking" — it must be visible, not silent.
3. **Never bypass with live credentials present.** Don't pair a bypass with secrets in the environment; if the task needs a token, use a [repo-scoped PAT](network-allowlists.md#git-credentials-https--scoped-pats) and remove it after.
4. **Time-box and file the fix.** Re-enable immediately after, and open a PR/issue so the underlying block is fixed in `configs/` — a break-glass that isn't followed by a fix is a standing hole.

What's **not** break-glass: editing managed settings, adding `excludedCommands`, allowlisting a cloud-storage domain, or `--allow-all-tools`/`--yolo` outside a container. Those are policy changes, not emergencies — they go through review.
