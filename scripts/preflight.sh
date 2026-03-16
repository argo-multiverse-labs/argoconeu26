#!/usr/bin/env bash
set -euo pipefail

PASS=0
FAIL=0
WARN=0

function check_pass() {
    echo -e "  \033[0;32m[PASS]\033[0m $1"
    ((PASS++)) || true
}

function check_fail() {
    echo -e "  \033[0;31m[FAIL]\033[0m $1"
    ((FAIL++)) || true
}

function check_warn() {
    echo -e "  \033[0;33m[WARN]\033[0m $1"
    ((WARN++)) || true
}

echo "============================================"
echo " ArgoCon EU 2026 Demo — Pre-flight Checks"
echo "============================================"
echo ""

# ----------------------------------------
# 1. Required CLI tools
# ----------------------------------------
echo "--- CLI Tools ---"

for cmd in docker kind kubectl helm cilium hubble kubectx pv yq git; do
    if command -v "$cmd" &>/dev/null; then
        VERSION=$($cmd version --short 2>/dev/null || $cmd version --client --short 2>/dev/null || $cmd --version 2>/dev/null | head -1 || echo "installed")
        VERSION=$(echo "$VERSION" | head -1)
        check_pass "$cmd: ${VERSION}"
    else
        check_fail "$cmd: NOT INSTALLED"
    fi
done

# bat/batcat (name varies by distro)
if command -v bat &>/dev/null; then
    check_pass "bat: $(bat --version 2>/dev/null | head -1 || echo 'installed')"
elif command -v batcat &>/dev/null; then
    check_pass "batcat: $(batcat --version 2>/dev/null | head -1 || echo 'installed') (aliased as bat in demo scripts)"
else
    check_fail "bat (or batcat): NOT INSTALLED"
fi

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
if curl -s --max-time 5 http://localhost:30443 &>/dev/null; then
    check_pass "ArgoCD UI accessible at http://localhost:30443"
else
    check_warn "ArgoCD UI not accessible at http://localhost:30443"
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
