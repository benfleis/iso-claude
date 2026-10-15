#!/usr/bin/env bash
# lock.sh — regenerate mise.lock after editing mise.toml (README.md). Runs as any
# user with the mise install.sh installed; only this directory's mise.lock changes.
# Extra args go to `mise lock` (e.g. --bump uv).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
mise_version=$(sed -n 's/^MISE_VERSION=//p' "$here/install.sh")
mise=${TOOLING_ROOT:-/opt/tooling}/mise/mise-$mise_version
if [[ ! -x $mise ]]; then
    echo "lock.sh: $mise not found; run install.sh first" >&2
    exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export MISE_DATA_DIR=$tmp/data MISE_STATE_DIR=$tmp/state MISE_CACHE_DIR=${TOOLING_MISE_CACHE:-/opt/mise/cache} \
    MISE_CONFIG_DIR=$tmp/config MISE_GLOBAL_CONFIG_FILE=$tmp/config/none.toml \
    MISE_TRUSTED_CONFIG_PATHS=$here MISE_YES=1
cd "$here" && "$mise" lock "$@"
chmod 0644 "$here/mise.lock"
