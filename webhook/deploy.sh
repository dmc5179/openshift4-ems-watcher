#!/bin/bash
# Deploy the FIPS EMS MutatingAdmissionWebhook.
#
# This creates:
#   - ConfigMap fips-ems-override in openshift-ingress (crypto policy files)
#   - Namespace fips-ems-webhook with webhook deployment and service
#   - MutatingWebhookConfiguration with service CA bundle
#
# The webhook intercepts router pod creation and injects the ConfigMap
# volume mounts. The ingress operator is NOT modified.
#
# After deploying, existing router pods are deleted so they get
# recreated with the mutated spec.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INGRESS_NS="${INGRESS_NS:-openshift-ingress}"

echo "==> Applying webhook manifests..."
oc apply -f "$SCRIPT_DIR/manifests.yaml"

echo "==> Waiting for TLS secret to be generated..."
for i in $(seq 1 30); do
  if oc get secret fips-ems-webhook-tls -n fips-ems-webhook &>/dev/null; then
    echo "    TLS secret ready."
    break
  fi
  sleep 2
done

echo "==> Waiting for webhook deployment to be ready..."
oc rollout status deployment/fips-ems-webhook -n fips-ems-webhook --timeout=120s

echo "==> Injecting service CA bundle into webhook configuration..."
# The service.beta.openshift.io/inject-cabundle annotation on
# MutatingWebhookConfiguration does not always work. Extract the
# service CA from a ConfigMap and patch it in manually.
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: service-ca-bundle
  namespace: fips-ems-webhook
  annotations:
    service.beta.openshift.io/inject-cabundle: "true"
data: {}
EOF

echo "    Waiting for CA injection..."
CA_PEM=""
for i in $(seq 1 30); do
  CA_PEM=$(oc get configmap service-ca-bundle -n fips-ems-webhook \
    -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null)
  if [[ -n "$CA_PEM" ]]; then
    echo "    Service CA bundle retrieved."
    break
  fi
  sleep 2
done

if [[ -z "$CA_PEM" ]]; then
  echo "ERROR: Could not retrieve service CA bundle."
  exit 1
fi

CA_B64=$(echo -n "$CA_PEM" | base64 -w0)

# Delete and recreate the webhook config with the CA bundle inline.
# oc patch with strategic merge requires all webhook fields, and
# JSON patch fails on the caBundle field, so replace is simplest.
oc delete mutatingwebhookconfiguration fips-ems-webhook --ignore-not-found
cat <<EOF | oc apply -f -
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: fips-ems-webhook
webhooks:
  - name: fips-ems.openshift-ingress.svc
    admissionReviewVersions: ["v1"]
    sideEffects: None
    failurePolicy: Ignore
    reinvocationPolicy: IfNeeded
    matchPolicy: Equivalent
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: In
          values: ["$INGRESS_NS"]
    objectSelector:
      matchLabels:
        ingresscontroller.operator.openshift.io/deployment-ingresscontroller: default
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
        scope: Namespaced
    clientConfig:
      caBundle: "$CA_B64"
      service:
        name: fips-ems-webhook
        namespace: fips-ems-webhook
        path: /mutate
        port: 443
EOF

echo ""
echo "==> Deleting router pods to trigger mutation..."
oc delete pods -n "$INGRESS_NS" \
  -l 'ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default'

echo "==> Waiting for router rollout..."
sleep 5
oc rollout status deployment/router-default -n "$INGRESS_NS" --timeout=180s

echo ""
echo "==> Checking webhook logs..."
oc logs deployment/fips-ems-webhook -n fips-ems-webhook --tail=10

echo ""
echo "==> Verifying router pod has the volume mount..."
POD=$(oc get pods -n "$INGRESS_NS" \
  -l 'ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default' \
  -o jsonpath='{.items[0].metadata.name}')
echo "Pod: $POD"
HAS_VOL=$(oc get pod "$POD" -n "$INGRESS_NS" \
  -o jsonpath='{.spec.volumes[?(@.name=="fips-ems-override")].name}')
if [[ "$HAS_VOL" == "fips-ems-override" ]]; then
  echo "  Volume mount: PRESENT"
  oc exec "$POD" -c router -n "$INGRESS_NS" -- \
    grep 'tls1-prf-ems-check' /etc/crypto-policies/back-ends/openssl_fips.config
  oc exec "$POD" -c router -n "$INGRESS_NS" -- \
    grep 'RHNoEnforceEMSinFIPS' /etc/crypto-policies/back-ends/opensslcnf.config
else
  echo "  ERROR: Volume mount NOT found on pod"
  exit 1
fi

echo ""
echo "==> Done. Verify with:"
echo "    echo | openssl s_client -connect <route-host>:443 -tls1_2 -no_ems 2>&1 | grep 'Cipher is'"
