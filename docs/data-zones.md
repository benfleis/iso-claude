# Data zones: host-private, tooling, guest-private, shared

Where things belong, independent of where they happen to live today. "Host" is the docker host and
its user (the uid the sessions exec as); "guest" is the iso-claude container; "shared" is the
`/opt/workspace` bind mount; "tooling" is `/opt/tooling`, mounted read-only.

| Zone | Rule | What lives here |
| --- | --- | --- |
| **Host-private** | The guest never sees it, and it controls the guest | Persistent credentials (`~/.local/state/iso-claude-launcher/.env`), launcher settings (`~/.config/iso-claude/.env`), ssh keys, host dotfiles, **the iso-claude checkout** |
| **Tooling** | One copy both sides run; root-owned, read-only to the guest | Toolchains apt can't supply at the right version: rust, uv, go, sccache, and their env (`/opt/tooling/env.sh`) |
| **Guest-private** | Rebuilt from the Dockerfile; losing it on a recreate is fine | apt packages, node and Claude Code, the image-baked `$HOME` dotfiles and oh-my-zsh, `/tmp`, the live firewall state |
| **Shared** | Real data both sides read and write | `src/` and worktrees, build trees, Claude's state, tasks and the archive, caches, the guest's shell config and git identity (`config/`) |

**Placing something new:** if a rebuild wiping it is fine, it's guest-private. If the host
executes or trusts it, it's host-private, or tooling if the guest runs it too. Everything else is
shared.

## Host-private

- **Credentials are ferried, not stored.** Tokens (`CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN`) live
  host-side in the 0600 secrets file and reach a session per exec via `-e`, never via
  `docker-compose.yaml`. A ferried token is still readable inside that session (it's in the process
  env); the point is that the guest can't persist or enumerate anything you didn't hand it. Scope
  each token to what a session needs.
- **Anything the host executes stays out of the guest's reach.** The `bin/` wrappers run on the
  host as you, and `iso-compose build` runs this Dockerfile. If the checkout sat in the shared
  mount, a compromised session could edit `bin/iso-claude` or `allowlist.conf` and the host would
  run the change on the next launch. So the checkout lives host-side, outside `/opt/workspace`
  (`COMPOSE_DIR` in `bin/` points at it).
- **Exception: the `/login` credential.** `/login` writes `.credentials.json` into Claude's state
  dir and refreshes it there, so it is necessarily guest-visible and persisted in the shared state.
  That's the price of a full account login (Remote Control, claude.ai session links); token mode
  avoids it but is inference-only. The state dir is 0700, re-asserted by the launcher on every run.

## Tooling

`/opt/tooling` holds the toolchains apt can't supply at the right version, installed once per box
by `tooling/install.sh` from a pinned `mise.toml` + `mise.lock` (`tooling/README.md`).

- **Both sides run the same bytes.** Same Ubuntu, same paths: sccache keys, cargo targets and venvs
  built on one side work on the other.
- **Root-owned, read-only to the guest.** Both sides execute these binaries, so no session, in the
  guest or as the host user, may change them; `rustup` or `uv self update` fail loudly instead of
  drifting from the lock. Updates go through `sudo tooling/install.sh`.
- **One env source.** `/opt/tooling/env.sh` sets `TOOLING_ROOT`, `WORKSPACE_ROOT`, `PATH` and each
  tool's homes. The host's shell startup and the guest's `~/.zshenv` both source it, so the two
  can't diverge.
- **Nothing writes here.** Runtime data goes to the shared cache (below).

## Guest-private

Everything under the container's `$HOME` (`/home/iso-claude`) is image content in the container's
writable layer: it survives a restart and is **lost on a recreate** (`iso-compose build` + `up`, or
`--force-recreate`). That's fine for what the image installs. Anything worth keeping must point into
the shared mount instead: caches (below), shell config (`config/zsh/env-local`,
`config/zsh/rc-local`, sourced by the baked dotfiles), zsh history (`state/zsh_history`), git
identity (`~/.config/git` → `/opt/workspace/config/git`).

The image locks the `$HOME` defaults the env replaces (`~/.claude`, `~/.cache`, `~/.npm`,
`~/.cargo`, `~/.rustup`: empty, root-owned, read-only), so a tool that ignores the env fails loudly
instead of writing where a recreate loses it.

## Shared

- **Claude's state** lives inside the workspace (`$CLAUDE_STATE_DIR`, default
  `$CLAUDE_WORK_DIR/state/iso-claude`), and `CLAUDE_CONFIG_DIR` points at it directly.
  `~/.claude-state` is only a link to it, kept because Claude's own records store absolute paths
  under it. Never share one `.claude.json` between two live instances; it's rewritten whole,
  without locking.
- **Identical paths on both sides.** `/opt/workspace` is mounted at the same path, so git's
  absolute paths, build trees, and Claude's dash-encoded project dirs match inside and out.
- **The root is read-only; everything lands in a named subdir.** `/opt/workspace` itself is
  root-owned; writable data goes in `src/`, `build/`, `cache/`, `config/` or `state/`. Anything
  that tries to write at the root (a stray relative path, a lock file, Claude's project-scope
  `.claude/`) fails instead of leaving unplaced crud.
- **Shared, guest-editable config: the host must not load it.** `config/zsh/env-local`,
  `config/zsh/rc-local` and anything else under `/opt/workspace` can be rewritten by a session.
  The host never sources them; its settings go in host dotfiles, and its tool env comes from
  `/opt/tooling/env.sh`. Building on the host runs guest-authored code too (CMake files,
  `build.rs`); that is the README's "trusted repos only" caveat, not something the zones fix.

### Caches

All caches live under `/opt/workspace/cache/`, one dir per tool, and both the guest and host-side
builds use them:

```
cache/
  cargo/            # CARGO_HOME: registry, git checkouts, `cargo install` output
  go/               # GOPATH, GOMODCACHE, GOCACHE
  sccache/          # SCCACHE_DIR
  uv/  uv-python/   # UV_CACHE_DIR, UV_PYTHON_INSTALL_DIR
  npm/              # npm_config_cache (guest)
  vcpkg-archives/   # VCPKG_BINARY_SOURCES (config/zsh/env-local)
```

The tool caches come from `/opt/tooling/env.sh` on both sides; `XDG_CACHE_HOME` and npm's cache are
set in the image. What sharing them assumes:

- **One kernel, so locks coordinate.** Host and guest share the kernel; `flock`s taken through the
  bind mount (cargo's package-cache lock, the `dbuild` lock) exclude each other.
- **Same toolchain on both sides, or no hits.** sccache keys on the compiler binary and cargo on
  the rustc version. rust and sccache come from `/opt/tooling`, so they match by construction;
  gcc and clang are apt packages on both sides, so rebuild the image with
  `iso-compose build --pull --no-cache` after host upgrades to keep them in step.
- **Two sccache daemons, one dir.** Each tracks the cache size on its own, so the pair can overshoot
  `SCCACHE_CACHE_SIZE`. Entries are written atomically, so this costs disk, not correctness.
