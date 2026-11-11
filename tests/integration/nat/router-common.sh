#!/usr/bin/env bash

# Shared router base, sourced by each scenario's router-entrypoint.sh

set -euo pipefail

# iptables needs the wan interface's name (eth0/eth1), but podman assigns those
# names arbitrarily — so look for the name using the wan IP,
# defined in the compose file.
wanif=$(ip -o -4 addr show | awk -v ip="$ROUTER_WAN_IP" '$0 ~ ip {print $2; exit}')

for subnet in ${WAN_SUBNETS:-}; do
  if [[ -z "$(ip -o -4 route show "$subnet")" ]]; then
    ip route add "$subnet" dev "$wanif"
  fi
done

# Actual NAT (masquerading) rule.
if ! iptables -t nat -A POSTROUTING -s "$LAN_SUBNET" -o "$wanif" -j MASQUERADE; then
  echo "ERROR: iptables NAT failed. Load netfilter modules on the host:" >&2
  echo "       sudo modprobe iptable_nat nf_conntrack" >&2
  exit 1
fi

# Setting a router that looks like a typical home router requires a few more things:

# 1. By default, never forward anything. This prevents us from doing things like
#    forwarding packets from the public WAN into the LAN (which would completely
#    de-characterize our NAT box) by accident.
iptables -P FORWARD DROP

# 2. Traffic originating FROM the LAN subnet, however, should be allowed to flow
#    to the WAN. The "NEW" in the --ctstate is what actually allows new connections
#    to be established.
iptables -A FORWARD\
  -s "$LAN_SUBNET"\
  -o "$wanif"\
  -m conntrack --ctstate NEW,ESTABLISHED,RELATED \
  -j ACCEPT

# 3. For WAN-to-LAN traffic, we only allow packets that are part of an
#    established connection - this is what allows us to receive traffic from
#    the internet.
iptables -A FORWARD\
  -d "$LAN_SUBNET"\
  -i "$wanif"\
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT

# Finally, NAT boxes silently drop all INPUT traffic (directed at the router's IP)
# on the WAN interface by default - if we don't do this, in fact, the router will
# issue an RST (connection refused) when external peers try to connect, and things
# like hole punching will fail.
iptables -A INPUT -i "$wanif" -j DROP

# Blocks until `compose down`. `sleep` runs in the background so the SIGTERM trap
# fires immediately instead of waiting for sleep to return.
hold_until_stopped() {
  trap 'exit 0' TERM INT
  sleep infinity &
  wait
}

forward_port() {
  local external_port=$1
  local internal_ip=$2
  local internal_port=$3
  local proto=${4:-tcp}

  # Adds the rule to rewrite the destination IP/port.
  iptables -t nat\
    -A PREROUTING\
    -i "$wanif"\
    -p "$proto"\
    --dport "$external_port"\
    -j DNAT\
    --to-destination "$internal_ip:$internal_port"

  # Allows forwarding of the rewritten packet to the internal
  # IP/port.
  iptables -A FORWARD\
    -i "$wanif"\
    -p "$proto"\
    -d "$internal_ip"\
    --dport "$internal_port"\
    -m conntrack --ctstate DNAT\
    -j ACCEPT
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "router ready (wan iface $wanif)"

  hold_until_stopped
fi
