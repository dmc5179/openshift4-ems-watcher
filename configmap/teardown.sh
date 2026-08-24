#!/bin/bash
# Remove the FIPS EMS relaxation and restore original router behavior.
set -euo pipefail

ROUTER_DEPLOYMENT="${ROUTER_DEPLOYMENT:-router-default}"
INGRESS_NS="${INGRESS_NS:-openshift-ingress}"
OPERATOR_NS="${OPERATOR_NS:-openshift-ingress-operator}"

echo "==> Removing volume mount patch from router deployment..."
# Remove the fips-ems-override volume and its mounts.
# The JSON patch removes by matching the volume name.
VOLUME_INDEX=$(oc get deployment "$ROUTER_DEPLOYMENT" -n "$INGRESS_NS" \
  -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' 2>/dev/null \
  | grep -n 'fips-ems-override' | cut -d: -f1)

if [[ -n "$VOLUME_INDEX" ]]; then
  VOLUME_INDEX=$((VOLUME_INDEX - 1))
  # Find and remove volume mounts referencing fips-ems-override
  MOUNT_INDICES=$(oc get deployment "$ROUTER_DEPLOYMENT" -n "$INGRESS_NS" \
    -o jsonpath='{range .spec.template.spec.containers[0].volumeMounts[*]}{.name}{"\n"}{end}' 2>/dev/null \
    | grep -n 'fips-ems-override' | cut -d: -f1 | sort -rn)

  PATCH="["
  for idx in $MOUNT_INDICES; do
    PATCH="${PATCH}{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/volumeMounts/$((idx - 1))\"},"
  done
  PATCH="${PATCH}{\"op\":\"remove\",\"path\":\"/spec/template/spec/volumes/${VOLUME_INDEX}\"}]"

  oc patch deployment "$ROUTER_DEPLOYMENT" -n "$INGRESS_NS" --type=json -p="$PATCH"
  echo "    Patch removed. Router pods will roll out with original config."
else
  echo "    No fips-ems-override volume found, skipping."
fi

echo "==> Deleting ConfigMap..."
oc delete configmap fips-ems-override -n "$INGRESS_NS" --ignore-not-found

echo "==> Scaling ingress operator back up..."
oc scale deployment ingress-operator -n "$OPERATOR_NS" --replicas=1 2>/dev/null || \
  echo "WARNING: could not scale ingress operator"

echo "==> Waiting for router rollout..."
oc rollout status deployment/"$ROUTER_DEPLOYMENT" -n "$INGRESS_NS" --timeout=180s 2>/dev/null || true

echo "==> Teardown complete. EMS enforcement restored."
