#!/usr/bin/env bash
# Script for generating configuration files and network presets for
# Logos Storage.
set -euo pipefail

echoerr() {
    echo "[storage_config] $1" >&2
}

# Needs bash 4 or higher
if (( BASH_VERSINFO[0] < 4 )); then
    echoerr "Error: This script requires Bash 4 or higher."
    exit 1
fi

# Needs jq
if ! command -v jq &> /dev/null; then
    echoerr "Error: jq is not installed"
    exit 1
fi

# Valid networks
declare -A _networks
_networks=([test]="Logos testnet" [dev]="Logos devnet")
# Associative arrays are unordered, but presets must be ordered
# as the first network will be the one that the node connects by
# default.
_preset_order=("test" "dev")

check_network() {
    local network=$1
    if [[ -z "${_networks[$network]+x}" ]]; then
        echoerr "Invalid network: $network. Use one of: ${!_networks[*]}"
        exit 1
    fi
}

raw_data() {
    local network=$1
    check_network "$network"
    curl -fsSL "https://fleets.logos.co/logos-${network}/storage-network.json"
}

mix_pool_json() {
    local network=$1
    check_network "$network"
    raw_data "$network" | jq -c '{
      "version": 1,
      "relays": map(select(.role == "mp") | {
        "peerId": .peerId,
        "mixPubKey": .mixPubKey,
        "libp2pPubKey": .libp2pPubKey,
        "multiAddr": "/ip4/\(.address)/tcp/\(.port)",
      })
    }'
}

node_sprs() {
    local network="$1"
    check_network "$network"
    raw_data "$network" | jq '[.[].spr]'
}

mix_proxy_sprs() {
    local network="$1"
    check_network "$network"
    raw_data "$network" | jq '. | map(select(.role == "mp")) | [.[].spr]'
}

full_config() {
    local network="$1"
    check_network "$network"
    cat <<EOF
    {
        "log-level": "${STORAGE_LOG_LEVEL:-info}",
        "nat": "${STORAGE_NAT:-auto}",
        "network": "logos.${network}",
        "mix-enabled": true,
        "dht-mix-proxy": $(mix_proxy_sprs "$network"),
        "mix-pool-json": $(mix_pool_json "$network" | jq -c 'tostring')
    }
EOF
}

presets() {
    echoerr "Re-generating network presets."

    for network in "${_preset_order[@]}"; do
        node_sprs "$network" | jq \
            --arg name "logos.${network}" \
            --arg description "${_networks[$network]}" \
            '{name: $name, description: $description, records: .}'
    done | jq -s '{presets: .}'
}

usage() {
    cat <<EOF
Usage: $0 <command> [network]

Generates configuration files and network presets for Logos Storage.

Commands:
  raw_data <network>        Fetch raw storage-network data from fleets.logos.co
  mix_pool_json <network>   Generate mix pool JSON configuration
  node_sprs <network>       List node SPRs
  full_config <network>     Generate full node configuration JSON
  presets                   Generate network presets JSON for all networks

Networks:
  ${!_networks[*]}

Examples:
  $0 node_sprs dev
  $0 full_config dev
  $0 presets
EOF
}

if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi

echoerr "Running command: $*"
"$@" | jq .
echoerr "Done."