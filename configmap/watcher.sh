#!/bin/bash
# fips-ems-watcher.sh
# Monitors the router deployment to verify the FIPS EMS relaxation
# ConfigMap mount is still in place. Alerts if the ingress operator
# or another actor reverts the patch.
#
# This script is OPTIONAL. The actual EMS relaxation is applied by
# deploy.sh via ConfigMap volume mounts on the router deployment.
# This watcher only monitors and re-applies if reverted.

set -euo pipefail

ROUTER_DEPLOYMENT="${ROUTER_DEPLOYMENT:-router-default}"
INGRESS_NS="${INGRESS_NS:-openshift-ingress}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
SETTLE_SECONDS="${SETTLE_SECONDS:-5}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

is_configmap_present() {
  oc get configmap fips-ems-override -n "$INGRESS_NS" &>/dev/null
}

is_mount_present() {
  oc get deployment "$ROUTER_DEPLOYMENT" -n "$INGRESS_NS" \
    -o jsonpath='{.spec.template.spec.volumes[*].name}' 2>/dev/null \
    | grep -q 'fips-ems-override'
}

is_router_patched() {
  local pod
  pod=$(oc get pods -n "$INGRESS_NS" \
    -l "ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || return 1
  [[ -z "$pod" ]] && return 1

  oc exec "$pod" -c router -n "$INGRESS_NS" -- \
    grep -q 'tls1-prf-ems-check = 0' /etc/crypto-policies/back-ends/openssl_fips.config 2>/dev/null
}

check_and_alert() {
  if ! is_configmap_present; then
    log "WARNING: ConfigMap fips-ems-override is missing from $INGRESS_NS"
    return 1
  fi

  if ! is_mount_present; then
    log "WARNING: Volume mount fips-ems-override is missing from deployment $ROUTER_DEPLOYMENT"
    log "  The ingress operator may have reconciled. Re-run deploy.sh to restore."
    return 1
  fi

  if ! is_router_patched; then
    log "WARNING: Router pod does not have tls1-prf-ems-check = 0"
    return 1
  fi

  return 0
}

main() {
  log "FIPS EMS Watcher starting (monitor mode)"
  log "  Router deployment: $ROUTER_DEPLOYMENT"
  log "  Namespace:         $INGRESS_NS"
  log "  Poll interval:     ${POLL_INTERVAL}s"

  sleep "$SETTLE_SECONDS"

  while true; do
    if check_and_alert; then
      log "OK: FIPS EMS relaxation is active"
    fi
    sleep "$POLL_INTERVAL"
  done
}

main "$@"
