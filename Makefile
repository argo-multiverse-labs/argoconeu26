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
	kubectl wait --for=condition=Ready pods -l app.kubernetes.io/part-of=argocd --field-selector=status.phase=Running -n argocd --timeout=300s

.PHONY: deploy-workloads
deploy-workloads: vendor ## Deploy tenant namespaces, workloads, and shared-services (Stage 0)
	kubectx kind-$(KIND_CLUSTER_NAME)
	kubectl apply -k shared-services/
	kubectl apply -k tenants/tenant-a/
	kubectl apply -k tenants/tenant-b/
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
	kubectl apply -k shared-services/
	kubectl apply -k tenants/tenant-a/
	kubectl apply -k tenants/tenant-b/
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
