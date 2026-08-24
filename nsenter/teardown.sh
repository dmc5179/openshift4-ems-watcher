#!/bin/bash
# Restore FIPS EMS enforcement on running router pods.
#
# Reverses the nsenter modifications by restoring the original
# crypto policy values, then triggers a HAProxy reload.
# Alternatively, simply deleting the router pods achieves the same
# result since the overlay filesystem resets on restart.
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
  exit 1
fi

# Find a route for reload trigger
if [[ -z "$RELOAD_ROUTE_NS" || -z "$RELOAD_ROUTE_NAME" ]]; then
  ROUTE_LINE=$(oc get routes --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)
  if [[ -n "$ROUTE_LINE" ]]; then
    RELOAD_ROUTE_NS=$(echo "$ROUTE_LINE" | awk '{print $1}')
    RELOAD_ROUTE_NAME=$(echo "$ROUTE_LINE" | awk '{print $2}')
  fi
fi

POD_DATA=$(oc get pods -n "$INGRESS_NS" -l "$LABEL_SELECTOR" \
  -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}')

RESTORED=0
while IFS=' ' read -r POD_NAME NODE_NAME; do
  [[ -z "$POD_NAME" ]] && continue
  log "Restoring pod $POD_NAME on node $NODE_NAME..."

  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "${SSH_USER}@${NODE_NAME}" bash -s << 'NODE_SCRIPT'
    set -euo pipefail
    CONTAINER_ID=$(sudo crictl ps --name router -q | head -1)
    HOST_PID=$(sudo crictl inspect "$CONTAINER_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["pid"])')

    # Restore tls1-prf-ems-check = 1
    sudo nsenter -t "$HOST_PID" -m bash -c \
      'sed -i "s/tls1-prf-ems-check = 0/tls1-prf-ems-check = 1/" /etc/crypto-policies/back-ends/openssl_fips.config'
    sudo nsenter -t "$HOST_PID" -m bash -c \
      'sed -i "s/tls1-prf-ems-check = 0/tls1-prf-ems-check = 1/" /etc/pki/tls/fips_local.cnf'

    # Remove RHNoEnforceEMSinFIPS line
    sudo nsenter -t "$HOST_PID" -m bash -c \
      'sed -i "/Options = RHNoEnforceEMSinFIPS/d" /etc/crypto-policies/back-ends/opensslcnf.config'

    echo "  Restored to default FIPS policy"
NODE_SCRIPT

  if [[ $? -eq 0 ]]; then
    RESTORED=$((RESTORED + 1))
  fi
done <<< "$POD_DATA"

if [[ -n "$RELOAD_ROUTE_NS" && -n "$RELOAD_ROUTE_NAME" ]]; then
  log "Triggering HAProxy reload..."
  oc annotate route "$RELOAD_ROUTE_NAME" -n "$RELOAD_ROUTE_NS" \
    fips-ems-reload="$(date +%s)" --overwrite
  sleep 5
fi

log "Done. $RESTORED pod(s) restored to default FIPS policy."
log "Alternatively, delete router pods to reset: oc delete pods -n $INGRESS_NS -l '$LABEL_SELECTOR'"
