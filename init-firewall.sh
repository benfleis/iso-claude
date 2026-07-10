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

# Allow traffic to/from the host's own /24 (Docker bridge, host services).
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
  echo "ERROR: Failed to detect host IP"
  exit 1
fi
HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Default-deny.
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Keep established/related flowing, then permit egress to allowlisted IPs only.
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# IPv6: there is no v6 allowlist, and the default ip6tables policy is ACCEPT, so
# without this the entire v4 allowlist is bypassable the moment the bridge gains
# a v6 address. Deny all v6 except loopback. Guarded so a kernel without v6
# support (where ip6tables can't read the table) is skipped rather than aborting.
if command -v ip6tables >/dev/null 2>&1 && ip6tables -L -n >/dev/null 2>&1; then
  ip6tables -F
  ip6tables -P INPUT DROP
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT DROP
  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A OUTPUT -o lo -j ACCEPT
fi

echo "Firewall scaffolding installed (allowlist empty until first reconcile)."
