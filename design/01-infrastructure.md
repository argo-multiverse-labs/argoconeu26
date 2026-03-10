# 01 - Infrastructure Design

**Document:** Infrastructure foundation for the ArgoCon EU 2026 demo environment
**Talk:** Network Segmentation at Scale: GitOps-Driven Multi-Tenant Isolation With Argo CD
**Last updated:** 2026-03-09

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [KinD Cluster Configuration](#2-kind-cluster-configuration)
3. [Cilium Installation](#3-cilium-installation)
4. [ArgoCD Installation](#4-argocd-installation)
5. [Port Forwarding Strategy](#5-port-forwarding-strategy)
6. [Bootstrap Sequence](#6-bootstrap-sequence)
7. [Teardown and Reset](#7-teardown-and-reset)
8. [Makefile](#8-makefile)
9. [Risks and Concerns](#9-risks-and-concerns)
10. [Open Questions](#10-open-questions)

---

## 1. Prerequisites

All CLI tools required to build and run the demo environment.

| Tool | Minimum Version | Purpose | Install |
|------|----------------|---------|---------|
| `docker` | 24.0+ | Container runtime for KinD nodes | [docs.docker.com](https://docs.docker.com/engine/install/) |
| `kind` | 0.31.0+ | Local Kubernetes clusters | `go install sigs.k8s.io/kind@v0.31.0` |
| `kubectl` | 1.30+ | Kubernetes CLI | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| `helm` | 3.16+ | Helm chart installation | [helm.sh](https://helm.sh/docs/intro/install/) |
| `cilium` | 0.16+ | Cilium CLI (install, status, connectivity) | [docs.cilium.io](https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/#install-the-cilium-cli) |
| `hubble` | 1.16+ | Hubble CLI (flow observation) | [docs.cilium.io](https://docs.cilium.io/en/stable/gettingstarted/hubble_setup/#install-the-hubble-client) |
| `pv` | 1.6+ | Pipe viewer for demo-magic.sh typing simulation | `brew install pv` / `apt install pv` |

> **Note:** `kubectx` is not listed here because this demo uses a single KinD cluster and never switches contexts. The `kubectl` context is set automatically by `kind create cluster`.

### Host kernel requirements

Cilium on KinD runs inside Docker containers that share the host kernel. The following kernel requirements apply to the **host machine**, not the KinD nodes:

- **Linux kernel 5.10+** is required for full Cilium eBPF feature support (L7 proxy, Hubble, identity-based enforcement).
- **Kernel 5.4** works for basic L3/L4 policies but some L7 features may be degraded.
- The host machine in this repo runs kernel **6.17.0** which exceeds all requirements.

Required kernel modules (typically loaded by default on modern kernels):
- `ip_tables`
- `xt_socket`
- `ip6_tables`
- `xt_mark`
- `xt_CT`

These are normally present on any Linux distribution with Docker installed. macOS users run Docker Desktop which uses a Linux VM with a compatible kernel.

---

## 2. KinD Cluster Configuration

### File: `kind-cluster/kind-config.yaml`

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: argoconeu26
networking:
  # ---------------------------------------------------------------
  # CRITICAL: Disable the default kindnet CNI so Cilium can take over.
  # Without this, kindnet installs and conflicts with Cilium.
  # ---------------------------------------------------------------
  disableDefaultCNI: true
  # ---------------------------------------------------------------
  # Cilium handles kube-proxy functionality via eBPF. Disabling
  # kube-proxy is optional but recommended for a clean Cilium setup.
  # Set to false if you encounter issues during bootstrap.
  # ---------------------------------------------------------------
  # ---------------------------------------------------------------
  # NOTE: kubeProxyMode: none adds bootstrap complexity for no demo
  # benefit. The demo does not demonstrate kube-proxy replacement.
  # Consider removing this (use default kube-proxy) and setting
  # kubeProxyReplacement: false in Cilium values to reduce risk.
  # ---------------------------------------------------------------
  kubeProxyMode: none
nodes:
  # ----- Control Plane -----
  - role: control-plane
    image: kindest/node:v1.32.11@sha256:5fc52d52a7b9574015299724bd68f183702956aa4a2116ae75a63cb574b35af8
    extraPortMappings:
      # ArgoCD UI (HTTP — server runs with --insecure)
      - containerPort: 30443
        hostPort: 30443
        protocol: TCP
      # Hubble UI
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP
      # Demo shared-service (config API on 8080)
      - containerPort: 30880
        hostPort: 30880
        protocol: TCP
    # ---------------------------------------------------------------
    # Mount propagation required for Cilium's BPF filesystem.
    # Cilium needs to mount bpffs at /sys/fs/bpf and this must
    # propagate correctly within the KinD container.
    # ---------------------------------------------------------------
    extraMounts:
      - hostPath: /proc/sys/net/core/bpf_jit_enable
        containerPath: /proc/sys/net/core/bpf_jit_enable
  # ----- Worker 1 -----
  # NOTE: 1 worker node is sufficient. CiliumNetworkPolicy enforcement
  # is identity-based, not node-based, so 2 workers provide no demo
  # benefit. A second worker only adds resource overhead.
  - role: worker
    image: kindest/node:v1.32.11@sha256:5fc52d52a7b9574015299724bd68f183702956aa4a2116ae75a63cb574b35af8
```

### Design decisions

**Node count: 1 control-plane + 1 worker.** CiliumNetworkPolicy enforcement is identity-based, not node-based, so multiple workers provide no demo benefit. A single worker is sufficient to demonstrate all network policy scenarios. Adding workers only increases resource overhead.

**Kubernetes version: v1.32.11.** Pinned with SHA256 digest for reproducibility (KinD 0.31.0 supports v1.31 through v1.35). Using v1.32 as a well-tested LTS version; v1.35.0 is available if newer features are needed.

**`disableDefaultCNI: true`** is mandatory. Without it, kindnet installs as the CNI and Cilium cannot take over pod networking.

**`kubeProxyMode: none`** disables kube-proxy so Cilium handles service routing via eBPF. However, the demo does not demonstrate kube-proxy replacement, so this adds bootstrap risk for no demo benefit. Consider removing this setting and setting `kubeProxyReplacement: false` in Cilium values. If kept, be aware that Cilium must be installed before CoreDNS and other system pods can start.

**Port mappings** use the 30xxx range via NodePort services:
- `30443` -- ArgoCD UI (HTTP via NodePort; `--insecure` mode)
- `30080` -- Hubble UI (HTTP via NodePort)
- `30880` -- Shared config-api service (for live L7 demo)

**Worker node labels** have been removed. The labels `workload=apps` and `workload=system` were never referenced by any nodeSelector in the demo manifests, so they added no value.

**extraMounts for bpf_jit_enable** ensures the eBPF JIT compiler is accessible inside the KinD container. This is typically already enabled on modern kernels but the explicit mount avoids edge cases.

---

## 3. Cilium Installation

### Helm repository

```
Repository: https://helm.cilium.io
Chart: cilium/cilium
Version: 1.19.1
```

**Version rationale:** Cilium 1.19.1 is the current stable release. It supports all features required by the demo: L7 HTTP policy filtering, Hubble with UI, DNS-aware egress policies (`toFQDNs`), ServiceAccount-based identity, and full KinD compatibility.

### File: `helm-values/cilium-values.yaml`

```yaml
# =============================================================================
# Cilium Helm values for KinD cluster — ArgoConEU26 demo
# Chart: cilium/cilium v1.19.1
# =============================================================================

# -- Cilium agent image
image:
  repository: quay.io/cilium/cilium
  tag: v1.19.1
  pullPolicy: IfNotPresent

# -- Kube-proxy replacement mode (matches kubeProxyMode: none in KinD config)
kubeProxyReplacement: true

# -- K8s service host/port for KinD (required when kube-proxy is disabled)
# KinD exposes the API server on the control-plane node.
k8sServiceHost: argoconeu26-control-plane
k8sServicePort: 6443

# -- Operator configuration
operator:
  replicas: 1
  image:
    repository: quay.io/cilium/operator-generic
    tag: v1.19.1

# -- IPAM mode (cluster-pool is default and works well with KinD)
ipam:
  mode: kubernetes

# -- Enable L7 proxy (REQUIRED for HTTP path filtering in Scene 1)
l7Proxy: true

# -- Enable Hubble (REQUIRED for Scene 3 observability)
hubble:
  enabled: true
  relay:
    enabled: true
    image:
      repository: quay.io/cilium/hubble-relay
      tag: v1.19.1
  ui:
    enabled: true
    replicas: 1
    ingress:
      enabled: false
    # Image tags omitted — use chart defaults matching Cilium 1.19.1
  # NOTE: The metrics block is stripped to just drop and flow since
  # there is no Prometheus/Grafana in this demo. Add dns, tcp,
  # port-distribution, icmp, httpV2 back if a metrics stack is added.
  metrics:
    enabled:
      - drop
      - flow

# -- Enable policy audit mode (useful during development, disable for demo)
# policyAuditMode: false

# -- Security context for KinD compatibility
securityContext:
  capabilities:
    ciliumAgent:
      - CHOWN
      - KILL
      - NET_ADMIN
      - NET_RAW
      - IPC_LOCK
      - SYS_ADMIN
      - SYS_RESOURCE
      - DAC_OVERRIDE
      - FOWNER
      - SETGID
      - SETUID
    cleanCiliumState:
      - NET_ADMIN
      - SYS_ADMIN
      - SYS_RESOURCE

# -- Container runtime interface (containerd for KinD)
cgroup:
  autoMount:
    enabled: false
  hostRoot: /sys/fs/cgroup

# -- BPF settings
bpf:
  masquerade: true
  mount: /sys/fs/bpf

# -- Routing mode (tunnel is safest for KinD)
routingMode: tunnel
tunnelProtocol: vxlan

# -- Debug (enable during development, disable for demo performance)
debug:
  enabled: false
```

### Key Cilium features required by the talk

| Feature | Cilium Setting | Used In |
|---------|---------------|---------|
| L7 HTTP path filtering | `l7Proxy: true` | Scene 1 Beat 2 -- blocking `/admin/*` paths |
| DNS-aware egress (`toFQDNs`) | Enabled by default when L7 proxy is on | Scene 1 -- DNS-aware egress policies |
| Hubble flow observation | `hubble.enabled: true`, `hubble.relay.enabled: true` | Scene 3 Beat 2 -- `hubble observe` |
| Hubble UI | `hubble.ui.enabled: true` | Scene 3 Beat 2 -- visual flow map |
| ServiceAccount identity | Enabled by default | Scene 4 -- SA-scoped CiliumNetworkPolicies |
| Hubble HTTP metrics | `hubble.metrics.enabled` with `httpV2` | Scene 3 -- HTTP-level flow visibility |

### Installation command

```bash
helm repo add cilium https://helm.cilium.io
helm repo update

helm install cilium cilium/cilium \
  --version 1.19.1 \
  --namespace kube-system \
  --values helm-values/cilium-values.yaml \
  --wait \
  --timeout 5m
```

### Post-install validation

```bash
# Wait for Cilium to be ready
cilium status --wait

# Verify Cilium is the active CNI (all nodes should show "ready")
kubectl get nodes -o wide

# Verify all pods are running (should not be stuck in Init/Pending)
kubectl get pods -n kube-system -l app.kubernetes.io/part-of=cilium

# Verify Hubble relay is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=hubble-relay

# Verify Hubble UI is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=hubble-ui

# Quick connectivity test (optional, takes ~2 minutes)
cilium connectivity test --single-node
```

---

## 4. ArgoCD Installation

### Helm repository

```
Repository: https://argoproj.github.io/argo-helm
Chart: argo/argo-cd
Chart version: 9.4.9
App version: v3.3.3
```

**Version rationale:** ArgoCD 3.3.3 is the current stable release. Sync impersonation was introduced in 2.10 and is mature in 3.x. The chart version 9.4.9 deploys ArgoCD v3.3.3.

### File: `helm-values/argocd-values.yaml`

```yaml
# =============================================================================
# ArgoCD Helm values for KinD cluster — ArgoConEU26 demo
# Chart: argo/argo-cd v9.4.9 (ArgoCD v3.3.3)
# =============================================================================

nameOverride: argocd

# -- CRDs
crds:
  install: true
  keep: true

# -- Global settings
global:
  domain: argocd.local

# -- Server configuration
server:
  # Run in insecure mode (no TLS termination at the server).
  # Acceptable for local KinD demos. Simplifies port forwarding.
  extraArgs:
    - --insecure
  service:
    type: NodePort
    # NOTE: Despite the key name "nodePortHttps", the server runs in
    # --insecure mode (plain HTTP). Access via http://localhost:30443.
    nodePortHttps: 30443

# -- Repo server
repoServer:
  replicas: 1

# -- Application controller
controller:
  replicas: 1

# -- ApplicationSet controller (REQUIRED for Scene 3)
applicationSet:
  enabled: true
  replicas: 1

# -- Notifications controller (not needed for demo)
notifications:
  enabled: false

# -- DEX (SSO — not needed for local demo)
dex:
  enabled: false

# -- Redis
redis:
  enabled: true

# -- Config map overrides (argocd-cm)
configs:
  cm:
    # Allow insecure access (no TLS) for local demo
    server.insecure: "true"
    # Disable admin password notification banner
    admin.enabled: "true"
    # ----------------------------------------------------------
    # ApplicationSet controller settings
    # ----------------------------------------------------------
    applicationsetcontroller.enable.progressive.syncs: "true"

  params:
    # Server insecure mode
    server.insecure: "true"
    # Allow Applications in any namespace (needed for tenant namespaces).
    # SECURITY NOTE: The wildcard "*" allows Applications to be created
    # in ANY namespace, weakening multi-tenant isolation. For production
    # or a tighter demo, scope this to specific tenant namespaces, e.g.:
    #   application.namespaces: "tenant-a,tenant-b,tenant-c,shared-services"
    application.namespaces: "*"

  rbac:
    # Default RBAC policy — deny all, explicit grants per tenant.
    # This gets refined in the ArgoCD security progression (design doc 04).
    policy.default: role:readonly
    policy.csv: |
      # Admin role for demo operator
      g, admin, role:admin

  # -- Known hosts and repository credentials
  repositories: {}
  credentialTemplates: {}

# -- Resource limits (keep low for KinD)
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

### Installation command

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd \
  --version 9.4.9 \
  --namespace argocd \
  --create-namespace \
  --values helm-values/argocd-values.yaml \
  --wait \
  --timeout 5m
```

### Post-install validation

```bash
# Wait for all ArgoCD pods to be ready
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

# Get the initial admin password
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d && echo

# Verify the server is accessible
kubectl get svc argocd-server -n argocd

# Verify ApplicationSet controller is running
kubectl get pods -n argocd -l app.kubernetes.io/component=applicationset-controller
```

### Sync impersonation configuration (Scene 4)

Sync impersonation is configured per-Application or globally via `argocd-cm`. The infrastructure install does NOT enable it by default -- it is enabled during Scene 4 of the demo as the "fix." The before/after configuration is covered in design doc 04, but the relevant `argocd-cm` patch is:

```yaml
# Applied during Scene 4 (NOT during initial bootstrap)
configs:
  cm:
    # Enable sync impersonation globally
    application.sync.impersonation.enabled: "true"
```

This requires corresponding RBAC (Roles and RoleBindings) in each tenant namespace to allow ArgoCD to impersonate tenant ServiceAccounts. Those are provisioned by the ApplicationSet in Scene 3.

---

## 5. Port Forwarding Strategy

The demo uses two complementary access methods:

### Method 1: NodePort services (primary for demo)

NodePort services are mapped through KinD's `extraPortMappings` so they are accessible on `localhost` without any port-forward commands. This is the most reliable method for live demos -- no background processes to manage.

| Service | NodePort | Host URL | Notes |
|---------|----------|----------|-------|
| ArgoCD UI | 30443 | `http://localhost:30443` | Server runs with `--insecure` (plain HTTP); port number is convention only |
| Hubble UI | 30080 | `http://localhost:30080` | Requires NodePort service for hubble-ui (see below) |
| Shared config-api | 30880 | `http://localhost:30880` | For live L7 demo in Scene 1 |

#### Hubble UI NodePort service

Hubble UI does not expose a NodePort by default. Apply this manifest after Cilium installation:

```yaml
# File: manifests/infrastructure/hubble-ui-nodeport.yaml
apiVersion: v1
kind: Service
metadata:
  name: hubble-ui-nodeport
  namespace: kube-system
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: hubble-ui
  ports:
    - port: 80
      targetPort: 8081
      nodePort: 30080
      protocol: TCP
```

### Method 2: kubectl port-forward (fallback)

If NodePort services have issues (or for ad-hoc access), use port-forward:

```bash
# ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8081:443 &

# Hubble UI
kubectl port-forward svc/hubble-ui -n kube-system 8082:80 &

# Hubble Relay (for hubble CLI)
kubectl port-forward svc/hubble-relay -n kube-system 4245:80 &
```

### Hubble CLI access

The `hubble` CLI connects to Hubble Relay. After port-forwarding relay:

```bash
# Observe all flows
hubble observe --server localhost:4245

# Observe flows for a specific namespace (tenant-a)
hubble observe --server localhost:4245 --namespace tenant-a

# Observe denied flows only (key for Scene 3 Beat 2)
hubble observe --server localhost:4245 --verdict DROPPED

# Observe flows between two namespaces
hubble observe --server localhost:4245 \
  --from-namespace tenant-a --to-namespace tenant-b
```

Alternatively, use `cilium hubble port-forward &` to automatically set up relay access on port 4245.

---

## 6. Bootstrap Sequence

The exact order of operations from zero to a fully running demo environment. Each step must complete before the next begins.

```
Step 1: Preflight checks
    |
    v
Step 2: Create KinD cluster (disableDefaultCNI, kubeProxyMode: none)
    |    Nodes come up but pods are Pending (no CNI)
    v
Step 3: Install Cilium via Helm
    |    CNI initializes, pods start scheduling
    |    Wait for cilium status --wait
    v
Step 4: Apply Hubble UI NodePort service
    |
    v
Step 5: Install ArgoCD via Helm
    |    Wait for all ArgoCD pods Ready
    v
Step 6: Print access information (passwords, URLs)
    |
    v
DONE — cluster is ready for demo content
```

### Timing expectations

| Step | Expected Duration |
|------|-------------------|
| KinD cluster creation | ~30-60 seconds |
| Cilium install + ready | ~2-3 minutes |
| ArgoCD install + ready | ~1-2 minutes |
| **Total** | **~4-6 minutes** |

### Implementation as shell script

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIND_CLUSTER_NAME="argoconeu26"
CILIUM_VERSION="1.19.1"
ARGOCD_CHART_VERSION="9.4.9"

# Detect OS for base64 compatibility
if [[ "$(uname -s)" == "Darwin" ]]; then
  BASE64_DECODE="base64 -D"
else
  BASE64_DECODE="base64 -d"
fi

echo "============================================"
echo " ArgoCon EU 2026 Demo — Bootstrap"
echo "============================================"

# ------------------------------------------
# Step 1: Preflight checks
# ------------------------------------------
echo "[1/6] Preflight checks..."
for cmd in docker kind kubectl helm cilium; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is not installed. See design/01-infrastructure.md for prerequisites."
    exit 1
  fi
done
echo "  All tools found."

# ------------------------------------------
# Step 2: Create KinD cluster
# ------------------------------------------
echo "[2/6] Creating KinD cluster '${KIND_CLUSTER_NAME}'..."
if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
  echo "  Cluster already exists. Skipping creation."
else
  kind create cluster \
    --name "${KIND_CLUSTER_NAME}" \
    --config "${SCRIPT_DIR}/kind-cluster/kind-config.yaml" \
    --wait 1m \
    --retain
fi
kubectl config use-context "kind-${KIND_CLUSTER_NAME}"
echo "  Cluster created. Nodes are up but pods are Pending (no CNI yet)."

# ------------------------------------------
# Step 3: Install Cilium
# ------------------------------------------
echo "[3/6] Installing Cilium ${CILIUM_VERSION}..."
helm repo add cilium https://helm.cilium.io 2>/dev/null || true
helm repo update cilium

if helm status cilium -n kube-system &>/dev/null; then
  echo "  Cilium already installed. Upgrading..."
  helm upgrade cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    --values "${SCRIPT_DIR}/helm-values/cilium-values.yaml" \
    --wait --timeout 5m
else
  helm install cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    --values "${SCRIPT_DIR}/helm-values/cilium-values.yaml" \
    --wait --timeout 5m
fi

echo "  Waiting for Cilium to report ready..."
cilium status --wait --wait-duration 5m
echo "  Cilium is ready."

# ------------------------------------------
# Step 4: Hubble UI NodePort service
# ------------------------------------------
echo "[4/6] Applying Hubble UI NodePort service..."
kubectl apply -f "${SCRIPT_DIR}/manifests/infrastructure/hubble-ui-nodeport.yaml"

# ------------------------------------------
# Step 5: Install ArgoCD
# ------------------------------------------
echo "[5/6] Installing ArgoCD (chart ${ARGOCD_CHART_VERSION})..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo

if helm status argocd -n argocd &>/dev/null; then
  echo "  ArgoCD already installed. Upgrading..."
  helm upgrade argocd argo/argo-cd \
    --version "${ARGOCD_CHART_VERSION}" \
    --namespace argocd \
    --values "${SCRIPT_DIR}/helm-values/argocd-values.yaml" \
    --wait --timeout 5m
else
  helm install argocd argo/argo-cd \
    --version "${ARGOCD_CHART_VERSION}" \
    --namespace argocd \
    --create-namespace \
    --values "${SCRIPT_DIR}/helm-values/argocd-values.yaml" \
    --wait --timeout 5m
fi

echo "  Waiting for ArgoCD pods..."
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s
echo "  ArgoCD is ready."

# ------------------------------------------
# Step 6: Print access information
# ------------------------------------------
echo "[6/6] Access information:"
echo ""
ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | $BASE64_DECODE)
echo "  ArgoCD UI:     http://localhost:30443"
echo "  ArgoCD user:   admin"
echo "  ArgoCD pass:   ${ARGOCD_PASSWORD}"
echo ""
echo "  Hubble UI:     http://localhost:30080"
echo ""
echo "  Hubble CLI:    cilium hubble port-forward &"
echo "                 hubble observe"
echo ""
echo "============================================"
echo " Bootstrap complete."
echo "============================================"
```

---

## 7. Teardown and Reset

### Full teardown

```bash
kind delete cluster --name argoconeu26
```

This removes the entire cluster, all state, all workloads. Clean and fast (~5 seconds).

### Reset to clean infrastructure (keep cluster, remove demo content)

For rehearsal velocity, it is faster to reset the demo state than to rebuild the cluster. This removes all tenant namespaces, ArgoCD Applications, and Projects while preserving the infrastructure (Cilium, ArgoCD):

```bash
#!/usr/bin/env bash
set -euo pipefail

# Delete all tenant namespaces
for ns in tenant-a tenant-b tenant-c shared-services; do
  kubectl delete namespace "$ns" --ignore-not-found
done

# Delete all ArgoCD Applications (except infrastructure)
kubectl delete applications.argoproj.io --all -n argocd

# Delete all ArgoCD AppProjects (except 'default')
kubectl get appprojects -n argocd -o name | grep -v 'default' | \
  xargs -r kubectl delete -n argocd

# Re-create the default project in its insecure state (Scene 0)
kubectl apply -f manifests/stage-0/default-project.yaml

echo "Demo reset to Stage 0 (Prologue). Infrastructure intact."
```

### Reset to a specific stage

Each stage of the demo has a corresponding manifest directory (see design doc 02-04 for stage definitions). To reset to a specific stage:

```bash
make reset-to-stage STAGE=2
```

This will:
1. Clean all demo content (as above)
2. Apply all manifests from `manifests/stage-0/` through `manifests/stage-N/`

---

## 8. Makefile

Top-level Makefile for the demo environment. Follows the pattern from the reference implementation at `local-cluster/argo-cdviz-flux/kind-cluster/Makefile`.

```makefile
SHELL ?= /bin/bash
KIND_CLUSTER_NAME = argoconeu26
CILIUM_VERSION = 1.19.1
ARGOCD_CHART_VERSION = 9.4.9

# Detect OS for base64 compatibility
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    BASE64_DECODE = base64 -D
else
    BASE64_DECODE = base64 -d
endif

.PHONY: help
help: ## This help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
.DEFAULT_GOAL := help

# ---- Preflight ----

HAS_DOCKER   := $(shell command -v docker;)
HAS_KUBECTL  := $(shell command -v kubectl;)
HAS_HELM     := $(shell command -v helm;)
HAS_KIND     := $(shell command -v kind;)
HAS_CILIUM   := $(shell command -v cilium;)

.PHONY: vendor
vendor: ## Preflight checks for required tools
ifndef HAS_DOCKER
	$(error You must install docker)
endif
ifndef HAS_KUBECTL
	$(error You must install kubectl)
endif
ifndef HAS_HELM
	$(error You must install helm)
endif
ifndef HAS_KIND
	$(error You must install kind)
endif
ifndef HAS_CILIUM
	$(error You must install cilium CLI)
endif

# ---- Cluster Lifecycle ----

.PHONY: kind-cluster
kind-cluster: vendor ## Create the KinD cluster
	@if kind get clusters 2>/dev/null | grep -q "^$(KIND_CLUSTER_NAME)$$"; then \
		echo "Cluster $(KIND_CLUSTER_NAME) already exists."; \
	else \
		kind create cluster --name $(KIND_CLUSTER_NAME) --wait 1m \
			--config kind-cluster/kind-config.yaml --retain; \
	fi
	kubectl config use-context kind-$(KIND_CLUSTER_NAME)

.PHONY: rm-kind
rm-kind: ## Delete the KinD cluster
	kind delete cluster --name $(KIND_CLUSTER_NAME)

# ---- Infrastructure ----

.PHONY: cilium-install
cilium-install: vendor ## Install Cilium CNI
	kubectl config use-context kind-$(KIND_CLUSTER_NAME)
	helm repo add cilium https://helm.cilium.io || true
	helm repo update cilium
	helm upgrade --install cilium cilium/cilium \
		--version $(CILIUM_VERSION) \
		--namespace kube-system \
		--values helm-values/cilium-values.yaml \
		--wait --timeout 5m
	cilium status --wait --wait-duration 5m
	kubectl apply -f manifests/infrastructure/hubble-ui-nodeport.yaml

.PHONY: argocd-install
argocd-install: vendor ## Install ArgoCD
	kubectl config use-context kind-$(KIND_CLUSTER_NAME)
	helm repo add argo https://argoproj.github.io/argo-helm || true
	helm repo update argo
	helm upgrade --install argocd argo/argo-cd \
		--version $(ARGOCD_CHART_VERSION) \
		--namespace argocd --create-namespace \
		--values helm-values/argocd-values.yaml \
		--wait --timeout 5m
	kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

# ---- Access ----

.PHONY: argocd-password
argocd-password: ## Print the ArgoCD admin password
	@kubectl get secret argocd-initial-admin-secret -n argocd \
		-o jsonpath='{.data.password}' | $(BASE64_DECODE) && echo

.PHONY: hubble-pf
hubble-pf: ## Port-forward Hubble Relay for hubble CLI
	cilium hubble port-forward &

.PHONY: info
info: ## Print all access URLs and credentials
	@echo "ArgoCD UI:   http://localhost:30443"
	@echo "ArgoCD user: admin"
	@printf "ArgoCD pass: "; kubectl get secret argocd-initial-admin-secret -n argocd \
		-o jsonpath='{.data.password}' | $(BASE64_DECODE); echo
	@echo ""
	@echo "Hubble UI:   http://localhost:30080"
	@echo "Hubble CLI:  make hubble-pf && hubble observe"

# ---- Full Lifecycle ----

.PHONY: build-all
build-all: kind-cluster cilium-install argocd-install info ## Full build: cluster + Cilium + ArgoCD

.PHONY: rebuild
rebuild: rm-kind build-all ## Nuke and rebuild everything from scratch

# ---- Demo Reset ----

.PHONY: reset-demo
reset-demo: ## Reset demo to Stage 0 (Prologue) — keeps infrastructure
	kubectl config use-context kind-$(KIND_CLUSTER_NAME)
	-kubectl delete namespace tenant-a tenant-b tenant-c shared-services 2>/dev/null
	-kubectl delete applications.argoproj.io --all -n argocd 2>/dev/null
	-kubectl get appprojects -n argocd -o name | grep -v 'default' | \
		xargs -r kubectl delete -n argocd 2>/dev/null
	@echo "Demo reset to Stage 0."

# ---- Kill Port Forwards ----

.PHONY: kill-pf
kill-pf: ## Kill all kubectl port-forward and cilium hubble port-forward processes
	@pids=$$(ps aux | grep -E "kubectl port-forward|cilium hubble" | grep -v grep | awk '{print $$2}'); \
	if [ -z "$$pids" ]; then \
		echo "No port-forward processes found."; \
	else \
		echo "Killing: $$pids"; \
		echo $$pids | xargs kill -9; \
	fi
```

---

## 9. Risks and Concerns

### Cilium on KinD

1. **Kernel version dependency.** Cilium's eBPF features require a modern host kernel. The host runs 6.17.0 which is excellent, but anyone cloning this repo on an older kernel (<5.10) may see degraded L7 proxy behavior or Cilium agent crashes. Document the minimum kernel in the README.

2. **`kubeProxyMode: none` bootstrap race.** When kube-proxy is fully disabled, Cilium must be installed before CoreDNS and other system pods can start (they need service routing to resolve DNS). KinD's `--wait` flag may time out if Cilium is not installed quickly enough. Mitigation: the `--retain` flag on `kind create cluster` prevents cleanup on failure, allowing manual recovery. If this proves flaky, set `kubeProxyMode` back to the default and set `kubeProxyReplacement: false` in Cilium values.

3. **Docker resource limits.** Running a 3-node KinD cluster with Cilium and ArgoCD requires approximately 4GB of RAM and 4 CPU cores allocated to Docker. On macOS/Docker Desktop, ensure the VM has sufficient resources.

4. **Cilium image pull time.** First-time setup pulls ~1.5GB of container images (Cilium agent, operator, Hubble relay, Hubble UI). On slow connections, the 5-minute Helm timeout may expire. Consider pre-pulling images or increasing the timeout.

### ArgoCD

5. **Insecure mode.** The ArgoCD server runs without TLS (`--insecure`). This is acceptable for a local KinD demo but must never be used in production. The design doc is explicit about this.

6. **NodePort 30443 with `--insecure`.** The ArgoCD server runs in `--insecure` mode (plain HTTP). The port number 30443 is convention only. Access via `http://localhost:30443`. Do not use `https://` -- there is no TLS certificate and browsers will reject the connection.

### General

7. **Port conflicts.** Ports 30080, 30443, and 30880 must be free on the host. If another KinD cluster or service uses these ports, the cluster creation will fail. The `rm-kind` target cleans up, but other clusters from the `local-cluster/` directory may conflict.

8. **kindest/node image availability.** The pinned Kubernetes version (v1.32.11) must have a published `kindest/node` image. Check [github.com/kubernetes-sigs/kind/releases](https://github.com/kubernetes-sigs/kind/releases) if the image pull fails.

---

## 10. Open Questions

1. **Kubernetes version for kindest/node.** The reference implementation uses `v1.34.0`. This document pins `v1.32.11` as a known-good version. Should we match the reference at `v1.34.0` or stay on a more widely tested version? Verify the exact `kindest/node` image tag is published before finalizing.

The Latest kind release is 0.31.0 with kubernetes 1.35

1. **Cilium version.** This document pins `1.19.1` (current stable). At the time of the conference, a newer patch or minor version may be available. Decision: pin to the latest stable at the time of final rehearsal and freeze.

2. **ArgoCD chart version.** This document pins chart `9.4.9` (app `v3.3.3`). Same as Cilium -- pin to latest stable at freeze time. The critical requirement is ArgoCD >= 2.10 for sync impersonation.



3. **Kube-proxy replacement vs. kube-proxy.** The design disables kube-proxy entirely (`kubeProxyMode: none`). This is the recommended Cilium configuration but adds bootstrap complexity. If it proves unreliable during rehearsal, fall back to keeping kube-proxy and setting `kubeProxyReplacement: false` in Cilium values. The demo features do not depend on kube-proxy replacement.

Let's verify or test it ourselves

4. **Hubble UI image tags.** The Hubble UI frontend/backend image tags are omitted from our values file and will use the chart defaults matching Cilium 1.19.1. Verify compatibility by checking the Cilium Helm chart defaults.

5. **ArgoCD NodePort vs. Ingress.** This design uses NodePort for simplicity. An alternative is to deploy an ingress controller (e.g., Cilium's built-in Gateway API support) and use proper hostnames. This adds complexity with no demo benefit. Recommend keeping NodePort unless there is a reason to change.

NodePort is great

6. **Pre-pulling images.** Should the bootstrap script pre-pull Cilium and ArgoCD images into KinD nodes before Helm install to speed up first-time setup? This adds ~30 seconds of scripting but improves reliability. The command would be: `kind load docker-image <image> --name argoconeu26`.

Not necessary to pre-pull

7. **Cilium `ipam.mode`.** The design uses `kubernetes` IPAM mode which delegates IP allocation to Kubernetes. Cilium's default `cluster-pool` mode is also valid. Confirm which mode is more appropriate for KinD and whether it affects any demo scenarios.

Please verify, if kubernetes is the simpler/easier option

---

## Directory Structure

After implementation, the infrastructure files will be organized as:

```
argoconeu26/
  kind-cluster/
    kind-config.yaml              # KinD cluster configuration
  helm-values/
    cilium-values.yaml            # Cilium Helm values
    argocd-values.yaml            # ArgoCD Helm values
  manifests/
    infrastructure/
      hubble-ui-nodeport.yaml     # Hubble UI NodePort service
    stage-0/                      # Prologue state
      applications/
    stage-1a/                     # Scene 1: standard K8s NetworkPolicies
      networkpolicies/
    stage-1b/                     # Scene 1: CiliumNetworkPolicies (L7)
      ciliumnetworkpolicies/
    stage-2/                      # Scene 2: per-tenant Projects + locked default
      projects/
      argocd-config/
      applications/
    stage-3/                      # Scene 3: ApplicationSets
      projects/
      applicationsets/
    stage-4/                      # Scene 4: sync impersonation
      argocd-config/
      projects/
      rbac/
      ciliumnetworkpolicies/
  scripts/
    bootstrap.sh                  # Full bootstrap script
    reset.sh                      # Reset to Stage 0
    demo-magic.sh                 # Copied from reference implementation
  Makefile                        # Top-level Makefile
  design/
    01-infrastructure.md          # This document
    PROMPT.md                     # Design prompt
```
