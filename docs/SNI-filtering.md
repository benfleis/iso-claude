# SNI-filtering egress + host closure — handoff

Status as of 2026-07-26. **Prototype, not yet verified end-to-end.** Written to
be picked up *outside* the sandbox container (where you have `NET_ADMIN` and can
rebuild/recreate the container without killing the working session). Everything
below is added to the working tree but **not committed**.

## Why

Two holes were found in the existing IP-allowlist firewall:

1. **The IP allowlist can't be both tight and reliable against shared CDNs.**
   `allowlist.conf`'s `@fastly`/`@cloudflare`/`@aws-cloudfront` directives admit
   whole CDN ranges — measured at **~6.1M addresses across 319 prefixes**. Since
   anyone can front an arbitrary domain with Cloudflare for free, `@cloudflare`
   alone is a general-purpose exfil channel to an attacker-chosen endpoint. An
   IP allowlist *structurally* cannot tell `crates.io` apart from `evil.com`
   when both resolve into the same Fastly/Cloudflare prefix.

   Confirmed live from inside the container before any changes: `example.com`
   (Cloudflare) and `api.openai.com` (Cloudflare) and `www.kernel.org` (Fastly)
   were all reachable purely because they sit in admitted CDN ranges, while
   `google.com`, `duckduckgo.com`, raw `8.8.8.8:53` etc. were correctly blocked.

2. **The host gateway was blanket-accepted**, handing the sandbox every service
   on the host. Live scan of the bridge gateway `172.18.0.1` found `22` (host
   sshd) and `8080` both OPEN — a full escape the moment an ssh key lands in the
   bind-mounted workspace (and `.zshenv-local` is built around push-over-ssh, so
   a key arriving is a matter of time).

Two residual holes neither change closes, by design (see Limitations): domain
fronting and DNS-label exfil.

## The two mechanisms

### 1. Name-based egress — `bin/iso-sniproxy` + `proxy-allowlist.conf`

A **host-side transparent proxy** that filters on the name the client asks for
rather than the resolved IP:

- **tcp/443** — parse the TLS ClientHello, take the SNI extension.
- **tcp/80** — parse the request head, take the `Host:` header.

Design decisions, and why:

- **Transparent (DNAT), not `HTTPS_PROXY`.** An env-var proxy is opt-in per
  process; anything that ignores the var goes direct. With DNAT there is no
  bypass to ignore — direct egress on 443/80 no longer exists in the container.
- **No MITM.** After the allow decision the proxy resolves the requested name
  itself and splices raw bytes. Cert pinning and mTLS keep working. Lying about
  the name gains nothing: the proxy connects to whatever name the client
  *claimed*, so `SNI=crates.io` to reach `evil.com` just gets you crates.io.
- **Private-IP guard.** An allowlisted name whose DNS answers `127.0.0.1`/`10.x`
  would otherwise reach back into the host we just closed. Upstreams that resolve
  only to private/loopback/link-local/reserved addresses are denied. Override
  with `--allow-private` (prints a warning).
- **Live allowlist.** `proxy-allowlist.conf` is re-read on every connection when
  its mtime changes — edits are live, no restart, running sessions unaffected.
  Stdlib-only Python 3, so nothing to install on the host.
- **Match semantics, no implicit widening.** `example.com` = the apex only;
  `*.example.com` = subdomains at any depth but **not** the apex. List both when
  you want both. (An allowlist that silently matches more than it says is worse
  than none.)

Runs on the host bound to the docker bridge gateway. `contrib/iso-sniproxy.service`
is a systemd unit (DynamicUser, no privilege needed — binds a high port, talks
to the internet).

### 2. Host closure — `hostports.conf` + `bin/iso-hostports`

`init-firewall.sh` no longer blanket-accepts the gateway. A second ipset
`allowed-host-ports` (`hash:ip,port`) holds deliberately-opened host services,
reconciled live from the host by `iso-hostports` — same shape and guarantees as
`iso-firewall` (declarative file → atomic ipset swap → verify, sessions never
interrupted).

```bash
iso-hostports --add 5432 postgres for the ducklake tests
iso-hostports --list
iso-hostports --del 5432
$EDITOR hostports.conf && iso-hostports    # or edit declaratively
```

Format `<port>[/<proto>] [<ip>]`, defaulting to tcp on the bridge gateway.
Notes:
- Empty desired set is **legitimate** here (it's the steady state = no host
  access), so unlike `iso-firewall` it does not abort on empty.
- The gateway IP is *asked of the container* (`ip route`), not guessed, so a
  docker network renumber can't silently point exceptions at the wrong address.
- Asymmetry vs the domain allowlist: an entry grants a whole port to anything in
  the container, with no name-level check behind it. Keep the list short.

## Files

| File | State | Role |
| --- | --- | --- |
| `bin/iso-sniproxy` | **new** | Host-side transparent SNI/Host proxy (Python 3, stdlib only) |
| `proxy-allowlist.conf` | **new** | Name allowlist for the proxy (live-reloaded) |
| `bin/iso-hostports` | **new** | Host-side reconcile for host-gateway port exceptions |
| `hostports.conf` | **new** | Declarative host-port exceptions (starts empty = closed) |
| `contrib/iso-sniproxy.service` | **new** | systemd unit for the proxy |
| `init-firewall.sh` | modified | 2nd ipset `allowed-host-ports`; gateway no longer blanket-accepted; `ISO_SNI_PROXY` DNAT via `ISO_PROXY_REDIR` nat chain |
| `docker-compose.yaml` | modified | `ISO_SNI_PROXY` + `*_TLS_PORT`/`*_HTTP_PORT` passthrough (default 0/18443/18080) |
| `bin/iso-common.sh` | modified | reconcile hostports on launch; warn if proxy mode on but nothing listening |
| `allowlist.conf` | modified | note that `@cdn` directives are dead weight under proxy mode |
| `.env-example` | modified | `ISO_SNI_PROXY` knobs |
| `README.md` | modified | new "SNI-filtering egress proxy" + "Host access" sections; security-properties + caveats updated |

## How the firewall wiring fits together

`init-firewall.sh` (in-container, root, at boot) after the changes:

- Creates both ipsets empty (`allowed-domains`, `allowed-host-ports`).
- Detects the host gateway but **does not** accept it wholesale.
- default-DROP; ESTABLISHED/RELATED accepted.
- `allowed-host-ports` matched with `dst,dst` (ip + port) for tcp and udp.
- If `ISO_SNI_PROXY=1`: a dedicated **`ISO_PROXY_REDIR` nat chain** RETURNs for
  loopback and the gateway, then DNATs 443→gateway:TLS_PORT and
  80→gateway:HTTP_PORT; filter-table ACCEPTs are added for the two proxy ports.
  A chain is used (not inline rules) because iptables takes only one `-d` per
  rule and the loopback+gateway exclusions must apply to both redirects.
- Then the usual `allowed-domains` ACCEPT + final REJECT.

So under proxy mode: 443/80 go to the host proxy (name-filtered); everything
else still falls to the IP allowlist; the host is reachable only on
`allowed-host-ports`.

## What was verified

Ran `iso-sniproxy` on loopback **inside** the container (no rebuild needed for
the proxy logic itself) and drove it with `curl --connect-to`:

```
ALLOW tls  -> crates.io:443       real API fetch returned serde 1.0.229 (up=255 down=439000)
ALLOW tls  -> api.github.com:443  200
DENY  tls  -> example.com         (not in allowlist)            curl rc=35
DENY  http -> example.com         (not in allowlist)            curl rc=52
DENY  tls  -> <garbage>           (not a TLS handshake record)
DENY  tls  -> localtest.me        (resolves only to non-public) private-IP guard
LIVE reload: appended example.com mid-flight -> next connection 200
```

Allowlist unit checks (`iso-sniproxy --check`): `crates.io`, `index.crates.io`,
`api.github.com`, `sub.deep.githubusercontent.com`, `api.anthropic.com` ALLOW;
`evil.com` and bare `githubusercontent.com` (apex, only `*.` listed) DENY.

`iso-hostports` `canonical()` parsing tested in isolation: accepts `5432`,
`9000/udp`, `8080 10.1.30.7`; rejects `0`, `70000`, `443/sctp`, `abc`. Config
line splitting (comment/blank strip) correct.

All scripts pass `bash -n` / `python3 -m ast`.

## What is NOT verified (do this on pickup)

**The DNAT path and the gateway closure have never been loaded into a kernel** —
both require `docker compose up -d --build`, which recreates the container and
would kill the authoring session. Syntax is as-correct-as-checkable without
`NET_ADMIN`, but expect to iterate on first boot.

Pickup checklist:

1. `cd /opt/workspace/src/iso-claude`
2. Confirm the bridge gateway matches the systemd unit's `--bind`:
   `docker network inspect iso-claude_default -f '{{(index .IPAM.Config 0).Gateway}}'`
   (was `172.18.0.1`). Fix `contrib/iso-sniproxy.service` if different.
3. Install + start the proxy **first**:
   `sudo cp contrib/iso-sniproxy.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now iso-sniproxy`
   Check `journalctl -u iso-sniproxy -f` shows `listening on …`.
4. Rebuild/recreate so the new `init-firewall.sh` runs:
   `docker compose up -d --build`. (Before setting the flag, this also creates
   the `allowed-host-ports` set so `iso-hostports` stops aborting.)
5. Verify host closure from inside: `iso-shell`, then confirm `22`/`8080` on the
   gateway are now refused; `iso-hostports --add <port>` and re-confirm reachable.
6. Enable proxy mode: `echo 'ISO_SNI_PROXY=1' >> ~/.config/iso-claude/.env`
   then `docker compose up -d` (recreates). From `iso-shell`:
   - allowed name (e.g. `curl -sI https://crates.io`) works;
   - non-allowlisted 443 (e.g. `https://example.com`) is refused;
   - watch `journalctl -u iso-sniproxy` for the ALLOW/DENY lines.
7. Once proxy mode is confirmed, drop the now-redundant `@cdn` directives from
   `allowlist.conf` (keep `@github` if you use git-over-SSH; the proxy does not
   cover 22) and `iso-firewall` to reconcile.

Gotcha: until step 4, `iso-hostports` aborts on every launch because
`allowed-host-ports` doesn't exist in the currently-running (pre-change)
container. That abort is the intended signal, not a failure.

## Known limitations (documented in README too)

- **Domain fronting.** A client can present `SNI=crates.io` then send
  `Host: evil.com` inside the TLS session. Most large CDNs reject the mismatch,
  but the proxy can't see inside TLS without MITM. Not closed.
- **DNS is still a channel.** The container resolves via Docker's embedded DNS
  (`127.0.0.11`) which forwards to the host resolver; data can leave in
  subdomain labels regardless of this proxy.
- **HTTP/3 / QUIC** (UDP 443) is not redirected — it's simply blocked, fine for
  the tooling here (everything falls back to TCP).
- Only 443/80 are name-filtered; other ports still fall to `allowed-domains`.

## Open questions for pickup

- Bridge gateway address is assumed `172.18.0.1`. If the compose project/network
  name differs on the target host, both the systemd `--bind` and the DNAT target
  must agree — the container-side detection is dynamic, but the host-side proxy
  bind is static in the unit. Consider deriving it in the unit's `ExecStart` if
  it drifts.
- Should `iso-firewall` learn to auto-drop the `@cdn` directives (or warn) when
  `ISO_SNI_PROXY=1`, so the two allowlists can't silently disagree?
- Proxy has no persistent log rotation — it logs to journald via systemd, which
  is fine, but there's no metrics/denied-count surfacing beyond grepping the
  journal.
