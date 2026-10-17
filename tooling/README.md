# /opt/tooling

Shared toolchains for the host and the iso-claude container: **one copy, run by both**, so host
and guest use byte-identical binaries. That's what makes sccache keys, cargo target dirs, venvs and
build behaviour match across the two, by construction rather than by keeping two installs in step.

This directory in the iso-claude repo is the source; `install.sh` puts it in `/opt/tooling`.

## The approach

- **What lives here:** toolchains that don't come from Ubuntu's archive, or come too old: rust
  (rustup), uv, go, sccache, plus the C/C++ compiler and linker: clang/clang++ (conda-forge) and
  mold. The host is Amazon Linux 2023 and the container Ubuntu, so their distro compilers differ;
  conda's clang brings its own sysroot (glibc 2.34, matching the host) and libstdc++, so both
  sides compile against identical headers and container-built binaries run on the host. C++
  binaries get an RPATH into the clangxx install dir: rebuild after bumping it. Both `clang` and
  `clang++` come from the one `conda:clangxx` env and run with `config/clang.cfg` instead of
  conda's default config, which would put the env's own headers (GNU libiconv, zstd, ICU) ahead
  of the sysroot. Remaining distro
  tools (gcc, cmake, ninja, make, the `-dev` headers) stay system packages on each side.
- **Owned by root, installed and updated on the host with `sudo`.** Not writable by the host user,
  so no session, on the host or in the container, can alter binaries the host executes.
- **Read-only in the container**, bind-mounted at the identical path. Use compose's long form
  (`type: bind`, `read_only: true`): on this Docker the short `/opt/tooling:/opt/tooling:ro` form
  mounts nothing when source and target paths match. Updating is a host step; a session that needs
  a new toolchain, target or component asks for it.
- **Nothing writes here at runtime.** Caches and per-user data go to `$WORKSPACE_ROOT/cache/`. A
  tool that tries to write here fails loudly, which is intended.
- **Local disk, not backed up.** Everything here is reproducible from `mise.toml` + `mise.lock`;
  each box installs its own copy.

Where this sits among the other zones: `docs/data-zones.md`.

## Layout

```
/opt/tooling/
  README.md
  env.sh        source this, host and container; sets the roots and PATH, then env/*.sh
  env/          one file per tool: rust.sh, go.sh, uv.sh, sccache.sh
  bin/          the one PATH entry: links to every tool binary and rustup proxy, plus
                our scripts from tooling/bin/ (git-objects)
  config/       clang.cfg, the compiler config bin/clang and bin/clang++ use
  mise.toml     pinned versions
  mise.lock     resolved artifacts and their checksums
  mise/         mise itself (off PATH) and the installed uv, sccache, go
  rustup/       RUSTUP_HOME: the toolchains
  cargo/bin/    rustup's proxies (linked into bin/)
```

## Environment

One source for both sides, so they can't drift: `env.sh`, sourced by the host's shell startup and
by the container's `~/.zshenv`. It sets two roots, puts `$TOOLING_ROOT/bin` on `PATH`, and
sources `env/<tool>.sh`, which derive everything else from the roots.

| Root | Default |
| --- | --- |
| `TOOLING_ROOT` | `/opt/tooling` |
| `WORKSPACE_ROOT` | `/opt/workspace` |

| File | Sets |
| --- | --- |
| `env/rust.sh` | `RUSTUP_HOME` (here), `CARGO_HOME` (workspace cache) |
| `env/go.sh` | `GOTOOLCHAIN=local`, `GOPATH`, `GOMODCACHE`, `GOCACHE` |
| `env/uv.sh` | `UV_CACHE_DIR`, `UV_PYTHON_INSTALL_DIR` |
| `env/sccache.sh` | `SCCACHE_DIR` |

On the host, source it **last** in your shell startup, after anything else that edits `PATH` or
sets these variables, and set none of them yourself. `env.sh` leaves `PATH` alone when
`$TOOLING_ROOT/bin` is already on it, so move that entry to the front first:

```sh
path=( ${path:#/opt/tooling/bin} )   # zsh
. /opt/tooling/env.sh
```

Anything ahead of `bin/` (a user mise, `~/.local/bin` shims) leaks host-only paths into build
trees, and the container then refuses them. With a user mise on the host, also set
`MISE_IGNORED_CONFIG_PATHS=/opt/tooling`: this directory's `mise.toml` belongs to `install.sh`,
and without it any mise shim run with cwd under `/opt/tooling` stops at a trust prompt.

The host may source the workspace's `config/zsh/*` too: the container mounts `config/` read-only,
so a session cannot plant anything there.

Same binaries plus same paths is what lets one artifact serve both sides. A venv records its
interpreter's absolute path; with one `uv` and one `UV_PYTHON_INSTALL_DIR`, uv-managed Pythons live
at the same path on host and container, so a single `.venv` works in both. If either side falls
back to its own default (`~/.local/share/uv/python`), venvs built there dangle on the other. The
same goes for a distro Python (`/usr/bin/python3` differs per OS), so uv is told to use only its
own Pythons: `UV_PYTHON_PREFERENCE=only-managed` (set in the workspace's `config/zsh/env-local.zsh`).

## Shared git objects

`git-objects` keeps one copy of duckdb's git history for every clone, worktree and submodule
under `$WORKSPACE_ROOT/src`: a bare store at `$WORKSPACE_ROOT/state/git-objects/duckdb.git` that
fetches duckdb/duckdb and the fork and never prunes. Each duckdb object dir gets one absolute
alternate to it, the same path on both sides. `git-objects fetch` refreshes the store,
`git-objects scan` is the dry run, `git-objects sweep [path]` relinks and repacks; dbuild sweeps
the repo it builds. New submodules borrow at init:
`git submodule update --init --recursive --reference $WORKSPACE_ROOT/state/git-objects/duckdb.git`.

## Shared git objects

`git-objects` keeps one copy of duckdb's git history for every clone, worktree and submodule
under `$WORKSPACE_ROOT/src`: a bare store at `$WORKSPACE_ROOT/state/git-objects/duckdb.git` that
fetches duckdb/duckdb and the fork and never prunes. Each duckdb object dir gets one absolute
alternate to it, the same path on both sides. `git-objects fetch` refreshes the store,
`git-objects scan` is the dry run, `git-objects sweep [path]` relinks and repacks; dbuild sweeps
the repo it builds. New submodules borrow at init:
`git submodule update --init --recursive --reference $WORKSPACE_ROOT/state/git-objects/duckdb.git`.

## Pinned versions

`mise.toml` is authoritative; at the time of writing:

| Tool | Version |
| --- | --- |
| rust | 1.99.0 |
| uv | 0.12.13 |
| sccache | 0.17.0 |
| go | 1.27.1 |
| clang / clang++ | 23.1.3 (conda-forge) |
| mold | 3.0.0 |

## Install and update

On the host, as root:

```sh
sudo tooling/install.sh
```

It installs mise itself (pinned, checksum-verified, off `PATH`), copies this directory's config
and env files into place, runs `mise install` in locked mode (every artifact verified against
`mise.lock`; rustup verifies its own downloads), relinks `bin/`, and checks each tool through
`env.sh`. Re-running it is safe.

To add or bump a tool: edit `mise.toml`, run `tooling/lock.sh` (any user; it rewrites only
`mise.lock`, using the pinned mise from `/opt/tooling`), commit both, then
`sudo tooling/install.sh`. Every executable a tool ships is linked into `bin/` automatically. To
try an install without root: `TOOLING_PREFIX=<dir> tooling/install.sh`.
