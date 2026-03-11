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
pe "kubectl rollout restart statefulset argocd-application-controller -n argocd"
pe "kubectl rollout status statefulset argocd-application-controller -n argocd --timeout=120s"

##############################################################################
# PAYOFF: Identity-aware enforcement
##############################################################################

as_rogue_tenant

p "# Now syncs run as the tenant's ServiceAccount."
p "# The tenant SA CANNOT create CiliumNetworkPolicies (only get/list/watch)."
p "# Even if the AppProject were misconfigured, Kubernetes RBAC stops it."

p "# And SA-scoped CNPs ensure pods running as the wrong ServiceAccount"
p "# get no allowed network paths. For Example:"

pe "yq e .spec ../manifests/stage-4/ciliumnetworkpolicies/shared-services-sa-scoped.yaml"

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
