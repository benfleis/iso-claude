# iso-claude

A sandboxed [Claude Code](https://claude.com/claude-code) environment for an
always-on box, safe enough to run unattended (including
`--dangerously-skip-permissions`) because **egress is locked down to an
allowlist**.

## Quick start

Needs Docker (with Compose) and a Claude Code OAuth token. From a clone of this
repo:

```bash
docker compose build

# Drop in an OAuth token. Mint it anywhere with `claude setup-token` (NOT inside
# the sandbox — the firewall would block the login flow), or reuse an existing
# one. Using a token only needs api.anthropic.com, which is already allowlisted.
# setup-token OAuth tokens are valid for one year; the file is sourced by the
# wrappers, so the '#' minted/expires line is just a note-to-self (no expiry
# warning is shown for this token type — see Token lifetime below).
mkdir -p ~/.config/iso-claude
{
  echo "# minted_at: $(date -Idate)  expires_at: $(date -d '+1 year' -Idate)"
  echo "export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-…"
} > ~/.config/iso-claude/.env

./bin/iso-claude            # first run builds the allowlist, then launches Claude
```

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
a `/opt/workspace` bind-mount, a separate state mount, and one firewall.

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

The in-container user is **`iso-claude`** (uid 1000), and `HOME` is its real
home `/home/iso-claude` — so the image's dotfiles and toolchains (cargo, uv,
rustup, the zsh prompt) resolve normally. Two things are decoupled from `HOME`:

- **Claude's durable state** (config, auth, project trust, history, sessions)
  is redirected via `CLAUDE_CONFIG_DIR` to a **separate mount**
  (`$CLAUDE_STATE_DIR` → `/home/iso-claude/.claude-state`), so it survives
  rebuilds and stays out of your project files. `/opt/workspace` holds *only*
  your code.
- **Your personal shell config** lives in the bind-mounted workspace as
  `/opt/workspace/.zshenv-local` and `/opt/workspace/.zshrc-local`, sourced by
  the baked dotfiles if present — persistent and host-editable without
  rebuilding.

## Layout

| File | Role |
| ------ | ------ |
| `docker-compose.yaml` | Service definition, capabilities, hardening, bind-mount |
| `Dockerfile` | `node:22` base + build toolchain + Claude Code + firewall scaffolding |
| `entrypoint.sh` | Runs `init-firewall.sh` as root at boot, then idles |
| `init-firewall.sh` | In-container **scaffolding only** — static rules + empty ipset |
| `bin/iso-firewall` | **Host-side reconcile** — resolves the allowlist and applies it |
| `bin/iso-claude` | Launch a Claude session in the sandbox |
| `bin/iso-shell` | Drop into an interactive shell in the sandbox |
| `allowlist.conf` | The egress allowlist (host-editable) |
| `.env-example` | Copy to `.env`; sets `CLAUDE_WORK_DIR` / `CLAUDE_STATE_DIR` |

## Usage

**Setup**

```bash
cp .env-example .env            # set CLAUDE_WORK_DIR etc. for your machine
docker compose build

# Mint a dedicated OAuth token OUTSIDE the sandbox (the firewall blocks the
# login flow inside it), then stash it where the wrappers look. Using the token
# only needs api.anthropic.com, which is allowlisted, so the jail works fine.
claude setup-token              # on the host, or any machine with Claude Code
mkdir -p ~/.config/iso-claude
{
  echo "# minted_at: $(date -Idate)  expires_at: $(date -d '+1 year' -Idate)"
  echo "export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-…"
} > ~/.config/iso-claude/.env
```

**Token lifetime & revocation.** A `setup-token` OAuth token is valid for
**one year** and is *inference-only* (it can't drive Remote Control). Claude Code
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
- **Don't run `/login` inside the sandbox.** Auth here is the
  `CLAUDE_CODE_OAUTH_TOKEN` env token. A `/login` writes a stored credential into
  Claude's state dir (`$CLAUDE_CONFIG_DIR/.credentials.json`), which Claude *prefers over the env
  token* — and once it expires it can't refresh (the refresh endpoint isn't on
  the allowlist), so Claude 401s with "Please run /login" and never falls back
  to the still-valid token. `iso-claude` guards against this: on each launch it
  moves any such stored credential aside (to `….credentials.json.shadowed-*.bak`)
  so the token always wins. If you ever see a 401 login prompt, a stale stored
  credential is the usual cause.

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
