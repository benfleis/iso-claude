#!/usr/bin/env bash
# install.sh — install or update the shared toolchains in /opt/tooling (README.md).
# Run on the host, as root:  sudo tooling/install.sh
# TOOLING_PREFIX=<dir> installs elsewhere, as any user (for testing).
set -euo pipefail

MISE_VERSION=v2026.9.5

here=$(cd "$(dirname "$0")" && pwd)
prefix=${TOOLING_PREFIX:-/opt/tooling}
if [[ -z ${TOOLING_PREFIX:-} && $(id -u) -ne 0 ]]; then
    echo "install.sh: run as root (sudo): /opt/tooling must not be writable by the user" >&2
    exit 1
fi
case $(uname -m) in
    x86_64) arch=x64 ;;
    aarch64) arch=arm64 ;;
    *) echo "install.sh: unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
umask 022
mkdir -p "$prefix/bin" "$prefix/mise"

# mise itself: pinned, checksum-verified, kept off PATH (only this script runs it).
mise="$prefix/mise/mise-$MISE_VERSION"
if [[ ! -x $mise ]]; then
    asset=mise-$MISE_VERSION-linux-$arch-musl
    base=https://github.com/jdx/mise/releases/download/$MISE_VERSION
    curl -fsSL -o "$tmp/$asset" "$base/$asset"
    curl -fsSL -o "$tmp/SHASUMS256.txt" "$base/SHASUMS256.txt"
    (cd "$tmp" && grep -E " (\./)?$asset\$" SHASUMS256.txt | sed 's# \./# #' | sha256sum -c --quiet)
    install -m 0755 "$tmp/$asset" "$mise"
fi

install -m 0644 "$here/mise.toml" "$here/mise.lock" "$here/README.md" "$here/env.sh" "$prefix/"
rm -rf "$prefix/env"
install -d -m 0755 "$prefix/env"
install -m 0644 "$here"/env/*.sh "$prefix/env/"

# The tools, exactly as mise.toml + mise.lock pin them. Locked mode refuses any
# artifact the lockfile doesn't cover; rustup verifies its own downloads.
export MISE_DATA_DIR=$prefix/mise MISE_STATE_DIR=$prefix/mise/state \
    MISE_CONFIG_DIR=$prefix/mise/config MISE_GLOBAL_CONFIG_FILE=$prefix/mise/config/none.toml \
    MISE_CACHE_DIR=$tmp/cache MISE_RUSTUP_HOME=$prefix/rustup MISE_CARGO_HOME=$prefix/cargo \
    MISE_TRUSTED_CONFIG_PATHS=$prefix MISE_YES=1 MISE_LOCKED=1
(cd "$prefix" && "$mise" install)

# One PATH entry for host and container: every executable each tool exposes
# (`mise bin-paths`) and every rustup proxy is linked into bin/ (relative links,
# so the tree also works under TOOLING_PREFIX). New tools need no change here.
find "$prefix/bin" -maxdepth 1 -type l -delete
while IFS= read -r d; do
    for b in "$d"/*; do
        [[ -f $b && -x $b ]] && ln -sfr "$b" "$prefix/bin/${b##*/}"
    done
done < <(cd "$prefix" && "$mise" bin-paths)
for p in "$prefix"/cargo/bin/*; do
    ln -sfr "$p" "$prefix/bin/${p##*/}"
done

# Verify through env.sh itself, as both sides will use it.
(
    TOOLING_ROOT=$prefix
    . "$prefix/env.sh"
    rustc --version; cargo --version; uv --version; sccache --version; go version
)
