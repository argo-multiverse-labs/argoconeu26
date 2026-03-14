#!/usr/bin/env bash
# bootstrap.sh — Bootstraps a KinD + Cilium + ArgoCD demo environment
# for the ArgoCon EU 2026 talk.
#
# Usage: ./scripts/bootstrap.sh
#
# Prerequisites:
#   docker, kind, kubectl, helm, cilium (cilium-cli)
#
# Exit codes:
#   0  success
#   1  missing prerequisite tool or runtime error
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

readonly KIND_CLUSTER_NAME="argoconeu26"
readonly CILIUM_VERSION="1.19.1"
readonly ARGOCD_CHART_VERSION="9.4.9"

# Detect OS for base64 compatibility (GNU vs BSD)
if [[ "$(uname -s)" == "Darwin" ]]; then
  BASE64_DECODE="base64 -D"
else
  BASE64_DECODE="base64 -d"
fi
readonly BASE64_DECODE

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info()  { printf '[INFO]  %s\n' "$*"; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Step 1: Preflight checks
# ---------------------------------------------------------------------------
preflight_checks() {
  log_info "[1/6] Preflight checks..."
  local missing=0
  for cmd in docker kind kubectl helm cilium; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "Required tool not found: ${cmd}"
      missing=1
    fi
  done
  if (( missing )); then
    log_error "Install all missing tools before running this script."
    exit 1
  fi
  log_info "  All required tools found."
}

# ---------------------------------------------------------------------------
# Step 2: Create KinD cluster
# ---------------------------------------------------------------------------
create_kind_cluster() {
  log_info "[2/6] Creating KinD cluster '${KIND_CLUSTER_NAME}'..."
  if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
    log_info "  Cluster already exists. Skipping creation."
  else
    kind create cluster \
      --name "${KIND_CLUSTER_NAME}" \
      --config "${ROOT_DIR}/cluster/kind-config.yaml" \
      --wait 1m \
      --retain
  fi
  kubectl config use-context "kind-${KIND_CLUSTER_NAME}"
  log_info "  Cluster ready."
}

# ---------------------------------------------------------------------------
# Step 3: Install / upgrade Cilium
# ---------------------------------------------------------------------------
install_cilium() {
  log_info "[3/6] Installing Cilium ${CILIUM_VERSION}..."
  helm repo add cilium https://helm.cilium.io 2>/dev/null || true
  helm repo update cilium

  if helm status cilium -n kube-system &>/dev/null; then
    log_info "  Cilium already installed. Upgrading..."
    helm upgrade cilium cilium/cilium \
      --version "${CILIUM_VERSION}" \
      --namespace kube-system \
      --values "${ROOT_DIR}/cluster/cilium-values.yaml" \
      --wait --timeout 5m
  else
    helm install cilium cilium/cilium \
      --version "${CILIUM_VERSION}" \
      --namespace kube-system \
      --values "${ROOT_DIR}/cluster/cilium-values.yaml" \
      --wait --timeout 5m
  fi

  log_info "  Waiting for Cilium to report ready..."
  cilium status --wait --wait-duration 5m
  log_info "  Cilium is ready."
}

# ---------------------------------------------------------------------------
# Step 4: Apply Hubble UI NodePort service
# ---------------------------------------------------------------------------
apply_hubble_nodeport() {
  log_info "[4/6] Applying Hubble UI NodePort service..."
  kubectl apply -f "${ROOT_DIR}/cluster/hubble-ui-nodeport.yaml"
}

# ---------------------------------------------------------------------------
# Step 5: Install / upgrade ArgoCD
# ---------------------------------------------------------------------------
install_argocd() {
  log_info "[5/6] Installing ArgoCD (chart ${ARGOCD_CHART_VERSION})..."
  helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
  helm repo update argo

  if helm status argocd -n argocd &>/dev/null; then
    log_info "  ArgoCD already installed. Upgrading..."
    helm upgrade argocd argo/argo-cd \
      --version "${ARGOCD_CHART_VERSION}" \
      --namespace argocd \
      --values "${ROOT_DIR}/cluster/argocd-values.yaml" \
      --wait --timeout 5m
  else
    helm install argocd argo/argo-cd \
      --version "${ARGOCD_CHART_VERSION}" \
      --namespace argocd \
      --create-namespace \
      --values "${ROOT_DIR}/cluster/argocd-values.yaml" \
      --wait --timeout 5m
  fi

  log_info "  Waiting for ArgoCD pods..."
  kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s
  log_info "  ArgoCD is ready."
}

# ---------------------------------------------------------------------------
# Step 6: Print access information
# ---------------------------------------------------------------------------
print_access_info() {
  log_info "[6/6] Access information:"
  printf '\n'

  local argocd_password
  argocd_password="$(
    kubectl get secret argocd-initial-admin-secret -n argocd \
      -o jsonpath='{.data.password}' | ${BASE64_DECODE}
  )"

  printf '  ArgoCD UI:     http://localhost:30443\n'
  printf '  ArgoCD user:   admin\n'
  printf '  ArgoCD pass:   %s\n' "${argocd_password}"
  printf '\n'
  printf '  Hubble UI:     http://localhost:30080\n'
  printf '\n'
  printf '  Hubble CLI:    cilium hubble port-forward &\n'
  printf '                 hubble observe\n'
  printf '\n'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  printf '============================================\n'
  printf ' ArgoCon EU 2026 Demo — Bootstrap\n'
  printf '============================================\n'

  preflight_checks
  create_kind_cluster
  install_cilium
  apply_hubble_nodeport
  install_argocd
  print_access_info

  printf '============================================\n'
  printf ' Bootstrap complete.\n'
  printf '============================================\n'
}

main "$@"
