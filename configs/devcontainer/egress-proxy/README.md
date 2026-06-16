# Devcontainer egress: SNI-filtering proxy (experimental, opt-in)

The default devcontainer firewall ([`../init-firewall.sh`](../init-firewall.sh)) resolves the allowlist to **IPs** at start and enforces with iptables. That's simple and runs anywhere Docker does, but it's **fragile to CDN IP rotation** (drift → false denials; broad/shared ranges → over-permit). See `docs/threat-model.md` residual risk #3.

This directory is an **opt-in alternative** that filters egress by **hostname (TLS SNI)** instead of IP — immune to IP rotation, and consistent with the hostname-filtering model of the built-in tiers. It is **experimental and untested in CI**: treat it as a reviewed starting point and run the validation below before relying on it.

## What it does / does not protect

- ✅ **Default-deny by hostname.** Outbound `:443` is redirected into a local Envoy; only TLS connections whose **SNI** is on the allowlist are forwarded (TLS **not** terminated) to their original destination. Unmatched SNI is closed. No IP resolution, so no drift.
- ✅ **Single source of truth.** The Envoy `server_names` are regenerated from [`../allowed-domains.txt`](../allowed-domains.txt) at start — the same list the IP firewall uses. No new place for domains to live.
- ⚠️ **Does NOT defeat domain fronting.** The SNI is client-supplied; a request can present an allowed SNI while really talking to another host behind a shared CDN. Same evasion class as the other hostname-filtering proxies (threat-model residual risk #2).
- ⚠️ **ECH (Encrypted Client Hello) blinds it.** If a client negotiates ECH, the SNI is encrypted and can't be matched. SNI filtering then fails closed (no match → denied) unless ECH is disabled.
- ⚠️ **HTTPS only.** Port 80 falls through to the default `DROP` (our allowlist is HTTPS). DNS stays pinned to the container resolver; **DNS tunnelling is not addressed here** — keep the existing DNS controls (`init-firewall.sh` Layer 1/2).

**If you want to beat domain fronting, use TLS *termination*, not SNI** — that means inspecting the real Host, which requires a MITM CA the container trusts. [Docker Sandboxes](../../../docs/docker-sandbox.md) already does TLS-terminating hostname filtering out of the box; if it's available to you, it is the stronger option and you don't need this.

### Domain fronting — why SNI isn't enough

Fronting splits the destination across two signals: the **TLS SNI** (cleartext — what this proxy filters) and the **HTTP `Host:`** header (inside the encrypted stream — what the server actually routes on). On a shared CDN frontend the two can disagree and the edge honors the `Host`:

```
TLS SNI: api.github.com       ← allowlisted, so we forward
Host: attacker.example         ← where the CDN routes, if it shares a frontend
```

We never see the `Host`, so the connection passes. Neither SNI nor IP filtering can stop this — both gate on the *outer*, allowlisted-but-attacker-chosen signal while the real target is in the encrypted inner. Two mitigations: (1) **don't allowlist frontable multi-tenant CDNs** — the repo's [never-list](../../../docs/network-allowlists.md#never-allowlisted--and-why) bans `*.cloudfront.net`, `*.amazonaws.com`, `*.r2.dev`, `*.blob.core.windows.net`, etc. for exactly this reason, so there's nothing to front *through*; (2) **TLS termination + `Host` allowlisting** — the only robust fix, i.e. [Docker Sandboxes](../../../docs/docker-sandbox.md).

### Making ECH a hard fail

ECH (Encrypted Client Hello) encrypts the real SNI, leaving only an outer "public name". A ClientHello with **no readable SNI already fails closed here** — no filter chain matches it, so Envoy drops the connection. The residual gap is an ECH connection whose *outer* name happens to be allowlisted. To make ECH a true hard fail:

- **At DNS (recommended — fits the devcontainer's DNS controls).** ECH only works if the client first fetches an ECH config from DNS — the `ech` SvcParam in the `HTTPS`/`SVCB` record. Strip or refuse it at the pinned resolver (or the opt-in dnsmasq allowlist) so clients get no config and **fall back to cleartext SNI**, which this proxy filters. Most reliable, no proxy change.
- **At the proxy (deeper).** Reject ClientHellos carrying the `encrypted_client_hello` extension (TLS ext type `0xfe0d`). Envoy's stock TLS inspector exposes no ECH matcher, so this needs a custom listener/TCP filter that parses the ClientHello — more engineering, untested here.

Together these enforce *"every egress must present a cleartext SNI we can match"*: no readable SNI ⇒ denied (already true), and ECH made unavailable via DNS ⇒ nothing can hide one. (This still doesn't beat plain domain fronting — only TLS termination does.)

## Enable it (two flags — no script edits)

The image and `init-firewall.sh` already support this mode; flip two values in `devcontainer.json` (and make sure this `egress-proxy/` dir is in your `.devcontainer/` build context alongside `Dockerfile`/`init-firewall.sh`):

1. **Build with Envoy** — `build.args.EGRESS_PROXY`:
   ```json
   "build": { "dockerfile": "Dockerfile", "args": { "EGRESS_PROXY": "true" } }
   ```
   This installs Envoy (pinned via the `ENVOY_VERSION` arg) and the `envoyproxy` run-as user. Default `false` keeps the image lean — the proxy scripts are copied either way, just unused.
2. **Select proxy mode** — `containerEnv.EGRESS_MODE`:
   ```json
   "containerEnv": { "EGRESS_MODE": "proxy" }
   ```
   `postStartCommand` stays `sudo /usr/local/bin/init-firewall.sh`; it **hands off to this proxy** when `EGRESS_MODE=proxy` (default `ipset` keeps the IP firewall). Keep `--cap-add=NET_ADMIN`/`NET_RAW` in `runArgs`. The allowlist is the same `allowed-domains.txt` either way — `init-firewall.sh` passes it through as `DOMAINS_FILE`.

Then rebuild the container. To switch back, set `EGRESS_PROXY` to `false` (rebuild) and/or `EGRESS_MODE` to `ipset`.

Run Envoy as a **managed service** for anything beyond a quick test — the init script backgrounds it for a single `postStart` run, which won't survive a crash. A supervisor or a sidecar `docker-compose` service is the durable shape.

## Validate before relying

On a real build, confirm:
- `curl -s -o /dev/null -w '%{http_code}\n' https://api.github.com/zen` → `200` (allowlisted SNI forwarded).
- `curl -s -o /dev/null -w '%{http_code}\n' https://example.com/` → **fails/closed** (SNI not on the list).
- `curl --noproxy '*' -s https://example.com/` → also fails (no direct path; everything goes through the redirect).
- A domain you add to `allowed-domains.txt` works after restart (regeneration wired up).
- Envoy's own egress reaches the real hosts (the uid exemption is correct — no redirect loop). Check `/tmp/envoy-egress.log` and the admin page at `127.0.0.1:15000`.
- Version check: the `@type` strings and `ORIGINAL_DST`/`use_original_dst` behavior in `envoy.yaml` match your installed Envoy version.

## Files

- [`envoy.yaml`](envoy.yaml) — Envoy bootstrap: TLS-inspector + SNI `server_names` allowlist + `ORIGINAL_DST` tcp-proxy, no catch-all chain (default-deny).
- [`init-egress-proxy.sh`](init-egress-proxy.sh) — regenerates `server_names` from `allowed-domains.txt`, sets the iptables redirect (default-deny, DNS pinned, Envoy-uid exempt), launches Envoy, self-tests.
