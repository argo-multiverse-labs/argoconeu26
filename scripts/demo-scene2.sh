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

pe "kubectl apply -f ../manifests/stage-2/applications/rogue-app.yaml"

p "# Waiting for the sync..."
kubectl wait --for=condition=Ready -n tenant-b -l app=rogue-implant pod --timeout=60s 2>/dev/null || sleep 3
pe "kubectl get pods -n tenant-b -l app=rogue-implant"

p "# My rogue workload is running in Tenant B's namespace!"
p "# The default ArgoCD Project has no destination restrictions."

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
pe "kubectl apply -f ../manifests/stage-2/projects/shared-services-project.yaml"

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
