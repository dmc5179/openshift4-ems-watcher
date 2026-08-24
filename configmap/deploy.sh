#!/bin/bash
# Deploy the FIPS EMS relaxation to the current OpenShift cluster.
#
# This script:
#   1. Creates the ConfigMap with modified crypto policy files
#   2. Scales down the ingress operator to prevent reconciliation
#   3. Patches the router deployment to mount the ConfigMap
#   4. Waits for the new router pods to roll out
#
# The ingress operator is scaled to zero because it would otherwise
# revert the volume mount patch on the router deployment. If you need
# the operator running, consider using unsupportedConfigOverrides on
# the IngressController CR instead (not covered here).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROUTER_DEPLOYMENT="${ROUTER_DEPLOYMENT:-router-default}"
INGRESS_NS="${INGRESS_NS:-openshift-ingress}"
OPERATOR_NS="${OPERATOR_NS:-openshift-ingress-operator}"

echo "==> Creating ConfigMap with modified crypto policy..."
oc apply -f "$SCRIPT_DIR/manifests.yaml"

echo "==> Scaling down ingress operator to prevent reconciliation..."
oc scale deployment ingress-operator -n "$OPERATOR_NS" --replicas=0 2>/dev/null || \
  echo "WARNING: could not scale ingress operator (may need cluster-admin)"

echo "==> Patching router deployment to mount crypto policy override..."
# Check if the volume mount already exists
if oc get deployment "$ROUTER_DEPLOYMENT" -n "$INGRESS_NS" \
    -o jsonpath='{.spec.template.spec.volumes[*].name}' 2>/dev/null | grep -q 'fips-ems-override'; then
  echo "    Volume mount already present, skipping patch."
else
  oc patch deployment "$ROUTER_DEPLOYMENT" -n "$INGRESS_NS" --type=json -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/volumes/-",
      "value": {
        "name": "fips-ems-override",
        "configMap": {
          "name": "fips-ems-override"
        }
      }
    },
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/volumeMounts/-",
      "value": {
        "name": "fips-ems-override",
        "mountPath": "/etc/crypto-policies/back-ends/openssl_fips.config",
        "subPath": "openssl_fips.config",
        "readOnly": true
      }
    },
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/volumeMounts/-",
      "value": {
        "name": "fips-ems-override",
        "mountPath": "/etc/crypto-policies/back-ends/opensslcnf.config",
        "subPath": "opensslcnf.config",
        "readOnly": true
      }
    }
  ]'
fi

echo "==> Waiting for router rollout..."
oc rollout status deployment/"$ROUTER_DEPLOYMENT" -n "$INGRESS_NS" --timeout=180s

echo "==> Done. Verify with:"
echo "    echo | openssl s_client -connect <route-host>:443 -tls1_2 -no_ems 2>&1 | grep 'Cipher is'"
