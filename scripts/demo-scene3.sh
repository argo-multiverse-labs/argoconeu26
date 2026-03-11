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

pe "kubectl exec -n tenant-a curl-client -- curl -s --max-time 5 -o /dev/null -w '%{http_code}\n' http://config-api.shared-services.svc.cluster.local:8080/admin/tenant-b/config"

p "# Hubble (in the other terminal) shows the DROPPED flow with the HTTP path."
p "# Network policy unit tests in production."

p "# The Hubble UI at http://localhost:30080 shows the same data visually"

echo ""
echo -e "\033[1;32mScene 3 complete. Press ENTER to continue to Scene 4.\033[0m"
wait
