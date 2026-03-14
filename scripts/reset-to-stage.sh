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
kubectl rollout restart statefulset argocd-application-controller -n argocd
kubectl rollout status statefulset argocd-application-controller -n argocd --timeout=120s

# Remove tenant-c namespace (if it exists)
kubectl delete namespace tenant-c --ignore-not-found 2>/dev/null || true

# ----------------------------------------
# Phase 2: Re-establish base workloads
# ----------------------------------------
echo "[2/3] Re-deploying base workloads..."

kubectl apply -f "${ROOT_DIR}/shared-services/"
kubectl apply -k "${ROOT_DIR}/tenants/tenant-a/"
kubectl apply -k "${ROOT_DIR}/tenants/tenant-b/"

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
