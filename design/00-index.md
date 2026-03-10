# Design Document Index

**Project:** ArgoCon EU 2026 — "Network Segmentation at Scale: GitOps-Driven Multi-Tenant Isolation With Argo CD"

**Generated:** 2026-03-09

**Source prompt:** [PROMPT.md](./PROMPT.md)

---

## Documents

| Doc | Title | Scope |
|-----|-------|-------|
| [01](./01-infrastructure.md) | Infrastructure (KinD + Cilium + ArgoCD) | Cluster config, Helm values, bootstrap sequence, Makefile |
| [02](./02-tenant-architecture.md) | Application and Tenant Architecture | Namespaces, workloads, shared config API, ApplicationSet, repo structure |
| [03](./03-network-policies.md) | Network Policy Progression | Stage-by-stage policies: none → K8s NP → CiliumNP → SA-scoped CNP |
| [04](./04-argocd-security.md) | ArgoCD Security Progression | Default project → per-tenant Projects → ApplicationSets → sync impersonation |
| [05](./05-demo-automation.md) | Demo Automation and Scripting | Makefile, demo-magic.sh scripts, stage resets, asciinema, pre-flight checks |
| [06](./06-git-strategy.md) | Git Commit and PR Strategy | Single-repo decision, branch strategy, Scene 3 git moment, reset mechanism |

---

## Document → Talk Scene Map

| Talk Scene | Primary Docs | What Happens |
|-----------|-------------|-------------|
| **Prologue** (~2 min) | 01, 02, 03 (Stage 0) | Platform Engineer shows basic setup. Flat network, default ArgoCD project, no policies. |
| **Scene 1** (~6 min) | 03 (Stages 1a, 1b), 02 | Rogue Tenant curls across namespaces. Standard NP blocks L4 but not L7. CiliumNP blocks HTTP paths. |
| **Scene 2** (~6 min) | 04 (Stages 0→2) | Rogue Tenant deploys into wrong namespace via default project. Per-tenant Projects + RBAC fix it. |
| **Scene 3** (~6 min) | 04 (Stage 3), 06, 02 | Manual sprawl breaks. ApplicationSet + one git commit = full tenant onboarding. Hubble validates. |
| **Scene 4** (~3 min) | 04 (Stage 4), 03 (Stage 4) | Sync impersonation gap. ArgoCD SA privilege scoping + SA-scoped CNPs. |
| **Recap** (~3 min) | All | Joint walkthrough of the full architecture stack. |

---

## Key Design Decisions

| Decision | Choice | Rationale | Doc |
|----------|--------|-----------|-----|
| Repository architecture | Single repo | 25-min constraint, simplicity, ApplicationSet path scoping | 06 |
| Branch strategy | Single branch (`main`) + tags | Most stage transitions are kubectl-driven, only Scene 3 needs live git | 06 |
| Tenant workloads | nginx:1.27-alpine + curl pods | No custom image builds, lightweight, stock images | 02 |
| Shared config API | nginx + ConfigMap location blocks | Zero build step, location blocks map directly to CiliumNP rules | 02 |
| Cilium L7 model | Allowlist-only (403 on deny) | Stronger demo moment than silent drop — audience sees explicit rejection | 03 |
| Demo reset | Forward commits only (no force push) | Safe, idempotent, no history rewriting | 06 |
| Scene 3 git moment | Pre-staged files in `staging/`, copy → commit → push | Reliable, no live editing risk | 06 |
| Recording | asciinema per-scene, 120x35 terminal | Independent recording, GIF conversion via `agg` for slides | 05 |

---

## Canonical Directory Layout

All stage manifests live under `manifests/stage-N/`. Each stage directory is self-contained. This is the single source of truth for paths referenced across all design documents.

```
manifests/
  stage-0/              # Prologue: flat network, default project
    applications/
  stage-1a/             # Scene 1: standard K8s NetworkPolicies
    networkpolicies/
  stage-1b/             # Scene 1: CiliumNetworkPolicies (L7)
    ciliumnetworkpolicies/
  stage-2/              # Scene 2: per-tenant Projects + locked default
    projects/
    argocd-config/
    applications/
  stage-3/              # Scene 3: ApplicationSet
    projects/
    applicationsets/
  stage-4/              # Scene 4: sync impersonation
    argocd-config/
    projects/
    rbac/
    ciliumnetworkpolicies/
tenants/                # ApplicationSet git directory generator source
  tenant-a/
  tenant-b/
staging/                # Pre-staged tenant-c for Scene 3 (committed)
  tenant-c/
scripts/                # Demo automation
```

**Key principle:** No `argocd/` top-level directory. No loose `stage-N/` directories at the repo root. Everything ArgoCD-related that is applied via `kubectl apply` during the demo lives under `manifests/stage-N/`.

---

## Consolidated Open Questions

Items flagged across all docs that need resolution before implementation.

### Infrastructure (Doc 01)
- ~~Version pins need verification~~ **RESOLVED:** Cilium 1.19.1, ArgoCD 3.3.3 (chart 9.4.9), KinD 0.31.0 with kindest/node:v1.32.11
- Docker resource requirements for running Cilium + ArgoCD + Hubble on a laptop
- Port conflict strategy if 30443/30080/30880 are in use

### Tenant Architecture (Doc 02)
- How Cilium L7 enforcement surfaces to curl client (TCP RST vs drop vs 403 injection)
- Whether to use one or two ApplicationSets for stage clarity
- Whether tenant Projects should include `shared-services` as a destination

### Network Policies (Doc 03)
- Cilium Envoy proxy availability on KinD (most likely L7 failure point)
- SA-scoped CNPs require RBAC to prevent cross-tenant SA name squatting
- Scene 4 framing: API-level vs identity-level (recommend API-level for demo clarity)
- `toFQDNs` DNS intercept rule coupling

### ArgoCD Security (Doc 04)
- Sync impersonation exact config syntax (verify against pinned ArgoCD version)
- `destinationServiceAccounts` availability in AppProject spec
- API-caller identity vs pod runtime identity distinction for Scene 4

### Demo Automation (Doc 05)
- Two-terminal setup for two-speaker format
- ~~Git operations in Scene 3 (integrated into demo script or separate?)~~ **RESOLVED:** Integrated into demo script. Use `cp -r staging/tenant-c tenants/tenant-c && git add && git commit && git push`.
- ~~`argocd` CLI vs `kubectl` for ArgoCD operations~~ **RESOLVED:** Use `kubectl` for reliability. `argocd` CLI is optional.
- Terminal sizing for two-speaker theatrical format

### Git Strategy (Doc 06)
- ~~ArgoCD repo access from KinD (local git server? Gitea? GitHub?)~~ **RESOLVED:** Use GitHub. Assume internet works.
- ~~Poll interval tuning for Scene 3 (vs manual `argocd app refresh`)~~ **RESOLVED:** Reduce poll interval to 30s via `argocd-cm`.
- ~~Rehearsal branch strategy to avoid reset-commit pollution~~ **RESOLVED:** Stay on `main`. Accept reset commits.
- Exact ApplicationSet refresh command
- ~~`preserveResourcesOnDeletion` setting~~ **RESOLVED:** Use default `false`.

### Cross-Cutting (Discuss with Christian)
- Scene 4 framing: API-level vs identity-level sync impersonation — Christian's input needed
- Character names: real names or personas?
- How theatrical: costumes/props or lighter touch?
- Running gags for each character

---

## Reading Order

**For implementation:** 01 → 02 → 03 → 04 → 06 → 05 (infrastructure first, automation last)

**For understanding the demo narrative:** Talk Outline → 00 (this index) → 03 + 04 side-by-side → 05

**For a quick overview:** This index → skim each doc's Stage/Section headings
