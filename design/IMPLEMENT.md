# Multi-Agent Implementation Orchestrator — ArgoCon EU 2026 Demo

You are implementing a KinD + Cilium + ArgoCD conference demo from six design documents.
This prompt is self-contained. Do not read CLAUDE.md or design/00-index.md for context — everything you need is here.

## Project

**Repository:** /home/luke/projects/github/argo-multiverse-labs/argoconeu26
**Talk:** Network Segmentation at Scale: GitOps-Driven Multi-Tenant Isolation With Argo CD
**Conference:** ArgoCon EU 2026 (25-minute theatrical demo)

## Version Pins

- Cilium: 1.19
- ArgoCD: 3.3 (Helm chart 9.4.9)
- KinD: 0.31.0 with kindest/node:v1.32.11
- Workloads: nginx:1.27-alpine, curlimages/curl:8.11.0

## Implementation Order

Process design documents in this exact order: 01 → 02 → 03 → 04 → 06 → 05

| Step | File | Scope |
|------|------|-------|
| 1 | design/01-infrastructure.md | KinD config, Cilium/ArgoCD Helm values, Hubble NodePort, bootstrap.sh, Makefile |
| 2 | design/02-tenant-architecture.md | Namespaces, tenant workloads, shared config-api, ArgoCD Applications per stage, ApplicationSet, base templates, tenant directories |
| 3 | design/03-network-policies.md | Stage 0 (none), Stage 1a (K8s NP), Stage 1b (CiliumNP L7), Stage 4 (SA-scoped CNP) |
| 4 | design/04-argocd-security.md | Default project, per-tenant Projects, RBAC, rogue app, ApplicationSet, sync impersonation |
| 5 | design/06-git-strategy.md | staging/tenant-c pre-staged files, commit message convention, reset Makefile targets |
| 6 | design/05-demo-automation.md | Makefile (final), demo-magic.sh scripts per scene, reset scripts, pre-flight checks |

## Canonical Directory Layout

All output files MUST match this structure. No exceptions. No extra top-level directories.

```
argoconeu26/
  Makefile
  cluster/
    kind-config.yaml
    cilium-values.yaml
    argocd-values.yaml
    hubble-ui-nodeport.yaml
  manifests/
    stage-0/
      projects/
        default-project.yaml
      applications/
        tenant-a-app.yaml
        tenant-b-app.yaml
        shared-services-app.yaml
    stage-1a/
      networkpolicies/
        tenant-a-default-deny.yaml
        tenant-a-allow-intra-namespace.yaml
        tenant-a-allow-dns.yaml
        tenant-a-allow-shared-services.yaml
        tenant-b-all.yaml
        shared-services-all.yaml
    stage-1b/
      ciliumnetworkpolicies/
        shared-services-l7.yaml
        tenant-a-fqdn-egress.yaml
    stage-2/
      projects/
        tenant-a-project.yaml
        tenant-b-project.yaml
        default-project-locked.yaml
      argocd-config/
        argocd-rbac-cm.yaml
      applications/
        rogue-app.yaml
        rogue-app-blocked.yaml
    stage-3/
      projects/
        platform-admin-project.yaml
      applicationsets/
        tenant-onboarding.yaml
    stage-4/
      argocd-config/
        argocd-cm.yaml
      projects/
        tenant-a-project-with-impersonation.yaml
        tenant-b-project-with-impersonation.yaml
      rbac/
        impersonation-clusterrole.yaml
      ciliumnetworkpolicies/
        shared-services-sa-scoped.yaml
        tenant-a-sa-scoped.yaml
        tenant-b-sa-scoped.yaml
  base/
    tenant-template/
      kustomization.yaml
      namespace.yaml
      network-policies/
        default-deny.yaml
        allow-shared-services.yaml
        allow-dns.yaml
      rbac/
        service-account.yaml
        role.yaml
        role-binding.yaml
      workloads/
        deployment.yaml
        service.yaml
        curl-client.yaml
    argocd-project/
      Chart.yaml
      values.yaml
      templates/
        project.yaml
  shared-services/
    config-api/
      configmap.yaml
      deployment.yaml
      service.yaml
    kustomization.yaml
  tenants/
    tenant-a/
      kustomization.yaml
      config.json
    tenant-b/
      kustomization.yaml
      config.json
  staging/
    tenant-c/
      kustomization.yaml
      config.json
  demo-apps/
    rogue-workload/
      deployment.yaml
      cluster-rolebinding.yaml
  scripts/
    bootstrap.sh
    reset.sh
    demo-magic.sh
    scene-0-prologue.sh
    scene-1-network.sh
    scene-2-projects.sh
    scene-3-scaling.sh
    scene-4-impersonation.sh
```

## Key Conventions

- Labels: `app: web` (tenant nginx), `app: curl-client` (curl pods), `app: config-api` (shared service)
- Service names: `web` (per-tenant nginx), `config-api` (shared config API in `shared-services`)
- Namespaces: `tenant-a`, `tenant-b`, `shared-services`, `argocd`
- ServiceAccounts: `sa-tenant-a`, `sa-tenant-b` (for SA-scoped CNPs in Stage 4)
- Namespace label: `tenant: <name>` on each tenant namespace
- Stage transitions: `kubectl apply -f manifests/stage-N/` (except Scene 3 which uses a git commit)
- ArgoCD access: `http://localhost:30443` (insecure mode, NodePort)
- Hubble UI: `http://localhost:30080` (NodePort)
- Repo URL in manifests: `https://github.com/argo-multiverse-labs/argoconeu26.git`
- ApplicationSet git directory generator watches: `tenants/*`
- ApplicationSet refresh: `kubectl annotate applicationset <name> argocd.argoproj.io/application-set-refresh=true -n argocd`

## Status Tracking System

Use design documents themselves as work trackers. After implementing each section, annotate the design doc with HTML comment status markers. Place the marker on the line immediately after the section heading or the code block fence for each manifest.

Status markers:
- `<!-- STATUS: PENDING -->` — not yet implemented
- `<!-- STATUS: IMPLEMENTED -->` — file written to disk
- `<!-- STATUS: REVIEWED -->` — validated against design doc
- `<!-- STATUS: ISSUE: description -->` — problem found during implementation

Example annotation placement:

```markdown
### File: `cluster/kind-config.yaml`
<!-- STATUS: IMPLEMENTED -->
```

Or for inline manifests:

```markdown
#### 1. Default-deny ingress and egress -- tenant-a
<!-- STATUS: IMPLEMENTED -->
```

### Resume Protocol

If starting a new session or resuming after interruption:

1. Read all six design documents in implementation order.
2. Scan for `<!-- STATUS: -->` markers in each doc.
3. Find the first section marked PENDING or with no marker.
4. Resume implementation from that point.
5. If a doc has all sections marked REVIEWED, skip to the next doc.

## Agent Dispatch Rules

### Which agent for what

| Agent Specialization | Use For |
|---------------------|---------|
| `kubernetes-operations:kubernetes-architect` | K8s manifests (Deployments, Services, Namespaces, NetworkPolicies, CiliumNetworkPolicies, AppProjects, Applications, ApplicationSets, RBAC, ConfigMaps). All YAML in `manifests/`, `base/`, `tenants/`, `shared-services/`, `staging/`. |
| `cicd-automation:deployment-engineer` | Makefile, bootstrap.sh, Helm install commands. |
| `shell-scripting:bash-pro` | demo-magic.sh scripts (scene-0 through scene-4), reset.sh, pre-flight check scripts. |
| `comprehensive-review:code-reviewer` | Per-doc review after implementation. Compare written files against design doc manifests. |
| `superpowers:code-reviewer` | Cross-doc consistency review after milestones (after doc 03, after doc 04, after doc 05). |

### Parallelism rules

**Parallel dispatch is safe when:**
- Writing files within the same design doc that have no structural dependency on each other.
- Example: tenant-a-default-deny.yaml and tenant-b-all.yaml from doc 03 can be written in parallel.
- Example: kind-config.yaml and cilium-values.yaml from doc 01 can be written in parallel.

**Sequential dispatch is required when:**
- A file's content depends on the output or structure of another file not yet written.
- Example: tenant kustomization.yaml depends on base/tenant-template/ existing first.
- Example: ApplicationSet manifest (doc 04 Stage 3) references base/argocd-project/ Helm chart (doc 02).
- Moving between design documents (always finish current doc + review before starting next).

### Agent dispatch pattern

For each implementable section in a design doc:

1. Read the section. Identify the file path and content from the design doc.
2. Dispatch a subagent with this instruction template:

   > Write the file at `<absolute-path>`. The content must match the following specification from design doc `<NN>`. Here is the specification:
   > `<paste the YAML/script from the design doc>`
   >
   > Conventions to follow:
   > - `<list relevant conventions from the Key Conventions section>`
   >
   > After writing, confirm the file path and a one-line summary of what it contains.

3. After the subagent confirms, mark the section `<!-- STATUS: IMPLEMENTED -->` in the design doc.

### Review gate pattern

After all sections in a design doc are marked IMPLEMENTED:

1. Dispatch a review agent:

   > Review the implementation of design doc `<NN>` (`<title>`).
   >
   > Read the design doc at: `design/<NN>-<name>.md`
   >
   > For every manifest/script/config specified in the design doc, verify:
   > a. The file exists at the correct path per the canonical layout.
   > b. The file content matches the design doc specification.
   > c. Labels, namespace references, port numbers, image tags, and version pins are consistent with the Key Conventions.
   > d. Cross-references to other files (e.g., Kustomize base paths, Helm chart paths, repo URLs) resolve correctly.
   >
   > Report:
   > - Files that match: list them.
   > - Discrepancies found: file path, what differs, what the design doc says.
   > - Missing files: any manifest in the design doc with no corresponding file.

2. Fix any discrepancies found.
3. Mark all passing sections `<!-- STATUS: REVIEWED -->` in the design doc.
4. Mark failing sections `<!-- STATUS: ISSUE: description -->` and fix before proceeding.

## Cross-Document Consistency Checks

Run these checks at the specified boundaries:

### After Doc 02 (before starting Doc 03)
- Verify all pod labels (`app: web`, `app: curl-client`, `app: config-api`) used in doc 03 network policies match the labels in doc 02 workload manifests.
- Verify namespace names in doc 02 match those referenced in doc 03 policy selectors.
- Verify the config-api service port (8080) in doc 02 matches port references in doc 03 policies.

### After Doc 04 (before starting Doc 06)
- Verify ApplicationSet `path: tenants/*` in doc 04 matches the tenant directory structure from doc 02.
- Verify AppProject `sourceRepos` and `destinations` in doc 04 match the repo URL and namespace names from docs 01-02.
- Verify the `base/argocd-project/` Helm chart template in doc 02 produces Projects consistent with the manual Projects in doc 04 Stage 2.
- Verify sync impersonation ServiceAccount names (`sa-tenant-a`, `sa-tenant-b`) in doc 04 match those in doc 03 Stage 4 SA-scoped CNPs.

### After Doc 05 (final review)
- Verify every `kubectl apply -f manifests/stage-N/` command in the demo scripts references directories and files that exist.
- Verify the Makefile targets reference correct paths.
- Verify the bootstrap.sh script references correct Helm value file paths and chart versions matching doc 01.
- Verify demo script curl commands match the validation commands in docs 02-03.

## Implementation Procedure

For each design doc in order (01 → 02 → 03 → 04 → 06 → 05):

### Phase 1: Read and Plan
1. Read the entire design document.
2. List every file that needs to be created, with its full path relative to the repo root.
3. Identify dependencies between files (what must be written first).

### Phase 2: Implement
4. Create parent directories as needed.
5. Dispatch subagents to write files. Use parallel dispatch where safe per the parallelism rules.
6. After each file is written, add `<!-- STATUS: IMPLEMENTED -->` to the corresponding section in the design doc.

### Phase 3: Review
7. Dispatch a review agent to validate all files from this doc.
8. Fix any discrepancies.
9. Update status markers to REVIEWED for passing sections.

### Phase 4: Cross-Doc Check (at boundaries specified above)
10. Run the relevant cross-document consistency check.
11. Fix any inconsistencies before proceeding to the next doc.

### Phase 5: Proceed
12. Move to the next design doc.

## What NOT To Implement

- Do not create a README.md (will be written separately).
- Do not modify design documents beyond adding STATUS markers.
- Do not create tests or CI pipelines unless specified in a design doc.
- Do not resolve open questions marked in the design docs — implement what is specified and flag open questions with `<!-- STATUS: ISSUE: OQ-N still open -->`.

## Completion Criteria

Implementation is complete when:
1. Every manifest, script, and config file specified across all six design docs exists at its canonical path.
2. Every implementable section in every design doc is marked `<!-- STATUS: REVIEWED -->`.
3. All three cross-document consistency checks pass.
4. The Makefile `build-all` target references all required infrastructure install steps.
5. All demo scripts (scene-0 through scene-4) exist and contain the commands from the design docs.
6. Ensure you have kept to the spirit of our talk ArgoConEU26 - Talk Outline Draft.md 

## Edge Cases

- Design docs contain some manifests shown inline and some shown as separate files. Distinguish "this is a file to write" from "this is an example for explanation."
- Doc 02 and Doc 04 both define ApplicationSet and Project manifests for Stage 3. Doc 04 is more detailed — use doc 04 as the authoritative source when they overlap.
- Doc 01 contains both a Makefile and a bootstrap.sh. Doc 05 contains an expanded Makefile. Doc 05's Makefile is the final version and should supersede doc 01's.
