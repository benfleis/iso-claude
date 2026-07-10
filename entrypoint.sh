#!/usr/bin/env bash
# entrypoint.sh
set -euo pipefail

# Install egress allowlist (needs NET_ADMIN/NET_RAW, which compose grants).
# Runs as root (PID 1) — NOT via sudo: cap_drop:ALL strips CAP_SETUID/SETGID,
# so sudo can't switch to root and would abort the entrypoint under `set -e`.
/usr/local/bin/init-firewall.sh

# Then become the long-lived PID 1 (or exec whatever command was passed).
exec "${@:-sleep infinity}"
