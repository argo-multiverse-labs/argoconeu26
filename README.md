# Network Segmentation at Scale: GitOps-Driven Multi-Tenant Isolation With Argo CD

**ArgoCon EU 2026** | Luke Philips & Christian Hernandez

A demo showing how to build production-grade multi-tenant isolation using ArgoCD and Cilium.

## What This Demonstrates

Progressive multi-tenant isolation across two planes: network (Cilium) and orchestration (ArgoCD), managed together through GitOps. Starting from a flat, wide-open cluster and ending with identity-aware, L7-enforced, fully automated tenant isolation.

## Prerequisites

| Tool | Version | Required |
|------|---------|----------|
| Docker | Recent | Yes |
| [KinD](https://kind.sigs.k8s.io/) | 0.31.0 | Yes |
| kubectl | 1.32+ | Yes |
| Helm | 3.x | Yes |
| [Cilium CLI](https://docs.cilium.io/en/v1.19/gettingstarted/k8s-install-default/#install-the-cilium-cli) | 1.19+ | Yes |
| [Hubble CLI](https://docs.cilium.io/en/v1.19/observability/hubble/setup/#install-the-hubble-client) | Latest | Yes |
| kubectx | Latest | Yes |
| pv (pipe viewer) | Latest | Yes (for demo-magic) |
| argocd CLI | Latest | Optional |
| asciinema | Latest | Optional (recording) |

## Quick Start

```bash
# Build everything: KinD cluster + Cilium 1.19.1 + ArgoCD 3.3.3 + workloads
make build-all

# Validate the environment
make preflight

# See access URLs and credentials
make info
```

## Access

| Service | URL | Notes |
|---------|-----|-------|
| ArgoCD UI | http://localhost:30443 | User: `admin`, password: `make argocd-password` |
| Hubble UI | http://localhost:30080 | Network flow visualization |

## Demo Flow

| Scene | What Happens | Key Concept |
|-------|-------------|-------------|
| **Prologue** | Platform Engineer shows flat network, default project, no policies | Starting state |
| **Scene 1** | Rogue curls across namespaces. K8s NPs block L4, CiliumNPs block L7 HTTP paths | NetworkPolicy vs CiliumNetworkPolicy |
| **Scene 2** | Rogue deploys into wrong namespace. Per-tenant ArgoCD Projects fix it | ArgoCD Projects as orchestration boundaries |
| **Scene 3** | Manual sprawl breaks. ApplicationSet + one git commit = full tenant onboarding | ApplicationSets with git directory generator |
| **Scene 4** | Sync impersonation gap. SA privilege scoping + SA-scoped CNPs | Sync impersonation + identity-aware CNPs |

### Running the Demo

```bash
make reset-demo          # Reset to Prologue (Stage 0)
make demo-prologue       # Run Prologue script
make demo-scene1         # Run Scene 1 script
make demo-scene2         # Run Scene 2 script
make demo-scene3         # Run Scene 3 script
make demo-scene4         # Run Scene 4 script

# Or run the full talk end-to-end
make demo-full
```

### Jumping to a Specific Scene

```bash
make reset-to-scene-1a   # Standard K8s NetworkPolicies applied
make reset-to-scene-1b   # CiliumNetworkPolicies (L7) applied
make reset-to-scene-2    # Per-tenant ArgoCD Projects + RBAC
make reset-to-scene-3    # ApplicationSets
make reset-to-scene-4    # Sync impersonation
```

## Recordings

Pre-recorded demos are in `recordings/` as [asciinema](https://asciinema.org/) `.cast` files.

```bash
# Play a recording in your terminal
asciinema play recordings/scene1.cast

# Convert to GIF (requires agg)
agg recordings/scene1.cast recordings/scene1.gif

# Record all scenes fresh
make record-all

# Upload to asciinema.org for sharing/embedding
asciinema upload recordings/scene1.cast
```

| Recording | Scene |
|-----------|-------|
| `prologue.cast` | Flat network, default project, no policies |
| `scene1.cast` | K8s NetworkPolicies + CiliumNetworkPolicies (L7) |
| `scene2.cast` | Per-tenant ArgoCD Projects + RBAC |
| `scene3.cast` | ApplicationSet tenant onboarding + Hubble |
| `scene4.cast` | Sync impersonation + SA-scoped CNPs |

## Repo Structure

```
cluster/                  # KinD config, Cilium + ArgoCD Helm values, Hubble NodePort
manifests/
  stage-0/                # Prologue: default project, initial apps
  stage-1a/               # Scene 1: standard K8s NetworkPolicies
  stage-1b/               # Scene 1: CiliumNetworkPolicies (L7)
  stage-2/                # Scene 2: per-tenant Projects + locked default + RBAC
  stage-3/                # Scene 3: ApplicationSet + platform-admin project
  stage-4/                # Scene 4: sync impersonation + SA-scoped CNPs
base/
  tenant-template/        # Kustomize base for tenant namespaces, workloads, RBAC, policies
  argocd-project/         # Helm chart for ArgoCD AppProjects
tenants/                  # Tenant overlays (ApplicationSet git directory generator source)
staging/                  # Pre-staged tenant-c for Scene 3 onboarding
shared-services/          # Shared config API (L7 demo target)
demo-apps/                # Rogue workload manifests
scripts/                  # demo-magic.sh scripts, bootstrap, preflight, reset
design/                   # Design documents (see design/00-index.md)
```

## Version Pins

| Component | Version |
|-----------|---------|
| Cilium | 1.19.1 |
| ArgoCD | 3.3.3 (Helm chart 9.4.9) |
| KinD | 0.31.0 (kindest/node:v1.32.11) |
| Workloads | nginx:1.27-alpine, curlimages/curl:8.11.0 |

## References

### ArgoCD
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/en/stable/)
- [ArgoCD Projects](https://argo-cd.readthedocs.io/en/stable/user-guide/projects/)
- [ArgoCD ApplicationSets](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/)
- [Sync Impersonation](https://argo-cd.readthedocs.io/en/stable/operator-manual/sync-options/#impersonate-argocd)

### Cilium
- [Cilium Documentation](https://docs.cilium.io/en/v1.19/)
- [CiliumNetworkPolicy](https://docs.cilium.io/en/v1.19/security/policy/)
- [L7 Policies](https://docs.cilium.io/en/v1.19/security/policy/language/#layer-7-examples)
- [Identity-Based Enforcement](https://docs.cilium.io/en/v1.19/security/identity/)
- [Hubble Observability](https://docs.cilium.io/en/v1.19/observability/hubble/)

### Kubernetes
- [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [KinD](https://kind.sigs.k8s.io/)
- [Kustomize](https://kustomize.io/)

## License

MIT
