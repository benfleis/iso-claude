# iso-claude

A sandboxed [Claude Code](https://claude.com/claude-code) environment for an
always-on box, safe enough to run unattended (including
`--dangerously-skip-permissions`) because **egress is locked down to an
allowlist**.

## Quick start

Needs Docker (with Compose). From a clone of this repo:

```bash
./bin/iso-compose build     # not plain `docker compose`: see Setup below
./bin/iso-claude            # first run builds the allowlist, then launches Claude
```

On first launch, run `/login`: it prints a URL — open it in any browser, paste
the code back. The credential is stored in Claude's state dir and refreshes on
its own (`platform.claude.com` is allowlisted). It's a full account login, so
Remote Control and claude.ai session links work. For an inference-only token
instead, see **Token mode** below.

That's it — the first launch brings the container up, populates the egress
firewall, and drops you into Claude as your own user. Put `bin/` on your `PATH`
to run `iso-claude` / `iso-shell` from anywhere. Everything below is detail.

## Goal

Maximum context (broad read access) with minimum blast radius (tight
write/egress). An agentic coding tool is attacker-steerable — the "lethal
trifecta" is an LLM + code execution + untrusted content (a repo, a fetched web
page, an MCP tool result carrying a prompt injection). The **egress allowlist
firewall is the primary containment**: even if the agent is fully compromised,
it can only talk to a short list of approved hosts, so it can't exfiltrate or
phone home.

Isolation comes in two layers: the dedicated box is the outer boundary; a
per-project container is the inner one. The container is what makes unattended
bypass-permissions mode acceptable — *given* the locked egress.

## How it works

The container is a **disposable execution jail invoked like a command**, not a
place you live in. Persistence (tmux, shells) stays on the host; each
`iso-claude` invocation is an independent Claude session sharing one container,
a `/opt/workspace` bind-mount, the read-only `/opt/tooling` toolchains, and one firewall.

```
host ── bin/iso-claude ──▶ docker compose exec --user <you> claude …
                               │
                               ▼
                     ┌─────────────────────────────┐
   bin/iso-firewall  │ container (PID 1 = root)     │
   (host reconcile) ─┼─▶ ipset "allowed-domains"    │
   resolves domains  │   iptables default-DROP      │
   on the HOST, then │   egress ⇒ allowlist only    │
   swaps the set     │   session runs as your UID   │
                     └─────────────────────────────┘
```

### Security properties

- **Default-deny egress.** `init-firewall.sh` installs an iptables
  default-`DROP` policy plus one rule allowing only IPs in the `allowed-domains`
  ipset. Everything else is rejected.
- **Boots fail-closed, even offline.** The in-container firewall script does
  *zero* network I/O — it only lays down the static rules and an *empty*
  allowlist. The container can't self-block by trying to reach the network to
  configure the network, and comes up blocked-by-default until populated.
- **No bootstrap paradox.** The allowlist is resolved **on the host** by
  `bin/iso-firewall` and pushed into the container's ipset via `docker exec`.
  The container never needs egress to configure its own egress firewall.
- **Live, non-disruptive updates.** Reconciling the allowlist swaps the ipset
  atomically (`ipset restore` + `swap`); running Claude sessions are not
  interrupted. Edit `allowlist.conf`, run `iso-firewall`, done — no rebuild, no
  restart.
- **Fail-safe reconcile.** If resolution is degraded (a range source is
  unreachable, or the required Anthropic host won't resolve), the reconcile
  aborts and leaves the live set intact rather than push a set that strips
  working egress.
- **Least privilege.** `cap_drop: ALL` then re-add only `NET_ADMIN`/`NET_RAW`
  (for iptables), `no-new-privileges: true`, sessions run as your host UID
  (root is only PID 1, needed to install the firewall at boot).

### State, dotfiles & persistence

The in-container user is **`iso-claude`**, with uid/gid baked in at build time
from `ISO_UID`/`ISO_GID` (default 1000; must match your host user). `HOME` is
its real home `/home/iso-claude` — so the image's dotfiles (the zsh prompt,
Claude Code) resolve normally. What must persist is decoupled from `HOME`:

- **Claude's durable state** (config, auth, project trust, history, sessions)
  lives inside the workspace (`$CLAUDE_STATE_DIR`, default
  `$CLAUDE_WORK_DIR/state/iso-claude`); `CLAUDE_CONFIG_DIR` points at it, so it
  survives rebuilds.
- **Toolchains apt can't supply at the right version** (rust, uv, go, sccache)
  are one shared, root-owned copy in `/opt/tooling`, mounted read-only, with one
  env file both sides source; see [tooling/README.md](tooling/README.md).
- **Your personal shell config** lives in the bind-mounted workspace as
  `/opt/workspace/config/zsh/env-local` and `/opt/workspace/config/zsh/rc-local`,
  sourced by the baked dotfiles if present — persistent and host-editable
  without rebuilding. Git identity is `config/git` (`~/.config/git` links to
  it); zsh history is `state/zsh_history`.

What belongs host-private, guest-private, or shared (credentials, the checkout
itself, caches, shell config), and why, is in
[docs/data-zones.md](docs/data-zones.md).

## Layout

| File | Role |
| ------ | ------ |
| `docker-compose.yaml` | Service definition, capabilities, hardening, bind-mount |
| `Dockerfile` | Ubuntu 26.04 base + build toolchain + Claude Code + firewall scaffolding |
| `entrypoint.sh` | Runs `init-firewall.sh` as root at boot, then idles |
| `init-firewall.sh` | In-container **scaffolding only** — static rules + empty ipset |
| `bin/iso-firewall` | **Host-side reconcile** — resolves the allowlist and applies it |
| `bin/iso-claude` | Launch a Claude session in the sandbox |
| `bin/iso-shell` | Drop into an interactive shell in the sandbox |
| `bin/iso-compose` | `docker compose` with the launcher settings loaded (build, down, logs) |
| `allowlist.conf` | The egress allowlist (host-editable) |
| `.env-example` | Copy to `~/.config/iso-claude/.env`; sets `CLAUDE_WORK_DIR`, `ISO_UID`, … |
| `docs/` | `data-zones.md` (what's host-private / tooling / guest-private / shared), `SNI-filtering.md` |
| `tooling/` | The shared toolchains: `install.sh`, `mise.toml` + `mise.lock`, `env.sh` (installed to `/opt/tooling`) |

## Usage

**Setup**

```bash
mkdir -p ~/.config/iso-claude
cp .env-example ~/.config/iso-claude/.env   # set CLAUDE_WORK_DIR, ISO_UID etc.
iso-compose build

# Optional, token mode instead of /login (see below): mint a token and stash it
# in the launcher's secrets file (0600). GH_TOKEN=… for `gh` goes here too.
claude setup-token              # on the host, or any machine with Claude Code
mkdir -p -m 700 ~/.local/state/iso-claude-launcher
{
  echo "# minted_at: $(date -Idate)  expires_at: $(date -d '+1 year' -Idate)"
  echo "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-…"
} > ~/.local/state/iso-claude-launcher/.env
chmod 600 ~/.local/state/iso-claude-launcher/.env
```

Run compose through **`iso-compose`**, never plain `docker compose`: only the
`bin/` scripts load `~/.config/iso-claude/.env`. A plain build bakes in uid 1000
(the launcher then refuses the image), and a plain `up` can see different mounts
and recreate the container under your running sessions.

**Token mode.** Setting `CLAUDE_CODE_OAUTH_TOKEN` switches `iso-claude` from
`/login` to the token, forwarded fresh on every exec. A `setup-token` OAuth
token is valid for **one year** and is *inference-only* (it can't drive Remote
Control). Claude Code
shows **no expiry warning** for this token type — hence the `# minted_at /
expires_at` note above; set a reminder to rotate. If a token leaks, note that
**rotating ≠ revoking**: minting a new one leaves the old one valid for its full
year. To actually kill it, log out of all sessions (claude.ai → Settings →
Account → Active sessions), then confirm it's dead with
`CLAUDE_CODE_OAUTH_TOKEN='<old>' claude -p hi` returning a 401; escalate to
Anthropic support if it still works.

**Run** (put `bin/` on your `PATH`, or call by path)

```bash
iso-claude                      # a Claude session in the jail
iso-claude -p "…"               # non-interactive
iso-shell                       # interactive shell in the jail
```

Both wrappers bring the container up, populate the allowlist if empty, and drop
you in as your own UID.

**Unattended ("YOLO") mode.** To skip permission prompts, pass
`--dangerously-skip-permissions` (it rides through the wrapper's `"$@"`):

```bash
iso-claude --dangerously-skip-permissions
```

To make it the default, uncomment the YOLO `exec` line in `bin/iso-claude`
(and comment the default one). This is only defensible because egress is
allowlist-locked and the session is contained — see [Goal](#goal) and
[Caveats](#caveats). Don't point it at adversarial content.

**Manage the allowlist**

```bash
$EDITOR allowlist.conf          # add/remove entries
iso-firewall                    # reconcile (live; sessions keep running)
iso-firewall --dry-run          # report pending changes; exit 10 if any
```

### The allowlist

`allowlist.conf` takes three kinds of entries:

- `@source` — pull in a provider's **published IPv4 ranges**
  (`@github`, `@fastly`, `@cloudflare`, `@aws-cloudfront`).
- `1.2.3.0/24` or `1.2.3.4` — raw IP/CIDR, used verbatim.
- `example.com` — hostname, resolved on the host.

**Why the `@` directives:** CDN-fronted services (crates.io, pypi.org, npm) are
GSLB/geo-balanced across whole CDNs — a hostname's IPs rotate between providers,
so resolving it can never pin the target. Allowing the provider's published
ranges makes them reliable. **Tradeoff:** those ranges are CDN-wide (`@fastly`
= every Fastly-hosted site), which widens egress. Comment a directive out to
tighten containment at the cost of per-IP flapping for that provider. See
[Future work](#future-work) for the hostname-precise alternative.

## Caveats

- **Trusted repos only.** The container isolates the *host* from the agent, but
  a malicious repo could still exfiltrate container contents (including Claude's
  creds) to any allowlisted host. Don't run untrusted code in it.
- **The bind-mount is the one deliberate hole.** `/opt/workspace` maps to a
  single host directory. Never widen it to `$HOME` or `/`; copy files into the
  work dir instead.
- **CDN breadth vs. precision.** With the `@cdn` directives on, egress reaches
  anything on those CDNs. That's a deliberate reliability/containment trade — the
  tight-and-reliable fix is below.
- **Auth modes don't mix.** `/login` stores a credential in Claude's state dir
  (`$CLAUDE_CONFIG_DIR/.credentials.json`), and Claude *prefers it over*
  `CLAUDE_CODE_OAUTH_TOKEN`. So in token mode, `iso-claude` moves any stored
  credential aside on each launch (to `….credentials.json.shadowed-*.bak`) so the
  token wins; to go back to `/login`, unset the token. A 401 "Please run /login"
  with `/login` in use usually means `platform.claude.com` (refresh) dropped off
  the allowlist — run `iso-firewall`.

## Future work

### SNI-filtering egress proxy

IP-allowlisting fundamentally can't be both tight *and* reliable against shared
CDNs: you either chase rotating per-domain IPs (tight but flaky) or allow whole
CDN ranges (reliable but broad). The correct fix is to filter egress by **TLS
SNI hostname** instead of by IP:

- Route all container egress through a filtering proxy (host-side or sidecar).
- The proxy allows connections by SNI (`crates.io`, `pypi.org`, …) and rejects
  everything else — regardless of which CDN/IP currently serves the host.
- The iptables policy tightens to "only the proxy" for outbound 443/80.

This gives hostname-precise containment (`crates.io` allowed, the rest of Fastly
not) *and* immunity to IP rotation, at the cost of running a proxy and handling
TLS SNI inspection. Tracked as a separate piece; the current ipset approach is
the pragmatic baseline until then.
