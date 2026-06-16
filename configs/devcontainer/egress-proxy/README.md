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

## Enable it

1. **Dockerfile** — install Envoy and create an unprivileged user to run it:
   ```dockerfile
   # install envoy (pin a version), then:
   RUN useradd --system --no-create-home envoyproxy
   COPY egress-proxy/ /usr/local/share/egress-proxy/
   ```
2. **Run the proxy init instead of the IP firewall** in `devcontainer.json`:
   ```jsonc
   "postStartCommand": "sudo /usr/local/share/egress-proxy/init-egress-proxy.sh"
   ```
   (Keep `--cap-add=NET_ADMIN`/`NET_RAW` in `runArgs`.)
3. Rebuild the container.

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
