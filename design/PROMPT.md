# Design Document Request: ArgoCon EU 2026 Demo Environment
# "Network Segmentation at Scale: GitOps-Driven Multi-Tenant Isolation With Argo CD"

## Context

You are designing the demo infrastructure and code for a 25-minute theatrical talk at ArgoCon EU 2026. The talk is a two-character play:

- **The Platform Engineer** (Luke Philips) — overconfident builder who thinks each layer of multi-tenancy is "done" after adding it
- **The Rogue Tenant** (Christian Hernandez, Cisco/Isovalent) — curious breaker who keeps discovering isolation gaps

Every concept is introduced through a **failure then fix** cycle. The audience learns by watching isolation break and get rebuilt.

The full talk script is available at:
`/home/luke/Documents/Vault/OSS/Argo/ArgoConEU26 - Talk Outline Draft.md`

You MUST read this file thoroughly before beginning any design work.

---

## Deliverables

Produce a set of **markdown design documents** to be persisted in this repository:
`/home/luke/projects/github/argo-multiverse-labs/argoconeu26`

The documents should collectively cover everything needed to implement the demo. Organize them as you see fit, but at minimum address the following areas. Each document should be standalone and actionable — someone should be able to pick up any single document and understand what to build without reading the others first.

### 1. Infrastructure Design (KinD Cluster + Cilium)

Design the local KinD cluster configuration that supports the full demo. This cluster must run Cilium as the CNI (replacing the default kindnet) with Hubble enabled for observability.

**Reference implementation** — an existing KinD cluster setup in this organization:
- Config: `/home/luke/projects/github/argo-multiverse-labs/local-cluster/argo-cdviz-flux/kind-cluster/kind/kind-config.yaml`
- Makefile: `/home/luke/projects/github/argo-multiverse-labs/local-cluster/argo-cdviz-flux/kind-cluster/Makefile`

Address:
- KinD cluster configuration (node count, port mappings, disabling default CNI for Cilium)
- Cilium installation method and configuration (Helm chart values, Hubble UI enablement)
- ArgoCD installation via official Helm chart
- Node architecture (control plane vs worker nodes, any labeling strategy)
- Port forwarding strategy for local access (ArgoCD UI, Hubble UI, demo services)
- Prerequisites and tooling (kubectl, helm, kind, cilium CLI, hubble CLI, etc.)

### 2. Application and Tenant Architecture

Design the multi-tenant application topology that the demo operates on. This includes the tenant workloads, shared services, and the ArgoCD configuration that manages them.

Address:
- Tenant namespace layout (at minimum tenant-a, tenant-b, shared-services)
- Tenant workload definitions (simple HTTP services that can curl each other)
- Shared service design (the config API on port 8080 with /admin paths for the L7 demo)
- ArgoCD Application and Project definitions at each stage of the demo
- ApplicationSet design for the scaling scene (Scene 3) — what generator, what template, what git structure

### 3. Network Policy Progression

Design the exact network policies needed at each stage of the talk, showing the progression from zero isolation to full L7-aware multi-tenant segmentation.

Address each stage explicitly:
- **Stage 0 (Prologue):** No policies — flat network, all pods can reach all pods
- **Stage 1a:** Standard Kubernetes NetworkPolicies — default-deny ingress/egress per namespace, explicit allows for legitimate traffic. Must successfully block cross-tenant L3/L4 traffic.
- **Stage 1b:** CiliumNetworkPolicies — L7 HTTP path filtering on the shared service (block `/admin/*` paths while allowing `/api/*`), DNS-aware egress rules using `toFQDNs`
- **Stage 4:** ServiceAccount-scoped CiliumNetworkPolicies for sync impersonation scene

For each stage, specify:
- The exact policy manifests (or their structure)
- What traffic is allowed and what is blocked
- How to validate the policy is working (specific curl commands and expected results)

### 4. ArgoCD Security Progression

Design the ArgoCD configuration at each stage, showing the progression from insecure defaults to properly isolated multi-tenant RBAC.

Address:
- **Stage 0:** Default ArgoCD Project — all tenants share it, no restrictions
- **Stage 2:** Per-tenant ArgoCD Projects with `spec.destinations`, `spec.sourceRepos`, `spec.clusterResourceWhitelist` properly scoped. RBAC roles per tenant.
- **Stage 3:** ApplicationSet configuration for automated tenant onboarding — Projects + CNPs + RBAC provisioned as a unit from a single git commit
- **Stage 4:** Sync impersonation configuration (ArgoCD 2.10+ `argocd-cm` settings, per-Application `spec.syncPolicy.managedNamespaceMetadata` or impersonation config)

Show the before/after for each stage clearly.

### 5. Demo Automation and Scripting

Design the automation that drives the demo. The talk is theatrical — the demo steps must be scripted and reliable.

**Reference implementation** — the demo-magic.sh pattern used in this organization:
`/home/luke/projects/github/argo-multiverse-labs/local-cluster/argo-cdviz-flux/demo-magic.sh`

Address:
- A Makefile for cluster lifecycle (create, bootstrap, teardown, reset-to-stage-N)
- Demo scripts for each scene that use demo-magic.sh (simulated typing, press-enter-to-advance)
- The ability to reset the demo to any stage (for rehearsal and recovery)
- Recording strategy using asciinema or similar (how to record, what terminal size, how to replay)
- A "nuke and rebuild" target that recreates everything from scratch

### 6. Git Commit and PR Strategy

This is a GitOps demo — the git history IS part of the demo. Design the exact sequence of commits/PRs that map to the talk's narrative progression.

Address:
- What files change in each commit/PR
- Branch strategy (single branch with staged commits, or feature branches with PRs per scene)
- How ApplicationSets detect new tenants from git (directory structure, config files)
- Whether the demo repo should be a separate git repo that ArgoCD watches, or this repo itself
- How to reset the git state for re-running the demo

---

## Demo Scenarios That Must Work

The following scenarios are scripted into the talk and MUST be supported by the design. For each, specify the exact commands, expected output, and what the audience sees:

1. **Flat network breach:** `curl` from a pod in tenant-a namespace to a service in tenant-b namespace returns 200 (no policies exist)
2. **L3/L4 block:** Same curl after standard NetworkPolicies are applied returns connection timeout/refused
3. **L7 path bypass:** curl to shared-service:8080/api/config returns 200, but curl to shared-service:8080/admin/tenant-b/config also returns 200 (standard NP only filters L4). After CiliumNP, the /admin path returns 403/dropped.
4. **ArgoCD project breach:** ArgoCD Application in the default Project successfully deploys a resource into tenant-b's namespace (should not be allowed). After per-tenant Projects, this is rejected.
5. **ApplicationSet scaling:** A single git commit (adding a new tenant config file) triggers ArgoCD to generate a full tenant stack — namespace, Project, CNPs, RBAC, workloads.
6. **Hubble visibility:** `hubble observe` or Hubble UI shows allowed and denied flows between tenant namespaces with policy verdicts.
7. **Sync impersonation:** Show the ArgoCD configuration diff (before/after enabling impersonation) and demonstrate that syncs now run scoped to the tenant ServiceAccount.

---

## Technical Constraints

- **Local-only execution:** Everything runs on a KinD cluster on a developer laptop. No cloud resources.
- **Official Helm charts:** Use upstream Helm charts for ArgoCD (`argo/argo-cd`), Cilium (`cilium/cilium`), and any other infrastructure components. Pin specific versions.
- **Cilium as CNI:** KinD must be configured with `disableDefaultCNI: true` and Cilium installed as the CNI. This is a hard requirement — the entire talk depends on CiliumNetworkPolicies.
- **ArgoCD version:** Must support sync impersonation (2.10+). Pin a specific version.
- **Reproducible:** Any engineer should be able to clone the repo, run `make build-all`, and have a working demo environment. Document all prerequisites.
- **Idempotent:** Running the setup twice should not break anything. Running teardown then setup should produce an identical environment.
- **Fast iteration:** Resetting between demo stages should take seconds, not minutes. Design for rehearsal velocity.

---

## Research Directives

You are encouraged to web search and research the following during your design work:

- Current stable versions of Cilium, ArgoCD, and their Helm charts
- Cilium KinD installation requirements (any special kernel modules, mount propagation, etc.)
- ArgoCD sync impersonation documentation and configuration specifics
- CiliumNetworkPolicy L7 HTTP filtering syntax and examples
- Hubble CLI and UI deployment on KinD
- ApplicationSet generator patterns (git directory generator, matrix generator)
- asciinema recording best practices for conference demos
- demo-magic.sh usage patterns

---

## Working Style

- **Ask clarifying questions** rather than making assumptions. If any aspect of the design is ambiguous, under-specified, or has multiple valid approaches, stop and ask.
- **Flag concerns and risks** explicitly. If something might not work on KinD, or a feature requires a specific version, or there is a known gotcha, call it out.
- **Cross-reference the talk script** for every design decision. The demo exists to serve the narrative.
- **Be specific over abstract.** Provide actual file paths, actual manifest structures, actual helm chart values — not "configure Cilium appropriately."

---

## Output Location

All design documents should be written as markdown files in:
`/home/luke/projects/github/argo-multiverse-labs/argoconeu26/`

Use a clear naming convention (e.g., `design/01-infrastructure.md`, `design/02-tenant-architecture.md`, etc.) and include an index document that maps documents to talk scenes.

After the documents are complete and reviewed, we will decide on implementation next steps together.
