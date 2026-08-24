#!/bin/bash
# Relax FIPS EMS enforcement on running router pods using nsenter.
#
# This script SSHes to each worker node hosting a router pod, uses
# nsenter to modify the crypto policy files as root inside the
# container's mount namespace, then triggers a HAProxy reload via
# a route annotation change so the new HAProxy process reads the
# updated config.
#
# Requirements:
#   - SSH key access to worker nodes (core user with sudo)
#   - oc CLI authenticated with cluster-admin
#   - A route exists in the cluster (for triggering reload)
#
# The ingress operator is NOT modified — it stays running at full scale.
# Changes are ephemeral: a pod restart resets the overlay filesystem.
set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/danclark-personal.pem}"
SSH_USER="${SSH_USER:-core}"
INGRESS_NS="${INGRESS_NS:-openshift-ingress}"
LABEL_SELECTOR="${LABEL_SELECTOR:-ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default}"
RELOAD_ROUTE_NS="${RELOAD_ROUTE_NS:-}"
RELOAD_ROUTE_NAME="${RELOAD_ROUTE_NAME:-}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

if [[ ! -f "$SSH_KEY" ]]; then
  echo "ERROR: SSH key not found at $SSH_KEY"
  echo "Set SSH_KEY to the path of your private key for worker node access."
  exit 1
fi

# Find a route to annotate for triggering reload
if [[ -z "$RELOAD_ROUTE_NS" || -z "$RELOAD_ROUTE_NAME" ]]; then
  log "Finding a route to use for reload trigger..."
  ROUTE_LINE=$(oc get routes --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)
  if [[ -z "$ROUTE_LINE" ]]; then
    echo "ERROR: No routes found in the cluster. Set RELOAD_ROUTE_NS and RELOAD_ROUTE_NAME."
    exit 1
  fi
  RELOAD_ROUTE_NS=$(echo "$ROUTE_LINE" | awk '{print $1}')
  RELOAD_ROUTE_NAME=$(echo "$ROUTE_LINE" | awk '{print $2}')
  log "Using route $RELOAD_ROUTE_NS/$RELOAD_ROUTE_NAME for reload trigger"
fi

# Get router pods and their nodes
log "Finding router pods..."
POD_DATA=$(oc get pods -n "$INGRESS_NS" -l "$LABEL_SELECTOR" \
  -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}')

if [[ -z "$POD_DATA" ]]; then
  echo "ERROR: No running router pods found."
  exit 1
fi

PATCHED=0
while IFS=' ' read -r POD_NAME NODE_NAME; do
  [[ -z "$POD_NAME" ]] && continue
  log "Patching pod $POD_NAME on node $NODE_NAME..."

  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "${SSH_USER}@${NODE_NAME}" bash -s << 'NODE_SCRIPT'
    set -euo pipefail
    CONTAINER_ID=$(sudo crictl ps --name router -q | head -1)
    if [[ -z "$CONTAINER_ID" ]]; then
      echo "ERROR: No router container found on this node"
      exit 1
    fi
    HOST_PID=$(sudo crictl inspect "$CONTAINER_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["pid"])')

    # Modify openssl_fips.config
    sudo nsenter -t "$HOST_PID" -m bash -c \
      'sed -i "s/tls1-prf-ems-check = 1/tls1-prf-ems-check = 0/" /etc/crypto-policies/back-ends/openssl_fips.config'

    # Modify fips_local.cnf
    sudo nsenter -t "$HOST_PID" -m bash -c \
      'sed -i "s/tls1-prf-ems-check = 1/tls1-prf-ems-check = 0/" /etc/pki/tls/fips_local.cnf'

    # Append RHNoEnforceEMSinFIPS if not already present
    sudo nsenter -t "$HOST_PID" -m bash -c \
      'grep -q RHNoEnforceEMSinFIPS /etc/crypto-policies/back-ends/opensslcnf.config || echo "Options = RHNoEnforceEMSinFIPS" >> /etc/crypto-policies/back-ends/opensslcnf.config'

    # Verify
    EMS_CHECK=$(sudo nsenter -t "$HOST_PID" -m grep 'tls1-prf-ems-check' /etc/crypto-policies/back-ends/openssl_fips.config)
    OPTIONS=$(sudo nsenter -t "$HOST_PID" -m grep 'RHNoEnforceEMSinFIPS' /etc/crypto-policies/back-ends/opensslcnf.config)
    echo "  openssl_fips.config: $EMS_CHECK"
    echo "  opensslcnf.config:   $OPTIONS"
NODE_SCRIPT

  if [[ $? -eq 0 ]]; then
    log "  Pod $POD_NAME patched successfully"
    PATCHED=$((PATCHED + 1))
  else
    log "  ERROR: Failed to patch pod $POD_NAME"
  fi
done <<< "$POD_DATA"

if [[ $PATCHED -eq 0 ]]; then
  echo "ERROR: No pods were patched."
  exit 1
fi

log "Triggering HAProxy reload via route annotation..."
oc annotate route "$RELOAD_ROUTE_NAME" -n "$RELOAD_ROUTE_NS" \
  fips-ems-reload="$(date +%s)" --overwrite

log "Waiting for HAProxy reload to complete..."
sleep 5

log "Done. $PATCHED pod(s) patched."
log "Verify with:"
log "  echo | openssl s_client -connect <route-host>:443 -tls1_2 -no_ems 2>&1 | grep 'Cipher is'"
