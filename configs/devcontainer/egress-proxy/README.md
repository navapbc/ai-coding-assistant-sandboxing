# Devcontainer egress: HTTP CONNECT proxy (experimental, opt-in)

The default devcontainer firewall ([`../init-firewall.sh`](../init-firewall.sh)) resolves the allowlist to **IPs** at start and enforces with iptables. Simple and runs anywhere Docker does, but **fragile to CDN IP rotation** (drift → false denials; broad/shared ranges → over-permit). See `docs/threat-model.md` residual risk #3.

This directory is an **opt-in alternative** that filters egress by **hostname**, via an explicit **HTTP CONNECT forward proxy** (Envoy) — the same model the built-in Tier-1 proxies and `srt` use. It's **experimental and untested in CI**: a reviewed starting point; run the validation below before relying on it.

## How it works

All egress is forced through the proxy: clients use `HTTP(S)_PROXY=127.0.0.1:15001`, and iptables **default-denies** everything except the proxy's own outbound (so a client that ignores the proxy and dials directly is dropped — fails closed, not exfil). For HTTPS the client sends a **cleartext** `CONNECT host:443` to the proxy; only **CONNECT authorities on the allowlist** are tunnelled (TLS passed through, not terminated), everything else gets `403`. The `server_names`/authorities are regenerated from [`../allowed-domains.txt`](../allowed-domains.txt) at start — same list as the IP firewall, no new place for domains.

## What it does / does not protect

| | This CONNECT proxy | Default IP firewall | TLS termination (Docker Sandboxes) |
|---|:--:|:--:|:--:|
| CDN **IP drift** / shared-IP over-permit | ✅ fixed (hostname) | ❌ | ✅ |
| **ECH** (encrypted SNI) | ✅ **fixed** | ✅ n/a (IP) | ✅ |
| **Domain fronting** (inner `Host` ≠ outer) | ❌ no | ❌ no | ✅ yes |

### ECH — solved by CONNECT

ECH (Encrypted Client Hello) encrypts the real SNI, which blinds a *transparent SNI* filter. A CONNECT proxy is immune: the client declares the destination in the **cleartext `CONNECT host:443`** line *before* any TLS, so the proxy allowlists on that — the encrypted inner SNI is never needed. An agent can't use ECH to reach a non-allowlisted host, because the TCP tunnel goes to the cleartext CONNECT host it named. (This is the main reason to prefer CONNECT over the transparent-SNI approach — no DNS `ech`-strip workaround required.)

### Domain fronting — still not solved

Fronting is an *inner-`Host`* attack and CONNECT gates the *outer* host. An agent can `CONNECT frontable-cdn:443` (allowlisted), then send `Host: evil` inside; if the front and target share that CDN's frontend, the CDN routes to evil. The proxy only saw the allowed CONNECT authority. Two mitigations, both already in play: (1) **don't allowlist frontable multi-tenant CDNs** — the [never-list](../../../docs/network-allowlists.md#never-allowlisted--and-why) bans `*.cloudfront.net`, `*.amazonaws.com`, `*.r2.dev`, `*.blob.core.windows.net`, so there's nothing to front *through*; (2) **TLS termination + `Host` allowlisting** — the only robust fix, i.e. [Docker Sandboxes](../../../docs/docker-sandbox.md), which remains the stronger tier.

## Enable it (two flags — no script edits)

The image and `init-firewall.sh` already support this; flip two values in `devcontainer.json` (and make sure this `egress-proxy/` dir is in your `.devcontainer/` build context):

1. **Build with Envoy** — `build.args.EGRESS_PROXY: "true"` (installs a pinned Envoy via `ENVOY_VERSION` + the `envoyproxy` run-as user; default `false` keeps the image lean).
2. **Select proxy mode** — `containerEnv.EGRESS_MODE: "proxy"` (`init-firewall.sh` hands off to this proxy; default `ipset` keeps the IP firewall). Keep `--cap-add=NET_ADMIN`/`NET_RAW`.

**Point clients at the proxy.** The init script writes `HTTP(S)_PROXY`/`NO_PROXY` to `/etc/environment` (best-effort, covers login shells). For reliable delivery to the agent/tools, also set them in `containerEnv`:
```json
"containerEnv": {
  "EGRESS_MODE": "proxy",
  "HTTP_PROXY": "http://127.0.0.1:15001", "HTTPS_PROXY": "http://127.0.0.1:15001",
  "NO_PROXY": "localhost,127.0.0.1,::1"
}
```
A tool that ignores the proxy can't reach the network (iptables blocks direct egress) — it fails closed, which is the safe outcome.

## Validate before relying

On a real build, confirm:
- `curl -x http://127.0.0.1:15001 -s -o /dev/null -w '%{http_code}\n' https://api.github.com/zen` → `200`.
- `curl -x http://127.0.0.1:15001 -s -o /dev/null -w '%{http_code}\n' https://example.com/` → `403` (CONNECT authority not allowlisted).
- A **direct** connection bypassing the proxy is dropped: `curl --noproxy '*' -s --max-time 5 https://example.com/` → fails.
- A domain added to `allowed-domains.txt` works after restart (regeneration wired up).
- Envoy version: the `@type` strings, the CONNECT/`dynamic_forward_proxy` wiring, and the vhost `domains` matching of the authority (`host` vs `host:443`, wildcard+port) match your installed Envoy. Check `/tmp/envoy-egress.log` and the admin page at `127.0.0.1:15000`.

## Simpler alternative: Squid

A pure CONNECT allowlist is a few lines in Squid (`dstdomain` is robust and easy to get right untested) — use this if the Envoy matching gives you trouble:
```squid
# /etc/squid/squid.conf  (allowed-domains: one host/line; ".foo.com" = wildcard)
acl allowed_hosts dstdomain "/etc/squid/allowed-domains.txt"
acl SSL_ports port 443
http_access allow CONNECT SSL_ports allowed_hosts
http_access deny all
http_port 15001
```
Same model, same egress lockdown (HTTP_PROXY + iptables default-deny), same ECH/fronting properties.

## Files

- [`envoy.yaml`](envoy.yaml) — Envoy as a CONNECT forward proxy: allowlist vhost (CONNECT authorities) + `dynamic_forward_proxy`, catch-all `403`.
- [`init-egress-proxy.sh`](init-egress-proxy.sh) — regenerates the authorities from `allowed-domains.txt`, sets the proxy env + iptables default-deny-except-proxy, launches Envoy, self-tests.
