#!/usr/bin/env bash
#
# Entrypoint script for a storage node in the NAT integration test.
set -euo pipefail

STORAGE_BINARY=${STORAGE_BINARY:-/app/build/storage}

# In-memory configuration for the node.
_config_opts=()
_opt_uses_identify="false"

_echoerr() {
  echo "$@" >&2
}

_base_config() {
  _config_opts+=(
    "${STORAGE_BINARY}"
    --listen-ip=0.0.0.0
    # api-bindaddr=0.0.0.0 so the published host port reaches the REST API.
    --api-bindaddr=0.0.0.0
    --listen-port=8070
    --api-port=8080
    --data-dir=/data
    '--log-level=DEBUG;trace:libp2p,mix'
  )
}

_api_request() {
  local addr="$1" path="$2" timeout="${3:-60}" interval="${4:-1}"
  local api_url="http://$addr:8080$path"
  local deadline=$((SECONDS + timeout))

  while (( SECONDS < deadline )); do
    if curl -fsS -H 'Accept: text/plain' "$api_url"; then
      return 0
    fi
    _echoerr "Retrying request to $api_url in $interval seconds."
    sleep "$interval"
  done
  _echoerr "FAILURE: giving up on request to $api_url."
  return 1
}

add_bootstrap_options() {
  local bootstrap_addr="$1" spr=""
  if [[ -z "$bootstrap_addr" ]]; then
    _echoerr "Node is a primary bootstrap node."
    _config_opts+=(--no-bootstrap-node)
    return 0
  fi

  _echoerr "Attempt to fetch bootstrap SPR from $bootstrap_addr ..."
  spr=$(_api_request "$bootstrap_addr" "/api/storage/v1/spr")
  _echoerr "Successfully fetched bootstrap SPR: $spr"
  _config_opts+=(--bootstrap-node="$spr")
}

public_node() {
  local wan_ip="$1"
  local bootstrap_addr="${2:-}"
  _echoerr "Node is on the WAN (public IP is $wan_ip)"

  add_bootstrap_options "$bootstrap_addr"
  if [[ "$wan_ip" != "use-identify" ]]; then
    _echoerr "Node external address set to $wan_ip"
    _config_opts+=(--nat=extip:$wan_ip)
  else
    _echoerr "Node will learn its external IP from Identify"
    _opt_uses_identify="true"
  fi
}

private_node() {
  local router_lan_ip="$1"
  local bootstrap_api_url="$2"
  _echoerr "Node is behind NAT (router LAN IP is $router_lan_ip)"
  # Redirect the traffic to our router instead of podman's own gateway to put the
  # node behind the NAT. A node on the wan (reachable) leaves ROUTER_LAN_IP unset
  # and keeps its default route.
  ip route replace default via "$router_lan_ip"

  if [[ -z "$bootstrap_api_url" ]]; then
    _echoerr "Private nodes require a bootstrap API URL."
    return 1
  fi

  add_bootstrap_options "$bootstrap_api_url"

  _config_opts+=(
    --nat-num-peers-to-ask=1
    --nat-max-queue-size=1
    --nat-min-confidence=1.0
    --nat-schedule-interval=5s
  )
}

enable_mix() {
  local info

  _config_opts+=(
    --mix-enabled
  )

  rm -rf /tmp/mixinfo.jsonl || true

  _echoerr "Querying mix nodes: $*"

  for mix_ip in "$@"; do
    info=$(_api_request "$mix_ip" "/api/storage/v1/debug/info")
    echo "$info" | jq '{
      peerId: .table.localNode.peerId,
      multiAddr: .addrs[0],
      mixPubKey: .mixPubKey,
      libp2pPubKey: .libp2pPubKey
    }' >> /tmp/mixinfo.jsonl
    _config_opts+=("--dht-mix-proxy=$(echo "$info" | jq --raw-output .spr)")
  done

  if [[ -s /tmp/mixinfo.jsonl ]]; then
    mix_pool_json_str=$(jq -n --slurpfile relays /tmp/mixinfo.jsonl '{
      version: 1,
      relays: $relays
    }')
    _config_opts+=(--mix-pool-json="$mix_pool_json_str")
  fi
}

enable_nat_servers() {
  if [[ "$_opt_uses_identify" == "true" ]]; then
    _echoerr "Cannot enable AutoNAT/Relay when using Identify for external IP detection"
    return 1
  fi

  # A bit long-winded but will catch typos and invalid values, and has
  # a convenient default.
  local services="${1:-all}"
  if [[ "$services" == "relay" ]]; then
    _config_opts+=(--relay-server)
  elif [[ "$services" == "autonat" ]]; then
    _config_opts+=(--autonat-server)
  elif [[ "$services" == "all" ]]; then
    _config_opts+=(--relay-server --autonat-server)
  else
    _echoerr "Invalid argument. Use 'relay' or 'autonat', or no arguments to enable both."
    return 1
  fi
}

with_args() {
  _config_opts+=("$@")
}

launch() {
  _echoerr "Starting node..."
  exec "${_config_opts[@]}"
}

# Added by default.
_base_config

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # This will run commands separated by -%- as a chain.
  while [[ $# -gt 0 ]]; do
    current_cmd=()
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-%-" ]]; then
        shift
        break
      fi
      current_cmd+=("$1")
      shift
    done
    "${current_cmd[@]}"
  done

  _echoerr "#### Config opts ####"
  _echoerr "${_config_opts[@]}"
  _echoerr "#####################"

  # Once we're done, launch the node.
  launch "$@"
fi
