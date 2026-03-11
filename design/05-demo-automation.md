# Design Document 05: Demo Automation and Scripting

**Talk:** Network Segmentation at Scale: GitOps-Driven Multi-Tenant Isolation With Argo CD
**Conference:** ArgoCon EU 2026
**Scope:** Makefile design, demo-magic.sh scripts for each scene, stage reset mechanism, recording strategy, pre-flight checks
**Dependencies:** Reads from design docs 01-04 for specific commands, manifests, and validation sequences

---

## Table of Contents

1. [Makefile Design](#1-makefile-design)
2. [Demo Scripts (demo-magic.sh)](#2-demo-scripts)
3. [Stage Reset Mechanism](#3-stage-reset-mechanism)
4. [Recording Strategy](#4-recording-strategy)
5. [Pre-flight Checks](#5-pre-flight-checks)
6. [Directory Layout](#6-directory-layout)
7. [Open Questions](#7-open-questions)

---

## 1. Makefile Design

The top-level Makefile follows the pattern established in `local-cluster/argo-cdviz-flux/kind-cluster/Makefile`. It provides cluster lifecycle targets, per-component install targets, demo stage management, and information display.

### File: `Makefile`
<!-- STATUS: REVIEWED -->

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

################################################################################
# Help                                                                         #
################################################################################

.PHONY: help
help: ## This help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
.DEFAULT_GOAL := help

################################################################################
# Preflight                                                                    #
################################################################################

HAS_DOCKER   := $(shell command -v docker;)
HAS_KUBECTL  := $(shell command -v kubectl;)
HAS_KUBECTX  := $(shell command -v kubectx;)
HAS_HELM     := $(shell command -v helm;)
HAS_KIND     := $(shell command -v kind;)
HAS_CILIUM   := $(shell command -v cilium;)
HAS_HUBBLE   := $(shell command -v hubble;)
HAS_PV       := $(shell command -v pv;)
HAS_ARGOCD   := $(shell command -v argocd;)

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
ifndef HAS_KUBECTX
	$(error You must install kubectx)
endif
ifndef HAS_KIND
	$(error You must install kind)
endif
ifndef HAS_CILIUM
	$(error You must install cilium CLI)
endif
ifndef HAS_HUBBLE
	$(error You must install hubble CLI)
endif
ifndef HAS_PV
	$(error You must install pv (pipe viewer) for demo-magic.sh)
endif

################################################################################
# Cluster Lifecycle                                                            #
################################################################################

.PHONY: kind-cluster
kind-cluster: vendor ## Create the KinD cluster (disableDefaultCNI, kubeProxyMode: none)
	@if kind get clusters 2>/dev/null | grep -q "^$(KIND_CLUSTER_NAME)$$"; then \
		echo "Cluster $(KIND_CLUSTER_NAME) already exists."; \
	else \
		kind create cluster --name $(KIND_CLUSTER_NAME) --wait 1m \
			--config cluster/kind-config.yaml --retain; \
	fi
	kubectx kind-$(KIND_CLUSTER_NAME)

.PHONY: rm-kind
rm-kind: kill-pf ## Delete the KinD cluster entirely
	kind delete cluster --name $(KIND_CLUSTER_NAME)

################################################################################
# Infrastructure Components                                                    #
################################################################################

.PHONY: cilium-install
cilium-install: vendor ## Install Cilium CNI + Hubble
	kubectx kind-$(KIND_CLUSTER_NAME)
	helm repo add cilium https://helm.cilium.io || true
	helm repo update cilium
	helm upgrade --install cilium cilium/cilium \
		--version $(CILIUM_VERSION) \
		--namespace kube-system \
		--values cluster/cilium-values.yaml \
		--wait --timeout 5m
	cilium status --wait --wait-duration 5m
	kubectl apply -f cluster/hubble-ui-nodeport.yaml

.PHONY: argocd-install
argocd-install: vendor ## Install ArgoCD via Helm
	kubectx kind-$(KIND_CLUSTER_NAME)
	helm repo add argo https://argoproj.github.io/argo-helm || true
	helm repo update argo
	helm upgrade --install argocd argo/argo-cd \
		--version $(ARGOCD_CHART_VERSION) \
		--namespace argocd --create-namespace \
		--values cluster/argocd-values.yaml \
		--wait --timeout 5m
	kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

.PHONY: deploy-workloads
deploy-workloads: vendor ## Deploy tenant namespaces, workloads, and shared-services (Stage 0)
	kubectx kind-$(KIND_CLUSTER_NAME)
	kubectl apply -f manifests/stage-0/namespaces/
	kubectl apply -f shared-services/config-api/
	kubectl apply -f tenants/tenant-a/workloads/
	kubectl apply -f tenants/tenant-b/workloads/
	kubectl wait --for=condition=Ready pods --all -n tenant-a --timeout=120s
	kubectl wait --for=condition=Ready pods --all -n tenant-b --timeout=120s
	kubectl wait --for=condition=Ready pods --all -n shared-services --timeout=120s

.PHONY: deploy-stage0-apps
deploy-stage0-apps: vendor ## Deploy ArgoCD Applications in default project (Stage 0)
	kubectx kind-$(KIND_CLUSTER_NAME)
	kubectl apply -f manifests/stage-0/applications/

################################################################################
# Full Lifecycle                                                               #
################################################################################

.PHONY: build-all
build-all: kind-cluster cilium-install argocd-install deploy-workloads deploy-stage0-apps info ## Full build: cluster + Cilium + ArgoCD + workloads + Stage 0

.PHONY: rebuild
rebuild: rm-kind build-all ## Nuke and rebuild everything from scratch

.PHONY: teardown
teardown: rm-kind ## Alias for rm-kind (complete cleanup)

################################################################################
# Demo Stage Management                                                        #
################################################################################

.PHONY: reset-demo
reset-demo: vendor ## Reset demo to Stage 0 (Prologue) -- keeps infrastructure
	kubectx kind-$(KIND_CLUSTER_NAME)
	@echo "Cleaning demo state..."
	-kubectl delete applicationsets --all -n argocd 2>/dev/null
	-kubectl delete applications.argoproj.io --all -n argocd 2>/dev/null
	-kubectl get appprojects -n argocd -o name | grep -v 'default' | \
		xargs -r kubectl delete -n argocd 2>/dev/null
	-kubectl delete ciliumnetworkpolicy --all -n tenant-a 2>/dev/null
	-kubectl delete ciliumnetworkpolicy --all -n tenant-b 2>/dev/null
	-kubectl delete ciliumnetworkpolicy --all -n shared-services 2>/dev/null
	-kubectl delete networkpolicy --all -n tenant-a 2>/dev/null
	-kubectl delete networkpolicy --all -n tenant-b 2>/dev/null
	-kubectl delete networkpolicy --all -n shared-services 2>/dev/null
	-kubectl delete namespace tenant-c --ignore-not-found 2>/dev/null
	-kubectl delete pod -n tenant-a rogue-pod --ignore-not-found 2>/dev/null
	-kubectl delete deployment -n tenant-b rogue-implant --ignore-not-found 2>/dev/null
	-kubectl delete clusterrolebinding rogue-tenant-escalation --ignore-not-found 2>/dev/null
	-kubectl delete clusterrole argocd-application-controller-impersonate --ignore-not-found 2>/dev/null
	-kubectl delete clusterrolebinding argocd-application-controller-impersonate --ignore-not-found 2>/dev/null
	@echo "Reverting ArgoCD ConfigMap (remove impersonation settings)..."
	-kubectl delete configmap argocd-cm -n argocd --ignore-not-found 2>/dev/null
	kubectl rollout restart deployment argocd-application-controller -n argocd
	kubectl rollout status deployment argocd-application-controller -n argocd --timeout=120s
	@echo "Re-deploying workloads..."
	kubectl apply -f manifests/stage-0/namespaces/
	kubectl apply -f shared-services/config-api/
	kubectl apply -f tenants/tenant-a/workloads/
	kubectl apply -f tenants/tenant-b/workloads/
	kubectl wait --for=condition=Ready pods --all -n tenant-a --timeout=120s
	kubectl wait --for=condition=Ready pods --all -n tenant-b --timeout=120s
	kubectl wait --for=condition=Ready pods --all -n shared-services --timeout=120s
	@echo "Restoring default ArgoCD project (wide-open)..."
	kubectl apply -f manifests/stage-0/projects/default-project.yaml
	@echo "Re-deploying Stage 0 ArgoCD Applications..."
	kubectl apply -f manifests/stage-0/applications/
	@echo ""
	@echo "Demo reset to Stage 0 (Prologue). Infrastructure intact."

.PHONY: reset-to-prologue
reset-to-prologue: reset-demo ## Alias: reset to Prologue (Stage 0)

.PHONY: reset-to-scene-1a
reset-to-scene-1a: reset-demo ## Reset to Scene 1a: standard Kubernetes NetworkPolicies applied
	@echo "Applying Stage 1a NetworkPolicies..."
	kubectl apply -f manifests/stage-1a/networkpolicies/
	@echo "Reset to Scene 1a complete."

.PHONY: reset-to-scene-1b
reset-to-scene-1b: reset-to-scene-1a ## Reset to Scene 1b: CiliumNetworkPolicies (L7 + DNS)
	@echo "Applying Stage 1b CiliumNetworkPolicies..."
	kubectl delete networkpolicy -n shared-services --all 2>/dev/null || true
	kubectl apply -f manifests/stage-1b/ciliumnetworkpolicies/
	@echo "Reset to Scene 1b complete."

.PHONY: reset-to-scene-2
reset-to-scene-2: reset-to-scene-1b ## Reset to Scene 2: per-tenant ArgoCD Projects + RBAC
	@echo "Applying Stage 2 ArgoCD Projects and RBAC..."
	-kubectl delete applications.argoproj.io --all -n argocd 2>/dev/null
	kubectl apply -f manifests/stage-2/projects/tenant-a-project.yaml
	kubectl apply -f manifests/stage-2/projects/tenant-b-project.yaml
	kubectl apply -f manifests/stage-2/projects/default-project-locked.yaml
	kubectl apply -f manifests/stage-2/applications/
	kubectl apply -f manifests/stage-2/argocd-config/argocd-rbac-cm.yaml
	@echo "Reset to Scene 2 complete."

.PHONY: reset-to-scene-3
reset-to-scene-3: reset-to-scene-2 ## Reset to Scene 3: ApplicationSets + Hubble
	@echo "Applying Stage 3 ApplicationSets..."
	-kubectl delete applications.argoproj.io --all -n argocd 2>/dev/null
	kubectl apply -f manifests/stage-3/projects/platform-admin-project.yaml
	kubectl apply -f manifests/stage-3/applicationsets/tenant-onboarding.yaml
	@echo "Waiting for ApplicationSet to generate Applications..."
	@until kubectl get application -n argocd tenant-stack-tenant-a 2>/dev/null; do sleep 2; done
	@echo "Reset to Scene 3 complete."

.PHONY: reset-to-scene-4
reset-to-scene-4: reset-to-scene-3 ## Reset to Scene 4: sync impersonation
	@echo "Applying Stage 4 sync impersonation..."
	kubectl apply -f manifests/stage-4/argocd-config/argocd-cm.yaml
	kubectl apply -f manifests/stage-4/rbac/impersonation-clusterrole.yaml
	kubectl apply -f manifests/stage-4/projects/
	kubectl apply -f manifests/stage-4/ciliumnetworkpolicies/
	@echo "Restarting ArgoCD application-controller to pick up impersonation setting..."
	kubectl rollout restart deployment argocd-application-controller -n argocd
	kubectl rollout status deployment argocd-application-controller -n argocd --timeout=120s
	@echo "Reset to Scene 4 complete."

################################################################################
# Access and Information                                                       #
################################################################################

.PHONY: info
info: ## Print all access URLs, credentials, and cluster status
	@echo "============================================"
	@echo " ArgoCon EU 2026 Demo — Status"
	@echo "============================================"
	@echo ""
	@echo "--- Cluster ---"
	@kubectl get nodes -o wide 2>/dev/null || echo "  Cluster not running"
	@echo ""
	@echo "--- ArgoCD ---"
	@echo "  UI:       https://localhost:30443"
	@echo "  User:     admin"
	@printf "  Password: "; kubectl get secret argocd-initial-admin-secret -n argocd \
		-o jsonpath='{.data.password}' 2>/dev/null | $(BASE64_DECODE); echo
	@echo ""
	@echo "--- Hubble ---"
	@echo "  UI:       http://localhost:30080"
	@echo "  CLI:      make hubble-pf && hubble observe"
	@echo ""
	@echo "--- Shared Config API ---"
	@echo "  URL:      http://localhost:30880"
	@echo ""
	@echo "--- Demo State ---"
	@echo "  Namespaces:"
	@kubectl get ns tenant-a tenant-b tenant-c shared-services 2>/dev/null | tail -n +2 || echo "    (not deployed)"
	@echo "  NetworkPolicies:"
	@kubectl get networkpolicy --all-namespaces 2>/dev/null | tail -n +2 || echo "    (none)"
	@echo "  CiliumNetworkPolicies:"
	@kubectl get ciliumnetworkpolicy --all-namespaces 2>/dev/null | tail -n +2 || echo "    (none)"
	@echo "  ArgoCD Projects:"
	@kubectl get appprojects -n argocd 2>/dev/null | tail -n +2 || echo "    (none)"
	@echo "  ArgoCD Applications:"
	@kubectl get applications.argoproj.io -n argocd 2>/dev/null | tail -n +2 || echo "    (none)"
	@echo "  ArgoCD ApplicationSets:"
	@kubectl get applicationsets -n argocd 2>/dev/null | tail -n +2 || echo "    (none)"
	@echo ""
	@echo "============================================"

.PHONY: argocd-password
argocd-password: ## Print the ArgoCD admin password
	@kubectl get secret argocd-initial-admin-secret -n argocd \
		-o jsonpath='{.data.password}' | $(BASE64_DECODE) && echo

.PHONY: hubble-pf
hubble-pf: ## Port-forward Hubble Relay for hubble CLI
	cilium hubble port-forward &

.PHONY: kill-pf
kill-pf: ## Kill all kubectl port-forward and cilium hubble port-forward processes
	@pids=$$(ps aux | grep -E "kubectl port-forward|cilium hubble" | grep -v grep | awk '{print $$2}'); \
	if [ -z "$$pids" ]; then \
		echo "No port-forward processes found."; \
	else \
		echo "Killing: $$pids"; \
		echo $$pids | xargs kill -9; \
	fi

################################################################################
# Demo Scripts                                                                 #
################################################################################

.PHONY: demo-prologue
demo-prologue: ## Run the Prologue demo script
	cd scripts && bash demo-prologue.sh

.PHONY: demo-scene1
demo-scene1: ## Run Scene 1 (network isolation) demo script
	cd scripts && bash demo-scene1.sh

.PHONY: demo-scene2
demo-scene2: ## Run Scene 2 (ArgoCD Projects + RBAC) demo script
	cd scripts && bash demo-scene2.sh

.PHONY: demo-scene3
demo-scene3: ## Run Scene 3 (ApplicationSets + Hubble) demo script
	cd scripts && bash demo-scene3.sh

.PHONY: demo-scene4
demo-scene4: ## Run Scene 4 (sync impersonation) demo script
	cd scripts && bash demo-scene4.sh

.PHONY: demo-full
demo-full: ## Run all demo scripts in sequence (full talk)
	cd scripts && bash demo-prologue.sh && \
		bash demo-scene1.sh && \
		bash demo-scene2.sh && \
		bash demo-scene3.sh && \
		bash demo-scene4.sh

################################################################################
# Recording                                                                    #
################################################################################

.PHONY: record-prologue
record-prologue: ## Record Prologue with asciinema
	asciinema rec -c "cd scripts && bash demo-prologue.sh" \
		--cols 120 --rows 35 --title "ArgoCon EU 2026 - Prologue" \
		recordings/prologue.cast

.PHONY: record-scene1
record-scene1: ## Record Scene 1 with asciinema
	asciinema rec -c "cd scripts && bash demo-scene1.sh" \
		--cols 120 --rows 35 --title "ArgoCon EU 2026 - Scene 1: Network Isolation" \
		recordings/scene1.cast

.PHONY: record-scene2
record-scene2: ## Record Scene 2 with asciinema
	asciinema rec -c "cd scripts && bash demo-scene2.sh" \
		--cols 120 --rows 35 --title "ArgoCon EU 2026 - Scene 2: ArgoCD Projects" \
		recordings/scene2.cast

.PHONY: record-scene3
record-scene3: ## Record Scene 3 with asciinema
	asciinema rec -c "cd scripts && bash demo-scene3.sh" \
		--cols 120 --rows 35 --title "ArgoCon EU 2026 - Scene 3: Scaling" \
		recordings/scene3.cast

.PHONY: record-scene4
record-scene4: ## Record Scene 4 with asciinema
	asciinema rec -c "cd scripts && bash demo-scene4.sh" \
		--cols 120 --rows 35 --title "ArgoCon EU 2026 - Scene 4: Sync Impersonation" \
		recordings/scene4.cast

.PHONY: record-all
record-all: record-prologue record-scene1 record-scene2 record-scene3 record-scene4 ## Record all scenes

################################################################################
# Pre-flight                                                                   #
################################################################################

.PHONY: preflight
preflight: vendor ## Run full pre-flight validation of demo environment
	@bash scripts/preflight.sh
```

### Key Design Decisions

**Target naming follows the reference Makefile.** `build-all`, `rm-kind`, `vendor`, `help` all mirror the `argo-cdviz-flux` Makefile. New targets (`reset-demo`, `reset-to-scene-N`, `info`, `preflight`, `demo-*`, `record-*`) extend the pattern for the theatrical demo format.

**`reset-to-scene-N` targets chain incrementally.** `reset-to-scene-1b` depends on `reset-to-scene-1a` which depends on `reset-demo`. This means each reset target produces a state that includes all prior stages. Running `reset-to-scene-3` executes: clean everything, restore Stage 0, apply Stage 1a NPs, apply Stage 1b CNPs, apply Stage 2 Projects, apply Stage 3 ApplicationSets. This takes approximately 15-30 seconds (no cluster rebuild, only kubectl apply operations).

**Idempotency.** Every target uses `kubectl apply` (not `create`), `--ignore-not-found` for deletes, and `helm upgrade --install` for Helm releases. Running any target twice produces the same result.

**The `-` prefix on cleanup commands.** Lines prefixed with `-` in Makefile recipes allow the command to fail without aborting the target. This is essential for cleanup commands where resources may not exist.

---

## 2. Demo Scripts

Each scene gets its own demo-magic.sh-based script. The scripts use `pe` (print and execute), `p` (print only), and comment lines for narration. Press ENTER to advance between steps.

### 2.1 Common Preamble
<!-- STATUS: REVIEWED -->

All scripts source a shared preamble that sets up demo-magic.sh and common variables:

```bash
# scripts/demo-common.sh
#!/usr/bin/env bash

# Source demo-magic.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/demo-magic.sh"

# Typing speed (characters per second)
TYPE_SPEED=40

# Custom prompt per character role
PLATFORM_PROMPT="\033[1;34m[Platform Engineer]\033[0m $ "
ROGUE_PROMPT="\033[1;31m[Rogue Tenant]\033[0m $ "

# Reset to default
DEFAULT_PROMPT="$ "

# Scene separator
function scene_break() {
    echo ""
    echo -e "\033[1;33m═══════════════════════════════════════════════════════\033[0m"
    echo -e "\033[1;33m  $1\033[0m"
    echo -e "\033[1;33m═══════════════════════════════════════════════════════\033[0m"
    echo ""
    wait
}

# Role switch
function as_platform_engineer() {
    DEMO_PROMPT="$PLATFORM_PROMPT"
}

function as_rogue_tenant() {
    DEMO_PROMPT="$ROGUE_PROMPT"
}

function as_narrator() {
    DEMO_PROMPT="$DEFAULT_PROMPT"
}
```

### 2.2 Prologue Script
<!-- STATUS: REVIEWED -->

```bash
# scripts/demo-prologue.sh
#!/usr/bin/env bash

# Prologue: "The Platform Is Ready" (~2 min)
# Platform Engineer announces the multi-tenant platform is ready.
# Shows the starting state: basic ArgoCD + namespaces. No isolation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/demo-common.sh"

clear

scene_break "PROLOGUE: The Platform Is Ready"

as_platform_engineer

# Show the cluster is running
p "# Welcome to Big Corp's shiny new multi-tenant platform!"
p "# Let's see what we've built..."
pe "kubectl get nodes"

# Show the namespaces
p "# Namespaces for our tenants -- nice and organized"
pe "kubectl get namespaces"

# Show tenant workloads
p "# Tenant A's workloads are running"
pe "kubectl get pods -n tenant-a"

p "# Tenant B's workloads are running"
pe "kubectl get pods -n tenant-b"

# Show ArgoCD Applications
p "# All managed by ArgoCD -- GitOps at its finest"
pe "kubectl get applications -n argocd"

# Show the default project (the problem)
p "# Everything is in the default ArgoCD Project"
pe "kubectl get appprojects -n argocd"

# Show there are NO network policies
p "# And our network? Well..."
pe "kubectl get networkpolicy --all-namespaces"
pe "kubectl get ciliumnetworkpolicy --all-namespaces"

p "# No network policies. Namespaces ARE the isolation."
p "# ...right?"

echo ""
echo -e "\033[1;32mPrologue complete. Press ENTER to continue to Scene 1.\033[0m"
wait
```

### 2.3 Scene 1 Script
<!-- STATUS: REVIEWED -->

```bash
# scripts/demo-scene1.sh
#!/usr/bin/env bash

# Scene 1: "Welcome, Tenants" — The Network Is Wide Open (~6 min)
# Beat 1: Flat network -> standard NetworkPolicies
# Beat 2: L7 gap -> CiliumNetworkPolicies

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/demo-common.sh"

clear

scene_break "SCENE 1: Welcome, Tenants -- The Network Is Wide Open"

##############################################################################
# BEAT 1: Flat Network
##############################################################################

as_rogue_tenant

p "# Nice platform! Let me just check something..."
p "# Can I reach Tenant B's web service from my namespace?"

pe "kubectl exec -n tenant-a curl-client -- curl -s -o /dev/null -w '%{http_code}' http://web.tenant-b.svc.cluster.local"

p "# 200! I can reach another tenant's internal service."
p "# What about the shared config API?"

pe "kubectl exec -n tenant-a curl-client -- curl -s http://config-api.shared-services.svc.cluster.local:8080/api/config"

p "# And the admin endpoint?"

pe "kubectl exec -n tenant-a curl-client -- curl -s http://config-api.shared-services.svc.cluster.local:8080/admin/tenant-b/config"

p "# I can see Tenant B's secrets! Namespaces are NOT isolation."

scene_break "FOURTH WALL BREAK: Kubernetes Namespaces vs Network Isolation"

p "# Kubernetes namespaces are an organizational boundary, not a security boundary."
p "# The default network model is flat -- all pods can reach all other pods."

scene_break "PLATFORM ENGINEER REACTS: Adding Standard NetworkPolicies"

as_platform_engineer

p "# Right. Let me add Kubernetes NetworkPolicies."
p "# Default-deny ingress AND egress for every tenant namespace."

pe "kubectl apply -f ../manifests/stage-1a/networkpolicies/"

p "# Let's verify the policies are in place"
pe "kubectl get networkpolicy --all-namespaces"

##############################################################################
# BEAT 1 PAYOFF: Cross-tenant is blocked
##############################################################################

as_rogue_tenant

p "# Let me try that cross-tenant curl again..."

pe "kubectl exec -n tenant-a curl-client -- curl -s --max-time 5 -o /dev/null -w '%{http_code}' http://web.tenant-b.svc.cluster.local"

p "# Timed out! Cross-tenant traffic is blocked at L3/L4."

p "# But what about the shared config API? I still need that..."

pe "kubectl exec -n tenant-a curl-client -- curl -s -o /dev/null -w '%{http_code}' http://config-api.shared-services.svc.cluster.local:8080/api/config"

p "# Good, the API path works. But wait..."

##############################################################################
# BEAT 2: L7 Gap
##############################################################################

pe "kubectl exec -n tenant-a curl-client -- curl -s -o /dev/null -w '%{http_code}' http://config-api.shared-services.svc.cluster.local:8080/admin/tenant-b/config"

p "# 200! The /admin path is still accessible!"
p "# Standard NetworkPolicies allowed TCP 8080 -- they can't distinguish /api/* from /admin/*"

scene_break "FOURTH WALL BREAK: CiliumNetworkPolicies -- L7 Filtering"

p "# CiliumNetworkPolicies are a SUPERSET of standard NetworkPolicies."
p "# They add: L7 filtering (HTTP paths/methods), DNS-aware policies (toFQDNs),"
p "# and identity-based enforcement via eBPF."

scene_break "PLATFORM ENGINEER: Upgrading to CiliumNetworkPolicies"

as_platform_engineer

p "# Replacing shared-services standard NPs with CiliumNetworkPolicies"
p "# These add L7 HTTP path filtering"

pe "kubectl delete networkpolicy -n shared-services --all"
pe "kubectl apply -f ../manifests/stage-1b/ciliumnetworkpolicies/"

p "# Let's see the CiliumNetworkPolicies"
pe "kubectl get ciliumnetworkpolicy --all-namespaces"

##############################################################################
# BEAT 2 PAYOFF: L7 path is blocked
##############################################################################

as_rogue_tenant

p "# Let me try the API path -- should still work"

pe "kubectl exec -n tenant-a curl-client -- curl -s -o /dev/null -w '%{http_code}' http://config-api.shared-services.svc.cluster.local:8080/api/config"

p "# 200. Good. Now the admin path..."

pe "kubectl exec -n tenant-a curl-client -- curl -s -o /dev/null -w '%{http_code}' http://config-api.shared-services.svc.cluster.local:8080/admin/tenant-b/config"

p "# 403! Cilium's Envoy proxy is blocking the request at the HTTP path level."
p "# The network is finally locked down."

echo ""
echo -e "\033[1;32mScene 1 complete. Press ENTER to continue to Scene 2.\033[0m"
wait
```

### 2.4 Scene 2 Script
<!-- STATUS: REVIEWED -->

```bash
# scripts/demo-scene2.sh
#!/usr/bin/env bash

# Scene 2: "But Who Can Deploy What?" — ArgoCD Projects & RBAC (~6 min)
# The Rogue Tenant pivots from the data plane to the deployment plane.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/demo-common.sh"

clear

scene_break "SCENE 2: But Who Can Deploy What? -- ArgoCD Projects & RBAC"

p "# The network is locked down. But what about the deployment plane?"

as_rogue_tenant

p "# Everything is in the 'default' ArgoCD Project... let me try something"
p "# I'll create an Application that deploys into Tenant B's namespace"

pe "kubectl apply -f ../manifests/stage-0/applications/rogue-app.yaml"

p "# Waiting for the sync..."
pe "until kubectl get pods -n tenant-b -l app=rogue-implant 2>/dev/null | grep -q Running; do sleep 2; done"
pe "kubectl get pods -n tenant-b -l app=rogue-implant"

p "# My rogue workload is running in Tenant B's namespace!"
p "# The default ArgoCD Project has no destination restrictions."

p "# And I can also create ClusterRoleBindings..."
pe "argocd app get rogue-deployment 2>/dev/null || kubectl get application -n argocd rogue-deployment -o jsonpath='{.status.sync.status}'"

scene_break "FOURTH WALL BREAK: ArgoCD Projects as Orchestration Boundaries"

as_platform_engineer

p "# ArgoCD Projects are the orchestration-layer boundary."
p "# They control WHAT can be deployed, WHERE, and BY WHOM."
p "# The spec.destinations field is the most commonly misconfigured field."

scene_break "PLATFORM ENGINEER: Creating Per-Tenant ArgoCD Projects"

p "# Step 1: Create scoped ArgoCD Projects for each tenant"

pe "cat ../manifests/stage-2/projects/tenant-a-project.yaml"
pe "kubectl apply -f ../manifests/stage-2/projects/tenant-a-project.yaml"
pe "kubectl apply -f ../manifests/stage-2/projects/tenant-b-project.yaml"

p "# Step 2: Lock down the default project"

pe "kubectl apply -f ../manifests/stage-2/projects/default-project-locked.yaml"

p "# Step 3: Re-create Applications using per-tenant projects"

pe "kubectl delete application -n argocd rogue-deployment --ignore-not-found"
pe "kubectl apply -f ../manifests/stage-2/applications/"

p "# Step 4: Apply RBAC -- tenants can only see their own project"

pe "kubectl apply -f ../manifests/stage-2/argocd-config/argocd-rbac-cm.yaml"

p "# Let's see the projects now"
pe "kubectl get appprojects -n argocd"

##############################################################################
# PAYOFF: Cross-tenant deployment is blocked
##############################################################################

as_rogue_tenant

p "# Let me try that cross-tenant deployment again..."

pe "kubectl apply -f ../manifests/stage-2/applications/rogue-app-blocked.yaml"

p "# Check the Application status..."
pe "kubectl get application -n argocd rogue-deployment -o jsonpath='{.status.conditions[*].message}' 2>/dev/null; echo"

p "# 'application destination is not permitted in project tenant-a'"
p "# The deployment plane is now locked down too."

pe "kubectl delete application -n argocd rogue-deployment --ignore-not-found"

p "# Two layers of isolation: orchestration (ArgoCD) + network (Cilium)"

echo ""
echo -e "\033[1;32mScene 2 complete. Press ENTER to continue to Scene 3.\033[0m"
wait
```

### 2.5 Scene 3 Script
<!-- STATUS: REVIEWED -->

```bash
# scripts/demo-scene3.sh
#!/usr/bin/env bash

# Scene 3: "One Hundred Tenants by Monday" — Scaling with GitOps (~6 min)
# Beat 1: Policy sprawl + drift -> ApplicationSets
# Beat 2: "But how do you know it's working?" -> Hubble

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/demo-common.sh"

clear

scene_break "SCENE 3: One Hundred Tenants by Monday -- Scaling with GitOps"

##############################################################################
# BEAT 1: Sprawl and Drift
##############################################################################

as_rogue_tenant

p "# You've manually configured Projects and CNPs for 5 tenants. Great."
p "# But Big Corp is onboarding 100 more teams next quarter."
p "# And... have you checked tenant-a's network policies lately?"
p "# Someone kubectl-edited a CiliumNetworkPolicy directly."

as_platform_engineer

p "# ArgoCD's self-heal caught the drift and reverted it!"
p "# But I didn't even notice. And 100 tenants... I can't copy-paste all of this."

scene_break "FOURTH WALL BREAK: ApplicationSets for Automated Onboarding"

p "# ApplicationSets with a git directory generator."
p "# One git commit = one tenant fully onboarded."
p "# Project + CNPs + RBAC + workloads -- all as a single GitOps unit."

p "# Here's the ApplicationSet:"
pe "cat ../manifests/stage-3/applicationsets/tenant-onboarding.yaml"

p "# And here's the git directory structure:"
pe "ls -la ../tenants/"

p "# Let's apply the ApplicationSet"

pe "kubectl apply -f ../manifests/stage-3/projects/platform-admin-project.yaml"
pe "kubectl apply -f ../manifests/stage-3/applicationsets/tenant-onboarding.yaml"

p "# Now let's add a brand new tenant with one git commit"

pe "ls ../tenants/"

p "# Only tenant-a and tenant-b. Let's onboard tenant-c."

pe "cp -r ../staging/tenant-c ../tenants/tenant-c"
pe "cd .. && git add tenants/tenant-c && git commit -m 'onboard tenant-c: full isolation stack in one commit' && git push && cd scripts"

p "# ArgoCD detects the new directory and provisions everything"
p "# Waiting for the ApplicationSet to generate the new Application..."

pe "until kubectl get application -n argocd tenant-stack-tenant-c 2>/dev/null; do sleep 2; done"

p "# Let's check what was created"
pe "kubectl get namespace tenant-c"
pe "kubectl get appprojects -n argocd"
pe "kubectl get ciliumnetworkpolicy -n tenant-c"
pe "kubectl get pods -n tenant-c"

p "# One commit. Full tenant stack. No copy-paste. No drift."

##############################################################################
# BEAT 2: Hubble Validation
##############################################################################

scene_break "BEAT 2: But How Do You Know It's Working?"

as_rogue_tenant

p "# 100 tenants, hundreds of policies."
p "# How do you KNOW traffic is actually being blocked?"

scene_break "FOURTH WALL BREAK: Hubble -- Cilium's Observability Layer"

p "# Hubble gives you real-time network flow visibility."
p "# Which traffic is allowed, which is denied, and why."

p "# Let's watch denied flows while I try some cross-tenant access"

p "# (Run this in a separate terminal window)"
p "hubble observe --namespace shared-services --verdict DROPPED --follow"

p "# Now attempting the blocked /admin path..."

pe "kubectl exec -n tenant-a curl-client -- curl -s --max-time 5 -o /dev/null -w '%{http_code}' http://config-api.shared-services.svc.cluster.local:8080/admin/tenant-b/config"

p "# Hubble (in the other terminal) shows the DROPPED flow with the HTTP path."
p "# Network policy unit tests in production."

p "# The Hubble UI at http://localhost:30080 shows the same data visually"

echo ""
echo -e "\033[1;32mScene 3 complete. Press ENTER to continue to Scene 4.\033[0m"
wait
```

### 2.6 Scene 4 Script
<!-- STATUS: REVIEWED -->

```bash
# scripts/demo-scene4.sh
#!/usr/bin/env bash

# Scene 4: "The Sync Loophole" — Identity-Aware Isolation (~3 min)
# ArgoCD's sync runs with its own SA, not the tenant's.
# Fix: sync impersonation + SA-scoped CNPs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/demo-common.sh"

clear

scene_break "SCENE 4: The Sync Loophole -- Identity-Aware Isolation"

as_rogue_tenant

p "# The deployment plane and network are locked down."
p "# But ArgoCD's sync process runs with its own highly-privileged ServiceAccount."
p "# Not the tenant's ServiceAccount."

p "# If the AppProject accidentally permitted CiliumNetworkPolicy creation..."
p "# the controller's broad permissions would let the sync succeed."
p "# There's no Kubernetes-level enforcement backing up the AppProject."

scene_break "PLATFORM ENGINEER: Enabling Sync Impersonation"

as_platform_engineer

p "# ArgoCD 2.10+ supports sync impersonation."
p "# The controller impersonates the tenant's ServiceAccount during sync."
p "# The tenant SA's RBAC becomes the enforcement boundary."

p "# Step 1: Enable impersonation in argocd-cm"
pe "cat ../manifests/stage-4/argocd-config/argocd-cm.yaml"
pe "kubectl apply -f ../manifests/stage-4/argocd-config/argocd-cm.yaml"

p "# Step 2: Grant the controller permission to impersonate tenant SAs"
pe "kubectl apply -f ../manifests/stage-4/rbac/impersonation-clusterrole.yaml"

p "# Step 3: Add destinationServiceAccounts to tenant Projects"
pe "diff ../manifests/stage-2/projects/tenant-a-project.yaml ../manifests/stage-4/projects/tenant-a-project-with-impersonation.yaml || true"
pe "kubectl apply -f ../manifests/stage-4/projects/"

p "# Step 4: Apply SA-scoped CiliumNetworkPolicies"
pe "kubectl apply -f ../manifests/stage-4/ciliumnetworkpolicies/"

p "# Restart the ArgoCD controller to pick up the new setting"
pe "kubectl rollout restart deployment argocd-application-controller -n argocd"
pe "kubectl rollout status deployment argocd-application-controller -n argocd --timeout=120s"

##############################################################################
# PAYOFF: Identity-aware enforcement
##############################################################################

as_rogue_tenant

p "# Now syncs run as the tenant's ServiceAccount."
p "# The tenant SA CANNOT create CiliumNetworkPolicies (only get/list/watch)."
p "# Even if the AppProject were misconfigured, Kubernetes RBAC stops it."

p "# And SA-scoped CNPs ensure pods running as the wrong ServiceAccount"
p "# get no allowed network paths."

echo ""

scene_break "JOINT RECAP: The Full Architecture"

as_narrator

p "# 1. CiliumNetworkPolicies -- L3-L7 traffic isolation with DNS-aware egress"
p "# 2. ArgoCD Projects -- orchestration boundary (destinations, sourceRepos, clusterResourceWhitelist)"
p "# 3. RBAC -- tenant self-service within boundaries"
p "# 4. ApplicationSets -- automated tenant onboarding at scale"
p "# 5. ArgoCD self-heal -- drift detection; git history as compliance audit trail"
p "# 6. Hubble -- validate isolation in production"
p "# 7. Sync impersonation + SA CNPs -- identity-aware isolation through the GitOps pipeline"

p "# Two layers -- orchestration and network -- managed together through GitOps."

echo ""
echo -e "\033[1;32mDemo complete.\033[0m"
```

### 2.7 Script Design Notes

**Role-based prompts.** Each script switches between `as_platform_engineer` and `as_rogue_tenant` to change the prompt color and label. This gives the audience an immediate visual cue about which character is acting. Blue for the Platform Engineer (builder), red for the Rogue Tenant (breaker).

**Press-ENTER pacing.** Every `pe` and `p` call requires ENTER to advance (default demo-magic.sh behavior). The presenter controls the pace. The `scene_break` function also waits for ENTER, providing a natural pause between narrative beats.

**Commands use relative paths from `scripts/`.** The scripts `cd scripts` and then reference manifests via `../manifests/`. This keeps paths short and readable on screen.

**Comments as narration.** Lines starting with `p "# ..."` display as comments (grey, italicized by demo-magic.sh) and serve as on-screen narration. The audience reads these while the presenter speaks.

**Separate terminal windows.** The Hubble `--follow` command in Scene 3 should run in a separate terminal window rather than as a background process. Background processes (`&`) in demo scripts can produce interleaved output that is hard to read on a projector. Running Hubble in its own terminal also allows the audience to see both streams simultaneously.

---

## 3. Stage Reset Mechanism

### 3.1 What State Needs to Be Reverted

Each stage builds on the prior stages. Resetting to a given stage requires:

| State Category | Revert Method | Time |
|----------------|---------------|------|
| Kubernetes NetworkPolicies | `kubectl delete networkpolicy --all -n <ns>` per namespace | <1s |
| CiliumNetworkPolicies | `kubectl delete ciliumnetworkpolicy --all -n <ns>` per namespace | <1s |
| ArgoCD Applications | `kubectl delete applications.argoproj.io --all -n argocd` | <1s |
| ArgoCD ApplicationSets | `kubectl delete applicationsets --all -n argocd` | <1s |
| ArgoCD AppProjects (non-default) | `kubectl get appprojects ... \| xargs kubectl delete` | <1s |
| Rogue workloads/pods | `kubectl delete deployment/pod` by label | <1s |
| Tenant-c namespace | `kubectl delete namespace tenant-c` | ~5s (waits for finalizers) |
| ClusterRoleBindings (rogue) | `kubectl delete clusterrolebinding` by name | <1s |
| Impersonation ClusterRole/Binding | `kubectl delete clusterrole/clusterrolebinding` by name | <1s |
| ArgoCD ConfigMap patches | `kubectl apply -f` original values | <1s |
| Re-deploy base workloads | `kubectl apply -f` tenant workloads and shared-services | ~3-5s |
| Re-apply stage manifests | `kubectl apply -f` for stages 0 through N | ~2-5s |

**Total reset time: approximately 10-20 seconds for any stage.** The cluster, Cilium, and ArgoCD are never torn down during a reset.

### 3.2 Reset Script
<!-- STATUS: REVIEWED -->

```bash
# scripts/reset-to-stage.sh
#!/usr/bin/env bash
set -euo pipefail

STAGE="${1:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."

echo "============================================"
echo " Resetting demo to Stage: ${STAGE}"
echo "============================================"

# Ensure correct context
kubectx kind-argoconeu26

# ----------------------------------------
# Phase 1: Clean all demo state
# ----------------------------------------
echo "[1/3] Cleaning all demo state..."

# ArgoCD resources
kubectl delete applicationsets --all -n argocd 2>/dev/null || true
kubectl delete applications.argoproj.io --all -n argocd 2>/dev/null || true
kubectl get appprojects -n argocd -o name | grep -v 'default' | \
    xargs -r kubectl delete -n argocd 2>/dev/null || true

# Network policies
for ns in tenant-a tenant-b tenant-c shared-services; do
    kubectl delete ciliumnetworkpolicy --all -n "$ns" 2>/dev/null || true
    kubectl delete networkpolicy --all -n "$ns" 2>/dev/null || true
done

# Rogue resources
kubectl delete pod -n tenant-a rogue-pod --ignore-not-found 2>/dev/null || true
kubectl delete deployment -n tenant-b rogue-implant --ignore-not-found 2>/dev/null || true
kubectl delete clusterrolebinding rogue-tenant-escalation --ignore-not-found 2>/dev/null || true
kubectl delete clusterrole argocd-application-controller-impersonate --ignore-not-found 2>/dev/null || true
kubectl delete clusterrolebinding argocd-application-controller-impersonate --ignore-not-found 2>/dev/null || true

# Remove ArgoCD ConfigMap patches (reverts impersonation settings from Stage 4)
kubectl delete configmap argocd-cm -n argocd --ignore-not-found 2>/dev/null || true
kubectl rollout restart deployment argocd-application-controller -n argocd
kubectl rollout status deployment argocd-application-controller -n argocd --timeout=120s

# Remove tenant-c namespace (if it exists)
kubectl delete namespace tenant-c --ignore-not-found 2>/dev/null || true

# ----------------------------------------
# Phase 2: Re-establish base workloads
# ----------------------------------------
echo "[2/3] Re-deploying base workloads..."

kubectl apply -f "${ROOT_DIR}/manifests/stage-0/namespaces/"
kubectl apply -f "${ROOT_DIR}/shared-services/config-api/"
kubectl apply -f "${ROOT_DIR}/tenants/tenant-a/workloads/"
kubectl apply -f "${ROOT_DIR}/tenants/tenant-b/workloads/"

# Wait for pods to be ready
kubectl wait --for=condition=Ready pods --all -n tenant-a --timeout=120s
kubectl wait --for=condition=Ready pods --all -n tenant-b --timeout=120s
kubectl wait --for=condition=Ready pods --all -n shared-services --timeout=120s

# ----------------------------------------
# Phase 3: Apply state up to the target stage
# ----------------------------------------
echo "[3/3] Applying state for Stage ${STAGE}..."

case "$STAGE" in
    0|prologue)
        # Stage 0: default project (wide-open), no policies
        kubectl apply -f "${ROOT_DIR}/manifests/stage-0/projects/default-project.yaml"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-0/applications/"
        echo "Stage 0 (Prologue): flat network, default ArgoCD project."
        ;;

    1a|scene-1a)
        kubectl apply -f "${ROOT_DIR}/manifests/stage-0/projects/default-project.yaml"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-0/applications/"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-1a/networkpolicies/"
        echo "Stage 1a: standard Kubernetes NetworkPolicies applied."
        ;;

    1b|scene-1b)
        kubectl apply -f "${ROOT_DIR}/manifests/stage-0/projects/default-project.yaml"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-0/applications/"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-1a/networkpolicies/"
        kubectl delete networkpolicy -n shared-services --all 2>/dev/null || true
        kubectl apply -f "${ROOT_DIR}/manifests/stage-1b/ciliumnetworkpolicies/"
        echo "Stage 1b: CiliumNetworkPolicies (L7 + DNS) applied."
        ;;

    2|scene-2)
        # Apply all network policies first
        kubectl apply -f "${ROOT_DIR}/manifests/stage-1a/networkpolicies/"
        kubectl delete networkpolicy -n shared-services --all 2>/dev/null || true
        kubectl apply -f "${ROOT_DIR}/manifests/stage-1b/ciliumnetworkpolicies/"
        # Apply ArgoCD Projects and RBAC
        kubectl apply -f "${ROOT_DIR}/manifests/stage-2/projects/tenant-a-project.yaml"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-2/projects/tenant-b-project.yaml"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-2/projects/default-project-locked.yaml"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-2/applications/"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-2/argocd-config/argocd-rbac-cm.yaml"
        echo "Stage 2: per-tenant ArgoCD Projects + RBAC applied."
        ;;

    3|scene-3)
        # Apply all prior stages
        kubectl apply -f "${ROOT_DIR}/manifests/stage-1a/networkpolicies/"
        kubectl delete networkpolicy -n shared-services --all 2>/dev/null || true
        kubectl apply -f "${ROOT_DIR}/manifests/stage-1b/ciliumnetworkpolicies/"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-2/projects/default-project-locked.yaml"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-2/argocd-config/argocd-rbac-cm.yaml"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-3/projects/platform-admin-project.yaml"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-3/applicationsets/tenant-onboarding.yaml"
        echo "Stage 3: ApplicationSets applied. Waiting for generation..."
        until kubectl get application -n argocd tenant-stack-tenant-a 2>/dev/null; do sleep 2; done
        echo "Stage 3: ApplicationSets + tenant onboarding applied."
        ;;

    4|scene-4)
        # Apply all prior stages
        kubectl apply -f "${ROOT_DIR}/manifests/stage-1a/networkpolicies/"
        kubectl delete networkpolicy -n shared-services --all 2>/dev/null || true
        kubectl apply -f "${ROOT_DIR}/manifests/stage-1b/ciliumnetworkpolicies/"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-2/projects/default-project-locked.yaml"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-2/argocd-config/argocd-rbac-cm.yaml"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-3/projects/platform-admin-project.yaml"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-3/applicationsets/tenant-onboarding.yaml"
        until kubectl get application -n argocd tenant-stack-tenant-a 2>/dev/null; do sleep 2; done
        # Apply Stage 4 impersonation
        kubectl apply -f "${ROOT_DIR}/manifests/stage-4/argocd-config/argocd-cm.yaml"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-4/rbac/impersonation-clusterrole.yaml"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-4/projects/"
        kubectl apply -f "${ROOT_DIR}/manifests/stage-4/ciliumnetworkpolicies/"
        kubectl rollout restart deployment argocd-application-controller -n argocd
        kubectl rollout status deployment argocd-application-controller -n argocd --timeout=120s
        echo "Stage 4: sync impersonation enabled."
        ;;

    *)
        echo "Unknown stage: ${STAGE}"
        echo "Valid stages: 0, prologue, 1a, scene-1a, 1b, scene-1b, 2, scene-2, 3, scene-3, 4, scene-4"
        exit 1
        ;;
esac

echo ""
echo "============================================"
echo " Reset complete. Current state: Stage ${STAGE}"
echo "============================================"
```

### 3.3 Idempotency Guarantees

- **`kubectl apply`** is idempotent by design. Applying the same manifest twice produces no change.
- **`kubectl delete --ignore-not-found`** succeeds even if the resource does not exist.
- **The clean phase deletes ALL demo state before re-applying.** This avoids accumulation of stale resources from prior runs.
- **Running the same reset target twice is safe.** The first run cleans and re-applies; the second run cleans (nothing to clean) and re-applies (already at desired state).

### 3.4 Emergency Recovery

If something goes wrong during a live demo:

```bash
# Fast reset to the PREVIOUS scene (preserves infrastructure)
make reset-to-scene-2    # or whichever scene you need

# Nuclear option: rebuild everything (~5 minutes)
make rebuild
```

The `reset-to-scene-N` targets are the primary recovery mechanism. They are faster than manual recovery and produce a known-good state.

---

## 4. Recording Strategy

### 4.1 Tool Choice: asciinema

**asciinema** is the recommended recording tool. It captures terminal output as a lightweight `.cast` text file (not video), supports playback at variable speed, and integrates with web embedding. The talk outline notes a preference for pre-recorded sessions that "look live but are reliable."

### 4.2 Terminal Configuration

| Setting | Value | Rationale |
|---------|-------|-----------|
| Terminal size | 120 columns x 35 rows | Fits 1080p projection with large font; avoids line wrapping on most commands |
| Font | JetBrains Mono or Fira Code, 18pt | Monospace with ligatures, readable from conference seating |
| Color scheme | Solarized Dark or Dracula | High contrast on projectors; tested with common color blindness |
| Shell prompt | Custom per-character (see demo-common.sh) | Blue for Platform Engineer, red for Rogue Tenant |
| Background | Pure dark (#1e1e1e or similar) | No transparency, no background images; clean for recording |

### 4.3 Recording Workflow

Each scene is recorded independently so scenes can be re-recorded without affecting others.

```bash
# Step 1: Reset to the starting state for the scene
make reset-to-scene-1a     # (to record Scene 1, reset to Stage 1a starting point)
# Or for the Prologue:
make reset-to-prologue

# Step 2: Record the scene
make record-scene1

# The asciinema command used (from Makefile):
# asciinema rec -c "cd scripts && bash demo-scene1.sh" \
#   --cols 120 --rows 35 \
#   --title "ArgoCon EU 2026 - Scene 1: Network Isolation" \
#   recordings/scene1.cast

# Step 3: Review the recording
asciinema play recordings/scene1.cast
# or
asciinema play --speed 2 recordings/scene1.cast  # 2x speed review

# Step 4: If unhappy, re-record (reset first)
make reset-to-prologue
make record-scene1
```

### 4.4 Post-Processing and Editing

**Trimming.** asciinema recordings can be trimmed with `asciinema cut`:

```bash
# Remove the first 5 seconds (setup noise)
asciinema cut --start 5.0 recordings/scene1.cast -o recordings/scene1-trimmed.cast
```

**Speed adjustment.** Replay speed can be controlled during playback or baked in:

```bash
# Compress idle time (pauses > 2 seconds become 2 seconds)
asciinema play --idle-time-limit 2 recordings/scene1.cast
```

**GIF conversion.** For embedding in slides or social media:

```bash
# Using agg (asciinema gif generator)
agg --cols 120 --rows 35 --font-size 18 \
    recordings/scene1.cast recordings/scene1.gif

# Using svg-term for SVG output (sharper than GIF)
svg-term --in recordings/scene1.cast --out recordings/scene1.svg \
    --window --width 120 --height 35
```

### 4.5 Playback Options for the Talk

Three options for how recordings are used during the actual conference talk, in order of preference:

**Option A: Live demo with recording as backup (recommended).**
Run the demo-magic.sh scripts live on stage. If something breaks, switch to the pre-recorded asciinema playback. This preserves the theatrical energy of a live demo while providing a safety net.

```bash
# Live demo (primary)
make demo-scene1

# If something breaks, switch to recording (backup)
asciinema play --idle-time-limit 2 recordings/scene1.cast
```

**Option B: Embedded asciinema player in slides.**
The asciinema web player can be embedded in HTML-based slide decks (reveal.js, Slidev). The presenter clicks through the recording during the talk.

```html
<!-- Embed in reveal.js slide -->
<asciinema-player src="scene1.cast" cols="120" rows="35"
    idle-time-limit="2" speed="1.5" theme="solarized-dark">
</asciinema-player>
```

**Option C: GIF/video in traditional slides.**
Convert recordings to GIF or MP4 for embedding in Google Slides or Keynote. Loses interactivity but works with any slide tool.

### 4.6 Recording Checklist

Before recording each scene:

- [ ] Terminal size is exactly 120x35 (`printf '\e[8;35;120t'` to set)
- [ ] Font size is 18pt
- [ ] Color scheme is set (Solarized Dark or Dracula)
- [ ] Demo state is at the correct starting stage (`make reset-to-scene-N`)
- [ ] Pre-flight checks pass (`make preflight`)
- [ ] No personal information visible in terminal (hostname, paths, etc.)
- [ ] No notifications or popups visible
- [ ] Hubble relay is port-forwarded (if Scene 3)
- [ ] Recording directory exists (`mkdir -p recordings`)

---

## 5. Pre-flight Checks

### 5.1 Pre-flight Script
<!-- STATUS: REVIEWED -->

```bash
# scripts/preflight.sh
#!/usr/bin/env bash
set -euo pipefail

PASS=0
FAIL=0
WARN=0

function check_pass() {
    echo -e "  \033[0;32m[PASS]\033[0m $1"
    ((PASS++))
}

function check_fail() {
    echo -e "  \033[0;31m[FAIL]\033[0m $1"
    ((FAIL++))
}

function check_warn() {
    echo -e "  \033[0;33m[WARN]\033[0m $1"
    ((WARN++))
}

echo "============================================"
echo " ArgoCon EU 2026 Demo — Pre-flight Checks"
echo "============================================"
echo ""

# ----------------------------------------
# 1. Required CLI tools
# ----------------------------------------
echo "--- CLI Tools ---"

for cmd in docker kind kubectl helm cilium hubble kubectx pv; do
    if command -v "$cmd" &>/dev/null; then
        VERSION=$($cmd version --short 2>/dev/null || $cmd version --client --short 2>/dev/null || $cmd --version 2>/dev/null | head -1 || echo "installed")
        check_pass "$cmd: ${VERSION}"
    else
        check_fail "$cmd: NOT INSTALLED"
    fi
done

# Optional tools
for cmd in argocd asciinema agg jq; do
    if command -v "$cmd" &>/dev/null; then
        check_pass "$cmd: installed (optional)"
    else
        check_warn "$cmd: not installed (optional)"
    fi
done

echo ""

# ----------------------------------------
# 2. Cluster status
# ----------------------------------------
echo "--- Cluster ---"

if kind get clusters 2>/dev/null | grep -q "^argoconeu26$"; then
    check_pass "KinD cluster 'argoconeu26' exists"
else
    check_fail "KinD cluster 'argoconeu26' does not exist (run: make build-all)"
fi

if kubectl get nodes &>/dev/null; then
    NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
    if [ "$NODE_COUNT" -eq "$READY_COUNT" ] && [ "$NODE_COUNT" -gt 0 ]; then
        check_pass "All ${NODE_COUNT} nodes are Ready"
    else
        check_fail "${READY_COUNT}/${NODE_COUNT} nodes Ready"
    fi
else
    check_fail "Cannot connect to cluster"
fi

echo ""

# ----------------------------------------
# 3. Cilium status
# ----------------------------------------
echo "--- Cilium ---"

if kubectl get pods -n kube-system -l app.kubernetes.io/part-of=cilium --no-headers 2>/dev/null | grep -q "Running"; then
    check_pass "Cilium agent pods are Running"
else
    check_fail "Cilium agent pods not running"
fi

if cilium status --wait-duration 10s &>/dev/null; then
    check_pass "Cilium reports healthy"
else
    check_fail "Cilium status check failed (run: cilium status)"
fi

# Check Hubble relay
if kubectl get pods -n kube-system -l app.kubernetes.io/name=hubble-relay --no-headers 2>/dev/null | grep -q "Running"; then
    check_pass "Hubble relay is Running"
else
    check_fail "Hubble relay not running"
fi

# Check Hubble UI
if kubectl get pods -n kube-system -l app.kubernetes.io/name=hubble-ui --no-headers 2>/dev/null | grep -q "Running"; then
    check_pass "Hubble UI is Running"
else
    check_warn "Hubble UI not running (not critical, but needed for Scene 3)"
fi

echo ""

# ----------------------------------------
# 4. ArgoCD status
# ----------------------------------------
echo "--- ArgoCD ---"

if kubectl get pods -n argocd --no-headers 2>/dev/null | grep -q "Running"; then
    RUNNING=$(kubectl get pods -n argocd --no-headers 2>/dev/null | grep -c "Running" || true)
    TOTAL=$(kubectl get pods -n argocd --no-headers 2>/dev/null | wc -l)
    if [ "$RUNNING" -eq "$TOTAL" ]; then
        check_pass "All ${TOTAL} ArgoCD pods are Running"
    else
        check_fail "${RUNNING}/${TOTAL} ArgoCD pods Running"
    fi
else
    check_fail "ArgoCD pods not running"
fi

# Check ApplicationSet controller specifically
if kubectl get pods -n argocd -l app.kubernetes.io/component=applicationset-controller --no-headers 2>/dev/null | grep -q "Running"; then
    check_pass "ApplicationSet controller is Running"
else
    check_fail "ApplicationSet controller not running (needed for Scene 3)"
fi

echo ""

# ----------------------------------------
# 5. Service accessibility
# ----------------------------------------
echo "--- Service Access ---"

# ArgoCD UI (NodePort 30443)
if curl -sk --max-time 5 https://localhost:30443 &>/dev/null; then
    check_pass "ArgoCD UI accessible at https://localhost:30443"
else
    check_warn "ArgoCD UI not accessible at https://localhost:30443"
fi

# Hubble UI (NodePort 30080)
if curl -s --max-time 5 http://localhost:30080 &>/dev/null; then
    check_pass "Hubble UI accessible at http://localhost:30080"
else
    check_warn "Hubble UI not accessible at http://localhost:30080"
fi

echo ""

# ----------------------------------------
# 6. Demo workloads
# ----------------------------------------
echo "--- Demo Workloads ---"

for ns in tenant-a tenant-b; do
    if kubectl get pod -n "$ns" curl-client --no-headers 2>/dev/null | grep -q "Running"; then
        check_pass "${ns}/curl-client pod is Running"
    else
        check_warn "${ns}/curl-client pod not running (deploy with: make deploy-workloads)"
    fi
done

if kubectl get pods -n shared-services -l app=config-api --no-headers 2>/dev/null | grep -q "Running"; then
    check_pass "shared-services/config-api is Running"
else
    check_warn "shared-services/config-api not running (deploy with: make deploy-workloads)"
fi

echo ""

# ----------------------------------------
# 7. Connectivity test (basic)
# ----------------------------------------
echo "--- Connectivity ---"

if kubectl get pod -n tenant-a curl-client --no-headers 2>/dev/null | grep -q "Running"; then
    HTTP_CODE=$(kubectl exec -n tenant-a curl-client -- curl -s --max-time 5 -o /dev/null -w "%{http_code}" http://config-api.shared-services.svc.cluster.local:8080/healthz 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        check_pass "tenant-a -> shared-services connectivity OK (HTTP ${HTTP_CODE})"
    else
        check_warn "tenant-a -> shared-services returned HTTP ${HTTP_CODE} (may be expected depending on stage)"
    fi
else
    check_warn "Cannot test connectivity (curl-client not running)"
fi

echo ""

# ----------------------------------------
# Summary
# ----------------------------------------
echo "============================================"
echo -e " Results: \033[0;32m${PASS} passed\033[0m, \033[0;31m${FAIL} failed\033[0m, \033[0;33m${WARN} warnings\033[0m"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Fix the failures above before running the demo."
    exit 1
fi
```

### 5.2 Stage-Specific Validation

The pre-flight script checks the environment is fundamentally healthy. For stage-specific validation (confirming the demo is at the expected stage), use:

```bash
# Quick stage validation
make info
```

The `info` target displays the current state of network policies, ArgoCD projects, applications, and applicationsets. The presenter can visually confirm the state matches the expected stage before starting a scene.

### 5.3 When to Run Pre-flight

- **Before `make build-all`**: only the CLI tools section will pass; everything else will fail. This is expected.
- **After `make build-all`**: everything should pass.
- **Before recording**: run `make preflight` to confirm the environment is healthy.
- **Before going on stage**: run `make preflight` as the final check.
- **After a `reset-to-scene-N`**: run `make info` to confirm the correct stage.

---

## 6. Directory Layout

After implementing the automation described in this document, the `scripts/` and `recordings/` directories will be organized as:

```
argoconeu26/
  Makefile                           # Top-level Makefile (Section 1)
  scripts/
    demo-magic.sh                    # Copied from reference implementation
    demo-common.sh                   # Shared preamble (prompts, scene_break, role switching)
    demo-prologue.sh                 # Prologue script (~2 min)
    demo-scene1.sh                   # Scene 1: network isolation (~6 min)
    demo-scene2.sh                   # Scene 2: ArgoCD Projects + RBAC (~6 min)
    demo-scene3.sh                   # Scene 3: ApplicationSets + Hubble (~6 min)
    demo-scene4.sh                   # Scene 4: sync impersonation (~3 min)
    reset-to-stage.sh                # Reset to any stage (Section 3)
    preflight.sh                     # Pre-flight validation (Section 5)
  recordings/                        # asciinema recordings (git-ignored)
    prologue.cast
    scene1.cast
    scene2.cast
    scene3.cast
    scene4.cast
    .gitkeep
```

The `recordings/` directory should be added to `.gitignore` since `.cast` files are large and machine-specific. Only the `.gitkeep` is committed.

---

## 7. Open Questions

1. **demo-magic.sh: fork or copy?** The reference demo-magic.sh at `local-cluster/argo-cdviz-flux/demo-magic.sh` is a copy of the original by Paxton Hare. Should we copy it into this repo (ensuring it is always available) or add it as a git submodule? Copying is simpler and avoids external dependencies. The reference implementation copies it, so this document recommends the same approach.

Copy here

2. **Custom prompts with demo-magic.sh.** The `DEMO_PROMPT` variable in demo-magic.sh controls the prompt display. The design above changes it dynamically via `as_platform_engineer` and `as_rogue_tenant`. This works because demo-magic.sh reads `DEMO_PROMPT` at each `p`/`pe` call. Verify that the ANSI color codes in the custom prompts render correctly with the `pv` pipe (which demo-magic.sh uses for simulated typing). If `pv` corrupts the color codes, the prompt may need to be moved outside the `pv` pipe.

Let's give this a try

3. **Two terminals or one?** The theatrical format has two characters. Options: (a) a single terminal with role-switching prompts (designed above), (b) two side-by-side terminals (one per character), (c) a tmux split-pane setup. A single terminal is simplest for recording and projection. Two terminals add visual impact but double the recording complexity. Decision should be made during rehearsal.

I am open to whichever works best for us

4. **Hubble observe in Scene 3.** The script runs `hubble observe --follow &` in the background. On KinD, the Hubble relay port-forward must be active before this command works. The script assumes `make hubble-pf` was run before starting Scene 3. If this is unreliable, the script should start the port-forward itself. However, background port-forwards inside a demo-magic script can be messy. An alternative is to run Hubble in a second terminal.

We will try to run make hubble-pf or a second terminal

5. **ArgoCD CLI (`argocd`) usage in scripts.** Some demo commands use the `argocd` CLI (e.g., `argocd app get`). The CLI requires authentication. For the KinD demo, this means either (a) running `argocd login localhost:30443 --username admin --password <pw> --insecure` at the start of the script, (b) using `kubectl` exclusively to inspect ArgoCD resources, or (c) pre-authenticating in the shell before running the demo script. Option (b) is the most reliable since it does not require the `argocd` CLI to be installed. The scripts above primarily use `kubectl` for this reason, but Scene 2 could benefit from `argocd app get` for cleaner output. Decision: use `kubectl` for reliability; `argocd` CLI is listed as optional in pre-flight.

We can try both, if argocd looks better we can keep it, we do not have to be secure, if we see a password in this demo that is ok

6. **Git operations in Scene 3.** The talk script shows adding `tenant-c` via a git commit. In the KinD demo, ArgoCD watches a remote GitHub repo. Options: (a) the tenant-c directory already exists in the repo and the ApplicationSet discovers it when applied, (b) the demo uses a local git server (Gitea) inside KinD so the commit can be made live, (c) the git commit is pre-recorded or simulated. Option (a) is simplest for the demo and is what the scripts above assume. If live git interaction is important for the theatrical impact, option (b) adds significant infrastructure complexity. This should be coordinated with design doc 06 (git commit strategy).

Likely option a - the simplest

7. **Terminal size for two-speaker setup.** The recording strategy recommends 120x35. If both speakers share one screen (split panes), each pane would be 60x35, which is too narrow for kubectl output. If each speaker has their own laptop/screen projected, each can use 120x35 independently. This depends on the AV setup at the conference venue.

Maybe we switch terminal tabs?

8. **asciinema vs alternative recording tools.** asciinema is the standard for terminal recording. Alternatives include VHS (by Charm, produces GIF directly from a script) and terminalizer. VHS has the advantage of being fully scriptable (no human interaction needed during recording), which is excellent for CI/CD but loses the press-ENTER pacing of demo-magic.sh. Recommend sticking with asciinema for interactive recording and using `agg` for GIF conversion.

Good to know, we can keep asciinema for now
