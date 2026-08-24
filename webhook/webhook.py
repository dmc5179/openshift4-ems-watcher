#!/usr/bin/env python3
"""
MutatingAdmissionWebhook that injects FIPS EMS relaxation into router pods.

Intercepts pod creation in openshift-ingress and adds a ConfigMap volume
mount with modified crypto policy files (tls1-prf-ems-check=0 and
Options=RHNoEnforceEMSinFIPS). The ConfigMap 'fips-ems-override' must
exist in the openshift-ingress namespace.
"""

import json
import ssl
import sys
import base64
from http.server import HTTPServer, BaseHTTPRequestHandler

CERT_PATH = "/tls/tls.crt"
KEY_PATH = "/tls/tls.key"
PORT = 8443

PATCH = json.dumps([
    {
        "op": "add",
        "path": "/spec/volumes/-",
        "value": {
            "name": "fips-ems-override",
            "configMap": {"name": "fips-ems-override"},
        },
    },
    {
        "op": "add",
        "path": "/spec/containers/0/volumeMounts/-",
        "value": {
            "name": "fips-ems-override",
            "mountPath": "/etc/crypto-policies/back-ends/openssl_fips.config",
            "subPath": "openssl_fips.config",
            "readOnly": True,
        },
    },
    {
        "op": "add",
        "path": "/spec/containers/0/volumeMounts/-",
        "value": {
            "name": "fips-ems-override",
            "mountPath": "/etc/crypto-policies/back-ends/opensslcnf.config",
            "subPath": "opensslcnf.config",
            "readOnly": True,
        },
    },
])

PATCH_B64 = base64.b64encode(PATCH.encode()).decode()

ROUTER_LABEL = "ingresscontroller.operator.openshift.io/deployment-ingresscontroller"


class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length))

        uid = body["request"]["uid"]
        pod = body["request"]["object"]
        labels = pod.get("metadata", {}).get("labels", {})

        should_patch = (
            ROUTER_LABEL in labels
            and not any(
                v.get("name") == "fips-ems-override"
                for v in pod.get("spec", {}).get("volumes", [])
            )
        )

        if should_patch:
            print(f"PATCH: injecting fips-ems-override into router pod (uid={uid})")
            resp = {
                "uid": uid,
                "allowed": True,
                "patchType": "JSONPatch",
                "patch": PATCH_B64,
            }
        else:
            reason = "not a router pod" if ROUTER_LABEL not in labels else "already patched"
            print(f"SKIP: {reason} (uid={uid})")
            resp = {"uid": uid, "allowed": True}

        review = {
            "apiVersion": "admission.k8s.io/v1",
            "kind": "AdmissionReview",
            "response": resp,
        }

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(review).encode())

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[webhook] {fmt % args}\n")
        sys.stderr.flush()


def main():
    server = HTTPServer(("0.0.0.0", PORT), WebhookHandler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT_PATH, KEY_PATH)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    print(f"Webhook server listening on :{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
