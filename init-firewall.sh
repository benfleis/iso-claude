#!/bin/bash
# init-firewall.sh — SCAFFOLDING ONLY, runs in-container as root at boot.
#
# Deliberately does NO network I/O (no dig, no curl, no GitHub fetch). It only
# lays down the static iptables structure and an EMPTY `allowed-domains` ipset,
# then sets the default policy to DROP. Consequences:
#   * The container always boots fail-CLOSED — even with no internet — and can
#     never self-block by trying to reach the network to configure the network.
#   * The actual allowed IPs are filled in afterwards by the HOST-side reconcile
#     (`bin/iso-firewall`), which resolves domains on the host and pushes the
#     result into this ipset via `docker exec`. See allowlist.conf.
#
# Until the first reconcile runs, egress is limited to DNS/loopback/host-net,
# i.e. blocked by default. That is intentional.
set -euo pipefail
IFS=$'\n\t'

# Preserve Docker's internal DNS (127.0.0.11) NAT rules across the flush so
# in-container name resolution keeps working (the app still resolves domains;
# the firewall gates by the resolved IP via the ipset).
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

if [ -n "$DOCKER_DNS_RULES" ]; then
  echo "Restoring Docker DNS rules..."
  iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
  iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
  echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
  echo "No Docker DNS rules to restore"
fi

# Base allowances (needed before the default-DROP policy bites).
# DNS is scoped to the resolver(s) named in /etc/resolv.conf (normally Docker's
# embedded 127.0.0.11), not the whole internet — a blanket udp/53 is a direct
# channel to any nameserver. Outbound SSH is intentionally NOT opened: git over
# SSH to an allowlisted host (e.g. github) is already covered by the
# allowed-domains match below, so a blanket tcp/22 would only add an exfil path.
for ns in $(awk '/^nameserver/{print $2}' /etc/resolv.conf); do
  iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
  iptables -A INPUT -p udp -s "$ns" --sport 53 -j ACCEPT
  iptables -A INPUT -p tcp -s "$ns" --sport 53 -j ACCEPT
done
iptables -A INPUT -i lo -j ACCEPT # loopback
iptables -A OUTPUT -o lo -j ACCEPT

# Empty allowlist set — populated later by the host reconcile (iso-firewall).
ipset create allowed-domains hash:net family inet

# Allow traffic to/from the host gateway only (not the whole /24 — that would
# open unrestricted access to every other container or host process sharing
# the bridge subnet, silently widening the "allowlist only" guarantee).
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
  echo "ERROR: Failed to detect host IP"
  exit 1
fi
if [ "$(printf '%s\n' "$HOST_IP" | wc -l)" -gt 1 ]; then
  echo "ERROR: multiple default routes detected — refusing to guess which is the host gateway. Fix the routing table (or this script) before continuing:" >&2
  printf '%s\n' "$HOST_IP" >&2
  exit 1
fi
echo "Host gateway detected as: $HOST_IP"
iptables -A INPUT -s "$HOST_IP" -j ACCEPT
iptables -A OUTPUT -d "$HOST_IP" -j ACCEPT

# Default-deny.
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Keep established/related flowing, then permit egress to allowlisted IPs only.
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# IPv6: there is no v6 allowlist, and the kernel's default ip6tables policy is
# ACCEPT, so without an explicit deny the entire v4 allowlist is bypassable the
# moment the bridge gains a v6 address.
#
# Set the DROP policy FIRST, before touching anything else, so that any
# failure partway through this block still leaves v6 fail-closed rather than
# kernel-default ACCEPT. A kernel with no v6 support at all (ip6tables binary
# absent) is skipped, since there's nothing to block — but if the binary
# exists and any step here fails, that's a real containment gap: fail loudly
# instead of silently continuing with ACCEPT (previously, a broken/permission
# -denied liveness probe here would skip the whole block silently).
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -P INPUT DROP || { echo "ERROR: ip6tables present but failed to set INPUT DROP policy — aborting rather than leaving v6 ACCEPT-by-default." >&2; exit 1; }
  ip6tables -P FORWARD DROP || { echo "ERROR: ip6tables present but failed to set FORWARD DROP policy — aborting rather than leaving v6 ACCEPT-by-default." >&2; exit 1; }
  ip6tables -P OUTPUT DROP || { echo "ERROR: ip6tables present but failed to set OUTPUT DROP policy — aborting rather than leaving v6 ACCEPT-by-default." >&2; exit 1; }
  ip6tables -F || { echo "ERROR: ip6tables present but failed to flush existing v6 rules." >&2; exit 1; }
  ip6tables -A INPUT -i lo -j ACCEPT || { echo "ERROR: ip6tables present but failed to allow v6 loopback (INPUT)." >&2; exit 1; }
  ip6tables -A OUTPUT -o lo -j ACCEPT || { echo "ERROR: ip6tables present but failed to allow v6 loopback (OUTPUT)." >&2; exit 1; }
else
  echo "ip6tables not found; assuming this kernel has no IPv6 support (nothing to block)."
fi

echo "Firewall scaffolding installed (allowlist empty until first reconcile)."
