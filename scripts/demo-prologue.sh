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
