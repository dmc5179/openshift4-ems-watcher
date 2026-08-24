#!/bin/bash
# Remove the FIPS EMS webhook and restore original router behavior.
set -euo pipefail

echo "==> Deleting MutatingWebhookConfiguration..."
oc delete mutatingwebhookconfiguration fips-ems-webhook --ignore-not-found

echo "==> Deleting webhook namespace..."
oc delete namespace fips-ems-webhook --ignore-not-found

echo "==> Deleting ConfigMap from openshift-ingress..."
oc delete configmap fips-ems-override -n openshift-ingress --ignore-not-found

echo "==> Deleting router pods to restore original crypto policy..."
oc delete pods -n openshift-ingress \
  -l 'ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default'

echo "==> Waiting for router rollout..."
sleep 5
oc rollout status deployment/router-default -n openshift-ingress --timeout=180s

echo "==> Teardown complete. EMS enforcement restored."
