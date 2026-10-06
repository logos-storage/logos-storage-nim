#!/bin/bash

# Environment variables from files in form of foo=bar
# If set to file path, read the file and export the variables
# If set to directory path, read all files in the directory and export the variables
if [[ -n "${ENV_PATH}" ]]; then
  set -a
  [[ -f "${ENV_PATH}" ]] && source "${ENV_PATH}" || for f in "${ENV_PATH}"/*; do source "$f"; done
  set +a
fi

# Bootstrap node URL
if [[ -n "${BOOTSTRAP_NODE_URL}" ]]; then
  BOOTSTRAP_NODE_URL="${BOOTSTRAP_NODE_URL}/api/storage/v1/spr"
  WAIT=${BOOTSTRAP_NODE_URL_WAIT:-300}
  SECONDS=0
  SLEEP=1
  # Run and retry if fail
  while (( SECONDS < WAIT )); do
    SPR=$(curl -s -f -m 5 -H 'Accept: text/plain' "${BOOTSTRAP_NODE_URL}")
    # Check if exit code is 0 and returned value is not empty
    if [[ $? -eq 0 && -n "${SPR}" ]]; then
      export STORAGE_BOOTSTRAP_NODE="${SPR}"
      break
    else
      # Sleep and check again
      echo "Can't get SPR from ${BOOTSTRAP_NODE_URL} - Retry in $SLEEP seconds / $((WAIT - SECONDS))"
      sleep $SLEEP
    fi
  done
fi

# Bootstrap node from URL
if [[ -n "${BOOTSTRAP_NODE_FROM_URL}" ]]; then
  WAIT=${BOOTSTRAP_NODE_FROM_URL_WAIT:-300}
  SECONDS=0
  SLEEP=1
  # Run and retry if fail
  while (( SECONDS < WAIT )); do
    SPR=($(curl -s -f -m 5 "${BOOTSTRAP_NODE_FROM_URL}"))
    # Check if exit code is 0 and returned value is not empty
    if [[ $? -eq 0 && -n "${SPR}" ]]; then
      for node in "${SPR[@]}"; do
        bootstrap+="--bootstrap-node=$node "
      done
      set -- "$@" ${bootstrap}
      break
    else
      # Sleep and check again
      echo "Can't get SPR from ${BOOTSTRAP_NODE_FROM_URL} - Retry in $SLEEP seconds / $((WAIT - SECONDS))"
      sleep $SLEEP
    fi
  done
fi


# Stop Logos Storage run if unable to get SPR
if [[ -n "${BOOTSTRAP_NODE_URL}" && -z "${STORAGE_BOOTSTRAP_NODE}" ]]; then
  echo "Unable to get SPR from ${BOOTSTRAP_NODE_URL} in ${BOOTSTRAP_NODE_URL_WAIT} seconds - Stop Logos Storage run"
  exit 1
fi

# Bootstrap nodes of the network
if [[ -n "${STORAGE_NETWORK}" ]]; then
  NETWORK_URL="https://fleets.logos.co/${STORAGE_NETWORK/./-}/storage-network.json"
  SPR=($(curl -s -f -m 5 "${NETWORK_URL}" | jq -r '.[].spr'))

  # Stop Logos Storage run if unable to get SPR
  if [[ -z "${SPR}" ]]; then
    echo "Unable to get SPR from ${NETWORK_URL} - Stop Logos Storage run"
    exit 1
  fi

  for node in "${SPR[@]}"; do
    set -- "$@" "--bootstrap-node=$node"
  done
fi

# Parameters
if [[ -z "${STORAGE_NAT}" ]]; then
  if [[ "${NAT_IP_AUTO}" == "true" && -z "${NAT_PUBLIC_IP_AUTO}" ]]; then
    export STORAGE_NAT="extip:$(hostname --ip-address | grep --color=never -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')"
  elif [[ -n "${NAT_PUBLIC_IP_AUTO}" ]]; then
    # Run for 60 seconds if fail
    WAIT=120
    SECONDS=0
    SLEEP=5
    while (( SECONDS < WAIT )); do
      IP=$(curl -s -f -m 5 "${NAT_PUBLIC_IP_AUTO}")
      # Check if exit code is 0 and returned value is not empty
      if [[ $? -eq 0 && -n "${IP}" ]]; then
        export STORAGE_NAT="extip:${IP}"
        break
      else
        # Sleep and check again
        echo "Can't get Public IP - Retry in $SLEEP seconds / $((WAIT - SECONDS))"
        sleep $SLEEP
      fi
    done
  fi
fi

# Stop Logos Storage run if can't get NAT IP when requested
if [[ "${NAT_IP_AUTO}" == "true" && -z "${STORAGE_NAT}" ]]; then
  echo "Can't get Private IP - Stop Logos Storage run"
  exit 1
elif [[ -n "${NAT_PUBLIC_IP_AUTO}" && -z "${STORAGE_NAT}" ]]; then
  echo "Can't get Public IP in $WAIT seconds - Stop Logos Storage run"
  exit 1
fi

# Show
echo -e "\Logos Storage run parameters:"
vars=$(env | grep "STORAGE_" | grep -v -e "[0-9]_SERVICE_" -e "[0-9]_NODEPORT_")
echo -e "${vars//STORAGE_/   - STORAGE_}"
echo -e "   - $@\n"

# Run
echo "Run Logos Storage node"
exec "$@"
