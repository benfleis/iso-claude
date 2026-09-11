# Data zones: host-private, guest-private, shared

Where things belong, independent of where they happen to live today. "Host" is the docker host and
its user (the uid the sessions exec as); "guest" is the iso-claude container; "shared" is the
`/opt/workspace` bind mount (plus the Claude state mount, see below).

| Zone | Rule | What lives here |
| --- | --- | --- |
| **Host-private** | The guest never sees it, and it controls the guest | Persistent credentials (`~/.local/state/iso-claude-launcher/.env`), launcher settings (`~/.config/iso-claude/.env`), ssh keys, host dotfiles, **the iso-claude checkout** |
| **Guest-private** | Rebuilt from the Dockerfile; losing it on a recreate is fine | Toolchains (rustup, cargo binaries, uv, node, Claude Code), apt packages, the image-baked `$HOME` dotfiles and oh-my-zsh, `/tmp`, the live firewall state |
| **Shared** | Real data both sides read and write | `src/` and worktrees, build trees, Claude's state, tasks and the archive, caches, the guest's shell config and git identity (`config/`) |

**Placing something new:** if a rebuild wiping it is fine, it's guest-private. If the host
executes or trusts it, it's host-private. Everything else is shared.

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

## Guest-private

Everything under the container's `$HOME` (`/home/iso-claude`) except the Claude state mount is image
content in the container's writable layer: it survives a restart and is **lost on a recreate**
(`iso-compose build` + `up`, or `--force-recreate`). That's intended for toolchains, which the
Dockerfile pins and rebuilds. Anything worth keeping must point into the shared mount instead:
caches (below), shell config (`config/zsh/env-local`, `config/zsh/rc-local`, sourced by the baked
dotfiles), zsh history (`state/zsh_history`), git identity (`~/.config/git` →
`/opt/workspace/config/git`).

## Shared

- **Claude's state** is its own mount (`$CLAUDE_STATE_DIR` → `/home/iso-claude/.claude-state`,
  `CLAUDE_CONFIG_DIR`). Pointing `CLAUDE_STATE_DIR` inside `/opt/workspace` (e.g.
  `/opt/workspace/state/iso-claude`) is fine: the session can already read and write it via
  `~/.claude-state`. Never share one `.claude.json` between two live instances; it's rewritten
  whole, without locking.
- **Identical paths on both sides.** `/opt/workspace` is mounted at the same path, so git's
  absolute paths, build trees, and Claude's dash-encoded project dirs match inside and out.
- **The root is read-only; everything lands in a named subdir.** `/opt/workspace` itself is
  root-owned; writable data goes in `src/`, `build/`, `cache/`, `config/` or `state/`. Anything
  that tries to write at the root (a stray relative path, a lock file, Claude's project-scope
  `.claude/`) fails instead of leaving unplaced crud.
- **Shared, guest-editable config: the host must not load it.** `config/zsh/env-local`,
  `config/zsh/rc-local` and anything else under `/opt/workspace` can be rewritten by a session.
  The host never sources them; host-side settings (including the cache env below) go in host
  dotfiles. Building on the host runs guest-authored code too (CMake files, `build.rs`); that is the
  README's "trusted repos only" caveat, not something the zones fix.

### Caches

All caches live under `/opt/workspace/cache/`, one dir per tool, and both the guest and host-side
builds use them:

```
cache/
  cargo/registry  cargo/git   # cargo has no XDG/cache env: ~/.cargo/{registry,git} are symlinks
  sccache/                    # SCCACHE_DIR
  uv/  pip/  npm/             # UV_CACHE_DIR, PIP_CACHE_DIR, npm_config_cache
  vcpkg/                      # VCPKG_DEFAULT_BINARY_CACHE
```

The guest sets these in the image (`ENV`, so non-interactive shells and Claude's Bash tool see
them); the host sets the same in its own dotfiles. What sharing them assumes:

- **One kernel, so locks coordinate.** Host and guest share the kernel; `flock`s taken through the
  bind mount (cargo's package-cache lock, the `dbuild` lock) exclude each other.
- **Same toolchain on both sides, or no hits.** sccache keys on the compiler binary and cargo on
  the rustc version. The image is Ubuntu 26.04 to match the host: keep them in step by rebuilding
  with `iso-compose build --pull --no-cache` after host upgrades, and pin rustc and the sccache
  release to the same versions on both sides.
- **Two sccache daemons, one dir.** Each tracks the cache size on its own, so the pair can overshoot
  `SCCACHE_CACHE_SIZE`. Entries are written atomically, so this costs disk, not correctness.
