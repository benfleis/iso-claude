# iso-common.sh — shared setup for the bin/ scripts. Not meant to be run
# directly; sourced by each (`source "$COMPOSE_DIR/bin/iso-common.sh"` after it
# sets COMPOSE_DIR itself, since that's needed to find this file).

SERVICE=claude

# Export the launcher settings (~/.config/iso-claude/.env, optional) so every
# `docker compose` we run interpolates the same config. EVERY compose entry point
# must call this (iso-claude, iso-shell, iso-firewall, iso-compose): one that
# didn't would see different mounts on `up -d` and RECREATE the container
# (killing running sessions), or build the image with the wrong ISO_UID.
# set -a: plain KEY=val lines must reach `docker compose`, which only sees
# exported vars.
#
# Also places Claude's state: inside the workspace (CLAUDE_STATE_DIR, default
# $CLAUDE_WORK_DIR/state/iso-claude), so the container reaches it through the
# workspace mount; ISO_CLAUDE_CONFIG_DIR is that path as the container sees it.
#
# Usage: iso_load_settings
iso_load_settings() {
    local f="$HOME/.config/iso-claude/.env"
    if [[ -f "$f" ]]; then
        set -a
        source "$f"
        set +a
    fi
    : "${CLAUDE_WORK_DIR:=/opt/workspace}"
    : "${CLAUDE_STATE_DIR:=$CLAUDE_WORK_DIR/state/iso-claude}"
    case "$CLAUDE_STATE_DIR" in
        "$CLAUDE_WORK_DIR"/?*) ;;
        *)
            echo "iso-claude: CLAUDE_STATE_DIR ($CLAUDE_STATE_DIR) must be inside CLAUDE_WORK_DIR ($CLAUDE_WORK_DIR)" >&2
            exit 1
            ;;
    esac
    export CLAUDE_WORK_DIR CLAUDE_STATE_DIR
    export ISO_CLAUDE_CONFIG_DIR="/opt/workspace/${CLAUDE_STATE_DIR#"$CLAUDE_WORK_DIR"/}"
}

# Refuse to run as root: `exec --user` downstream is derived straight from our
# own uid/gid, and the container grants NET_ADMIN/NET_RAW to its bounding set.
# Root here would become container-UID-0, which inherits those caps for free
# and could flush/edit the egress firewall from inside the sandboxed session.
#
# Also loads the settings (iso_load_settings above), then the secrets file,
# optional, which wins:
#   ~/.local/state/iso-claude-launcher/.env  secrets (CLAUDE_CODE_OAUTH_TOKEN,
#                                            GH_TOKEN); keep it 0600
# Secrets are exported for the wrappers' `-e VAR` passthrough only; nothing in
# docker-compose.yaml reads them. Keep the secrets file outside CLAUDE_WORK_DIR:
# the container mounts all of that.
#
# Usage: iso_prepare_env <name-for-messages>
iso_prepare_env() {
    local name="$1" f="$HOME/.local/state/iso-claude-launcher/.env"
    if [ "$(id -u)" -eq 0 ]; then
        echo "$name: refusing to run as root (would leak NET_ADMIN/NET_RAW into the sandboxed session). Run as a normal user." >&2
        exit 1
    fi
    iso_load_settings
    if [[ -f "$f" ]]; then
        set -a
        source "$f"
        set +a
    fi
}

# Bring the sandbox container up (idempotent) and make sure the egress
# allowlist is populated (a fresh `up` boots fail-closed with an empty one).
#
# Usage: iso_ensure_running <name-for-messages>
iso_ensure_running() {
    local name="$1"

    # Create the work dir AND Claude's state dir on the HOST first, so Docker
    # doesn't auto-create them as root (root-owned mounts break access and
    # trap Claude in a login loop).
    mkdir -p "$CLAUDE_WORK_DIR"
    # The state dir holds the /login credential (.credentials.json) and every
    # transcript: owner-only, re-asserted each launch in case it was created or
    # copied in loosely.
    mkdir -p "$CLAUDE_STATE_DIR"
    chmod 700 "$CLAUDE_STATE_DIR"

    # The shared toolchains are bind-mounted read-only (tooling/README.md);
    # without them the container has no rust, uv, go or sccache. Checked before
    # `up`, so a missing install can't lead to a recreate.
    if [ ! -d /opt/tooling/bin ]; then
        echo "$name: /opt/tooling is not installed; run: sudo $COMPOSE_DIR/tooling/install.sh" >&2
        exit 1
    fi

    # Make sure the sandbox is up. --no-recreate: a launch never replaces a running
    # container, even after a rebuild or a compose edit (either kills every session);
    # switching to a new image/config is a deliberate `iso-compose up -d`.
    docker compose -f "$COMPOSE_DIR/docker-compose.yaml" up -d --no-recreate >/dev/null

    # The image's iso-claude uid:gid is baked in at build time (ISO_UID/ISO_GID,
    # recorded in a label) and must equal ours, or $HOME and npm-global are
    # unwritable. A plain `docker compose build` skips iso_load_settings, so
    # check the label rather than trust the build.
    local want have
    want="$(id -u):$(id -g)"
    have=$(docker image inspect -f '{{index .Config.Labels "iso-claude.uid-gid"}}' iso-claude 2>/dev/null || true)
    if [ "$have" != "$want" ]; then
        echo "$name: image iso-claude is built for uid:gid '${have:-unknown}', but you are $want." >&2
        echo "$name: set ISO_UID/ISO_GID in ~/.config/iso-claude/.env, then: iso-compose build && iso-compose up -d  (recreates the container, ending running sessions)" >&2
        exit 1
    fi

    # A fresh `up` boots with an EMPTY allowlist (fail-closed → no egress) until
    # the host reconcile populates it. Populate it if empty so Claude can reach
    # the API. (Re-resolve on demand any time with `iso-firewall`.)
    local count
    count=$(docker compose -f "$COMPOSE_DIR/docker-compose.yaml" exec -T --user 0 "$SERVICE" \
        ipset list allowed-domains 2>/dev/null | awk '/^Number of entries:/{print $4}' || true)
    if [ -z "$count" ] || [ "$count" -eq 0 ]; then
        echo "$name: populating egress allowlist (first run since boot)…" >&2
        "$COMPOSE_DIR/bin/iso-firewall" --quiet || echo "$name: warning — egress reconcile failed; egress may be blocked" >&2
    fi
}
