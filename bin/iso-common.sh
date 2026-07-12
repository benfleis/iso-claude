# iso-common.sh — shared setup for iso-shell and iso-claude. Not meant to be
# run directly; sourced by both wrapper scripts (`source "$COMPOSE_DIR/bin/iso-common.sh"`
# after each sets COMPOSE_DIR itself, since that's needed to find this file).

SERVICE=claude

# Refuse to run as root: `exec --user` downstream is derived straight from our
# own uid/gid, and the container grants NET_ADMIN/NET_RAW to its bounding set.
# Root here would become container-UID-0, which inherits those caps for free
# and could flush/edit the egress firewall from inside the sandboxed session.
#
# Also sources the launcher env (CLAUDE_WORK_DIR, CLAUDE_STATE_DIR,
# CLAUDE_CODE_OAUTH_TOKEN, ...) from ~/.config/iso-claude/.env if present, so
# our view of the compose config matches — if it drifted, `up -d` later would
# look like a config change and RECREATE the container, killing any running
# session.
#
# Usage: iso_prepare_env <name-for-messages>
iso_prepare_env() {
    local name="$1"
    if [ "$(id -u)" -eq 0 ]; then
        echo "$name: refusing to run as root (would leak NET_ADMIN/NET_RAW into the sandboxed session). Run as a normal user." >&2
        exit 1
    fi
    [[ -f "$HOME/.config/iso-claude/.env" ]] && source "$HOME/.config/iso-claude/.env"
}

# Bring the sandbox container up (idempotent) and make sure the egress
# allowlist is populated (a fresh `up` boots fail-closed with an empty one).
#
# Usage: iso_ensure_running <name-for-messages>
iso_ensure_running() {
    local name="$1"

    # Create the work dir AND Claude's state dir on the HOST first, so Docker
    # doesn't auto-create them as root (root-owned mounts break access and
    # trap Claude in a login loop). Both are bind-mounted by docker-compose.yaml.
    mkdir -p "${CLAUDE_WORK_DIR:-/opt/workspace}"
    mkdir -p "${CLAUDE_STATE_DIR:-$HOME/.local/state/iso-claude}"

    # Make sure the sandbox is up (no-op if already running).
    docker compose -f "$COMPOSE_DIR/docker-compose.yaml" up -d >/dev/null

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
