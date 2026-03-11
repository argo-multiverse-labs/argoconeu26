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

pe "kubectl exec -n tenant-a curl-client -- curl -s -o /dev/null -w '%{http_code}\n' http://web.tenant-b.svc.cluster.local"

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

pe "kubectl exec -n tenant-a curl-client -- curl -s --max-time 5 -o /dev/null -w '%{http_code}\n' http://web.tenant-b.svc.cluster.local"

p "# Timed out! Cross-tenant traffic is blocked at L3/L4."

p "# But what about the shared config API? I still need that..."

pe "kubectl exec -n tenant-a curl-client -- curl -s -o /dev/null -w '%{http_code}\n' http://config-api.shared-services.svc.cluster.local:8080/api/config"

p "# Good, the API path works. But wait..."

##############################################################################
# BEAT 2: L7 Gap
##############################################################################

pe "kubectl exec -n tenant-a curl-client -- curl -s -o /dev/null -w '%{http_code}\n' http://config-api.shared-services.svc.cluster.local:8080/admin/tenant-b/config"

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

pe "kubectl exec -n tenant-a curl-client -- curl -s -o /dev/null -w '%{http_code}\n' http://config-api.shared-services.svc.cluster.local:8080/api/config"

p "# 200. Good. Now the admin path..."

pe "kubectl exec -n tenant-a curl-client -- curl -s -o /dev/null -w '%{http_code}\n' http://config-api.shared-services.svc.cluster.local:8080/admin/tenant-b/config"

p "# 403! Cilium's Envoy proxy is blocking the request at the HTTP path level."
p "# The network is finally locked down."

echo ""
echo -e "\033[1;32mScene 1 complete. Press ENTER to continue to Scene 2.\033[0m"
wait
