# FIPS EMS Relaxation for OpenShift Ingress Router Pods

Relaxes FIPS 140-3 Extended Master Secret (EMS) enforcement on OpenShift ingress router pods so that TLS 1.2 clients without EMS support can connect.

> **Warning:** This is **unsupported by Red Hat**. It weakens the FIPS 140-3 TLS 1.2 posture. Use only when you have clients that cannot negotiate TLS 1.3 or TLS 1.2 with EMS, and you accept the reduced security posture.

## Background

RHEL 9 / OpenShift 4.17+ with FIPS enabled enforces FIPS 140-3, which requires TLS 1.2 connections to use Extended Master Secret (RFC 7627). Clients that don't support EMS are rejected at the TLS handshake.

EMS enforcement happens at **two levels** inside the router container:

| Level | File | Setting |
|-------|------|---------|
| FIPS provider (libcrypto) | `/etc/crypto-policies/back-ends/openssl_fips.config` and `/etc/pki/tls/fips_local.cnf` | `tls1-prf-ems-check = 1` |
| libssl | `/etc/crypto-policies/back-ends/opensslcnf.config` | (absent — needs `Options = RHNoEnforceEMSinFIPS`) |

Both must be changed for relaxation to take effect. On a standard RHEL host, `update-crypto-policies --set FIPS:NO-ENFORCE-EMS` handles this. That binary is not available inside the router container image.

### HAProxy and OpenSSL config loading

HAProxy initializes OpenSSL **once at process startup**. Modifying crypto policy files in a running container has no effect until HAProxy starts a new process. HAProxy's `-sf` (soft reload) starts a genuinely new OS process that re-reads all OpenSSL config from disk — so modifications made before a reload DO take effect.

However, HAProxy overrides some OpenSSL settings (like `MaxProtocol`) via its own config directives. The EMS settings operate at a layer HAProxy does not override, so they respond correctly to file modifications + reload.

## Methods

Three tested approaches are provided. Choose based on your constraints.

```
fips-ems-watcher/
├── README.md                       # This file
├── example-openssl-default.cnf     # Reference: default openssl.cnf from a router pod
├── webhook/                        # Method 1: MutatingAdmissionWebhook (recommended)
│   ├── manifests.yaml
│   ├── webhook.py                  # Webhook server source (also embedded in manifests)
│   ├── deploy.sh
│   └── teardown.sh
├── configmap/                      # Method 2: ConfigMap volume mount
│   ├── manifests.yaml
│   ├── deploy.sh
│   ├── teardown.sh
│   ├── watcher.sh                  # Optional: monitors for drift
│   └── deployment.yaml             # Optional: watcher deployment
└── nsenter/                        # Method 3: nsenter from worker nodes
    ├── deploy.sh
    └── teardown.sh
```

---

### Method 1: MutatingAdmissionWebhook (`webhook/`) — Recommended

A webhook that intercepts router pod creation in the `openshift-ingress` namespace and injects ConfigMap volume mounts with the modified crypto policy files. The ingress operator stays running at full scale.

**How it works:**
1. Creates a ConfigMap `fips-ems-override` in `openshift-ingress` with the modified crypto policy files
2. Deploys a Python webhook server in namespace `fips-ems-webhook` with OpenShift service-serving TLS certs
3. Creates a `MutatingWebhookConfiguration` scoped to pod CREATE in `openshift-ingress` matching the router label
4. When the ReplicaSet controller creates a router pod, the webhook mutates the pod spec to add the ConfigMap volume and subPath mounts
5. The router pod starts with the relaxed EMS policy from first boot

**Pros:**
- **Ingress operator stays running** at full scale — no operator changes needed
- **Operator does not fight the mutation** — tested and confirmed. The operator reconciles the Deployment template, not individual pod specs. The webhook mutates pods after the ReplicaSet controller creates them.
- Survives pod restarts — new pods get mutated automatically by the webhook
- Self-contained inside the cluster — no SSH or node access needed
- `failurePolicy: Ignore` — if the webhook is down, router pods still start (with default FIPS policy)

**Cons:**
- Requires deploying a webhook service (pod + TLS cert)
- The `service.beta.openshift.io/inject-cabundle` annotation does not reliably work on `MutatingWebhookConfiguration` — the deploy script extracts the service CA manually
- If the webhook pod is down when router pods restart, those pods will not have the EMS relaxation until they are deleted and recreated with the webhook running

**Usage:**
```bash
cd webhook/
./deploy.sh      # Deploy webhook, recreate router pods with mutation
./teardown.sh    # Remove webhook, restore original behavior
```

---

### Method 2: ConfigMap Volume Mount (`configmap/`)

Mounts a ConfigMap containing modified crypto policy files over the originals in the router deployment using `subPath` volume mounts.

**How it works:**
1. Creates a ConfigMap `fips-ems-override` in `openshift-ingress` with the modified `openssl_fips.config` and `opensslcnf.config`
2. Scales the ingress operator to 0 replicas to prevent reconciliation
3. Patches the `router-default` Deployment to mount the ConfigMap files over `/etc/crypto-policies/back-ends/openssl_fips.config` and `/etc/crypto-policies/back-ends/opensslcnf.config`
4. Router pods roll out with the relaxed policy active from first boot

**Pros:**
- Self-contained inside the cluster (no SSH or node access needed)
- Survives HAProxy reloads (files are on the volume mount, not the overlay)
- Survives pod restarts (mount is on the Deployment spec)
- Simple — just a ConfigMap and a JSON patch

**Cons:**
- **Ingress operator must be scaled to 0.** While down, no IngressController CR changes are reconciled (no new route shards, no operator-managed cert rotation, no TLS profile changes via the CR). The router pods themselves continue serving traffic normally.
- CVO (Cluster Version Operator) may scale the ingress operator back to 1 during cluster upgrades or drift reconciliation, which would revert the patch.
- Optional `watcher.sh` can detect and alert if the operator reverts the change, but cannot re-apply without the operator being scaled back down.

**Usage:**
```bash
cd configmap/
./deploy.sh      # Apply relaxation
./teardown.sh    # Restore original behavior
```

---

### Method 3: nsenter from Worker Nodes (`nsenter/`)

SSHes to each worker node hosting a router pod, uses `nsenter` to modify crypto policy files as root inside the container's mount namespace, then triggers a HAProxy reload via a route annotation change.

**How it works:**
1. Finds all running router pods and their host nodes
2. SSHes to each node, finds the router container PID via `crictl`
3. Uses `nsenter -t $PID -m` to enter the container's mount namespace as root
4. Modifies `openssl_fips.config`, `fips_local.cnf`, and `opensslcnf.config` via `sed`
5. Annotates a route to trigger the openshift-router to reload HAProxy with `-sf`
6. The new HAProxy process reads the modified files from the container overlay

**Pros:**
- **Ingress operator stays running** at full scale — no disruption to operator-managed features
- No cluster resources created (no ConfigMap, no Deployment patches)
- Quick to apply and revert

**Cons:**
- **Requires SSH access to worker nodes** (key-based, core user with sudo on RHCOS)
- Changes are ephemeral — a pod restart resets the overlay filesystem, requiring re-application
- Must be run from outside the cluster (bastion, jump host, or external watcher) unless a privileged DaemonSet is deployed (see below)
- Must be applied to each router pod individually

**Usage:**
```bash
cd nsenter/
SSH_KEY=~/.ssh/my-key.pem ./deploy.sh      # Apply relaxation
SSH_KEY=~/.ssh/my-key.pem ./teardown.sh    # Restore
```

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `SSH_KEY` | `~/.ssh/danclark-personal.pem` | Path to SSH private key for worker nodes |
| `SSH_USER` | `core` | SSH user on worker nodes |
| `INGRESS_NS` | `openshift-ingress` | Router pod namespace |
| `RELOAD_ROUTE_NS` | (auto-detected) | Namespace of route to annotate for reload trigger |
| `RELOAD_ROUTE_NAME` | (auto-detected) | Name of route to annotate for reload trigger |

#### In-cluster nsenter via privileged DaemonSet

The nsenter approach can be made self-contained inside the cluster by deploying a privileged DaemonSet on worker nodes. The DaemonSet pods would:
- Run with `hostPID: true` and `privileged` SCC
- Watch for router containers via `crictl`
- Apply the crypto policy modifications via nsenter
- Monitor for pod restarts and re-apply

This trades SSH access for a privileged workload inside the cluster. The DaemonSet needs `privileged` SCC, which is a significant security surface — it has full root access to the node.

---

## Other Approaches Considered

### 4. Custom Router Image

Build a custom container image based on the official router image with the crypto policy pre-modified, then force the router deployment to use it.

**How it would work:**
1. Pull the official router image from the release payload
2. Build a new image `FROM` it that runs `update-crypto-policies --set FIPS:NO-ENFORCE-EMS` (or directly modifies the files)
3. Push to a registry accessible by the cluster
4. Patch the router Deployment to use the custom image

**Assessment:**
- Requires scaling the ingress operator to 0 (same as ConfigMap method) because the operator controls the router image via the release payload. There is no supported IngressController CR field to override the router image.
- The image must be rebuilt for every OpenShift z-stream or minor upgrade to stay current with security fixes.
- Introduces supply chain concerns — you're now maintaining a fork of a core infrastructure image.
- **Not recommended** unless you already have an image pipeline for OpenShift infrastructure components.

### 5. External Watcher (Bastion / Jump Host)

An automated version of the nsenter method: a service running outside the cluster that watches the Kubernetes API for router pod events and SSHes to nodes to apply modifications.

**How it would work:**
1. A systemd service or cron job on a bastion host watches `oc get pods -w` for router pod Ready events
2. On detecting a new or restarted router pod, it SSHes to the hosting node and runs the nsenter modification
3. Triggers a HAProxy reload via route annotation

**Security considerations:**
- The watcher runs **outside the cluster blast radius** — compromising a cluster workload does not give an attacker access to the watcher or the SSH keys
- The SSH key grants root-equivalent access to worker nodes (via `core` + sudo), so it must be tightly controlled
- API access can be scoped to a read-only ServiceAccount (pods/list, pods/watch) plus the ability to annotate one route
- Network exposure is limited: the watcher needs outbound access to the API server and SSH to worker nodes
- **Compared to the in-cluster DaemonSet**: the external watcher has a smaller in-cluster footprint (no privileged pods) but moves the trust boundary to an external machine

**Assessment:** This is the nsenter method with automation. Good fit when you already have a bastion with node access and want to avoid any privileged workloads inside the cluster.

### 6. Node-Level Crypto Policy (MachineConfig)

Use a MachineConfig to set `FIPS:NO-ENFORCE-EMS` on worker nodes where router pods run.

**Assessment:**
- **Rejected.** This modifies the crypto policy for the entire node, affecting all workloads — not just the router. The user requirement is to scope changes to ingress router pods only.
- Would also affect node-level services (kubelet, CRI-O, etc.) which should maintain strict FIPS compliance.

### 7. Copy `update-crypto-policies` Into the Container

Copy the `update-crypto-policies` binary from the host into the router container and run it.

**Assessment:**
- Requires root access to write the binary (same nsenter problem)
- The binary may depend on host-installed Python modules or paths that differ inside the container
- Fragile across upgrades
- **Not recommended** — direct file modification via sed is simpler and has fewer dependencies.

## Verification

After applying either method, test with a client that does not send EMS:

```bash
# From a FIPS:NO-ENFORCE-EMS host (client must also allow no-EMS):
echo | openssl s_client -connect <route-host>:443 -servername <route-host> -tls1_2 -no_ems 2>&1 | grep 'Cipher is'

# Success: "Cipher is ECDHE-RSA-AES128-GCM-SHA256" (or similar)
# Failure: "Cipher is (NONE)"
```

Confirm that standard TLS still works:

```bash
# TLS 1.2 with EMS
echo | openssl s_client -connect <route-host>:443 -servername <route-host> -tls1_2 2>&1 | grep 'Cipher is'

# TLS 1.3
echo | openssl s_client -connect <route-host>:443 -servername <route-host> -tls1_3 2>&1 | grep 'Cipher is'
```

Confirm that node crypto policy is unchanged:

```bash
oc debug node/<node-name> -- chroot /host update-crypto-policies --show
# Should output: FIPS (not FIPS:NO-ENFORCE-EMS)
```
