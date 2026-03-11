# Design Document 06: Git Commit and PR Strategy

**Talk:** Network Segmentation at Scale: GitOps-Driven Multi-Tenant Isolation With Argo CD
**Conference:** ArgoCon EU 2026
**Scope:** Repository architecture, git state per talk stage, branch/tag strategy, reset mechanisms, and post-conference repo layout
**Dependencies:** Reads from all Wave 1 design docs (01-04) for manifest paths, ApplicationSet design, and stage definitions

---

## Table of Contents

1. [Repository Architecture Decision](#1-repository-architecture-decision)
2. [Git State Design Per Talk Stage](#2-git-state-design-per-talk-stage)
3. [The Scene 3 Git Moment](#3-the-scene-3-git-moment)
4. [Branch Strategy](#4-branch-strategy)
5. [Git Reset Mechanism](#5-git-reset-mechanism)
6. [Commit Message Convention](#6-commit-message-convention)
7. [Post-Conference Repo State](#7-post-conference-repo-state)
8. [Open Questions](#8-open-questions)

---

## 1. Repository Architecture Decision

### Option A -- Single Repo

This repository (`argo-multiverse-labs/argoconeu26`) serves as both the talk infrastructure/automation code AND the GitOps source that ArgoCD watches.

**Advantages:**
- One repo to clone, one repo to understand.
- Attendees browsing the repo after the conference see everything in one place.
- The Scene 3 "one commit = one tenant" moment happens in the repo attendees already have open.
- Simpler CI, simpler git reset, simpler mental model.
- Demo scripts, design docs, and the actual GitOps manifests share a single `git log`.

**Disadvantages:**
- ArgoCD watches a repo that also contains Makefiles, scripts, design docs, and non-GitOps content. This is unrealistic for production.
- The ApplicationSet git directory generator will scan the repo root, which includes directories it should ignore (e.g., `design/`, `scripts/`). This is solved by scoping the generator to `tenants/*` which is already the design in doc 02 and doc 04.
- The git history mixes demo infrastructure changes (Makefile tweaks, script fixes) with the GitOps changes ArgoCD cares about. In production you would never want this.

### Option B -- Two Repos

- `argo-multiverse-labs/argoconeu26` -- talk infrastructure, automation, design docs, demo scripts.
- `argo-multiverse-labs/argoconeu26-gitops` -- the GitOps repo ArgoCD watches. Contains only `tenants/`, `shared-services/`, `base/`, `argocd/`, and `network-policies/`.

**Advantages:**
- Mirrors real-world pattern (separation of concerns).
- The GitOps repo has a clean `git log` with only policy/manifest changes.
- ArgoCD configuration is realistic -- attendees can replicate the pattern.
- No risk of ArgoCD reacting to non-GitOps commits (script changes, doc updates).

**Disadvantages:**
- Two repos to manage, two repos to reset, two repos to clone.
- The Scene 3 git commit happens in a repo the audience may not have open.
- Resetting the demo requires coordinating git state across two repos.
- Adds complexity to the bootstrap process (ArgoCD must be configured with credentials for a second repo).
- For a KinD demo, the "realism" of two repos provides no functional benefit.

### Recommendation: Option A -- Single Repo

**Rationale:** This is a 25-minute conference demo, not a production reference architecture. The single-repo approach optimizes for the things that matter most during the talk:

1. **Simplicity.** One repo means one `git log`, one `git reset`, one mental model. The audience is already absorbing dense content (CiliumNetworkPolicies, ArgoCD Projects, ApplicationSets, sync impersonation). Adding a second repo to their mental model burns cognitive budget with no teaching value.

2. **The Scene 3 moment.** The climax of the GitOps story is "add a directory, push, watch ArgoCD provision everything." This moment is most impactful when it happens in the repo the audience is already looking at. If the commit goes to a separate repo, you have to explain the repo boundary first, which steals time from the payoff.

3. **Post-conference browsability.** Attendees who find the repo after the conference can `git log` and see the entire narrative in one place. Two repos fragments the story.

4. **ApplicationSet scoping.** The git directory generator watches `tenants/*`. It does not scan `design/`, `scripts/`, or `Makefile`. ArgoCD ignores non-GitOps content structurally, without needing repo-level separation.

5. **Reset simplicity.** Resetting one repo is trivial. Resetting two repos atomically requires coordination scripts that add failure modes during live demos.

**The tradeoff is realism.** Acknowledge this explicitly in the talk or README: "In production, you would typically separate your GitOps manifests into a dedicated repository. We use a single repo here for demo clarity." This takes five seconds and costs nothing.

---

## 2. Git State Design Per Talk Stage

Each stage below describes the exact set of files that exist in the repo, the commit that introduced them, and what ArgoCD sees when it polls.

### 2.1 Repo Directory Tree (Final State)

For reference, this is the complete file tree at the end of the talk (Stage 4). Earlier stages are subsets.

```
argoconeu26/
|-- Makefile
|-- README.md
|-- design/                              # Design docs (ArgoCD ignores)
|-- scripts/                             # Demo automation (ArgoCD ignores)
|   |-- demo-magic.sh
|   |-- scene-0-prologue.sh
|   |-- scene-1-network.sh
|   |-- scene-2-projects.sh
|   |-- scene-3-scaling.sh
|   |-- scene-4-impersonation.sh
|   |-- reset.sh
|
|-- cluster/                             # Infrastructure (ArgoCD ignores)
|   |-- kind-config.yaml
|   |-- cilium-values.yaml
|   |-- argocd-values.yaml
|
|-- base/                                # Shared templates
|   |-- tenant-template/
|   |   |-- kustomization.yaml
|   |   |-- namespace.yaml
|   |   |-- network-policies/
|   |   |   |-- default-deny.yaml
|   |   |   |-- allow-shared-services.yaml
|   |   |   |-- allow-dns.yaml
|   |   |-- rbac/
|   |   |   |-- service-account.yaml
|   |   |   |-- role.yaml
|   |   |   |-- role-binding.yaml
|   |   |-- workloads/
|   |       |-- deployment.yaml
|   |       |-- service.yaml
|   |       |-- curl-client.yaml
|   |-- argocd-project/
|       |-- Chart.yaml
|       |-- values.yaml
|       |-- templates/
|           |-- project.yaml
|
|-- shared-services/
|   |-- config-api/
|   |   |-- configmap.yaml
|   |   |-- deployment.yaml
|   |   |-- service.yaml
|   |-- kustomization.yaml
|
|-- tenants/                             # ApplicationSet watches this
|   |-- tenant-a/
|   |   |-- kustomization.yaml
|   |   |-- config.json
|   |   |-- project.yaml
|   |   |-- rbac.yaml
|   |   |-- network-policies.yaml
|   |   |-- workloads/
|   |-- tenant-b/
|   |   |-- (same structure)
|   |-- tenant-c/                        # Added in Scene 3
|       |-- (same structure)
|
|-- manifests/                           # All staged manifests, self-contained per stage
|   |-- stage-0/
|   |   |-- applications/
|   |   |   |-- tenant-a-app.yaml
|   |   |   |-- tenant-b-app.yaml
|   |   |   |-- shared-services-app.yaml
|   |-- stage-1a/
|   |   |-- networkpolicies/
|   |       |-- tenant-a-default-deny.yaml
|   |       |-- tenant-a-allow-intra-namespace.yaml
|   |       |-- tenant-a-allow-dns.yaml
|   |       |-- tenant-a-allow-shared-services.yaml
|   |       |-- tenant-b-all.yaml
|   |       |-- shared-services-all.yaml
|   |-- stage-1b/
|   |   |-- ciliumnetworkpolicies/
|   |       |-- shared-services-l7.yaml
|   |       |-- tenant-a-fqdn-egress.yaml
|   |-- stage-2/
|   |   |-- projects/
|   |   |   |-- tenant-a-project.yaml
|   |   |   |-- tenant-b-project.yaml
|   |   |   |-- default-project-locked.yaml
|   |   |-- argocd-config/
|   |   |   |-- argocd-rbac-cm.yaml
|   |   |-- applications/
|   |       |-- rogue-app.yaml
|   |       |-- rogue-app-blocked.yaml
|   |-- stage-3/
|   |   |-- projects/
|   |   |   |-- platform-admin-project.yaml
|   |   |-- applicationsets/
|   |       |-- tenant-onboarding.yaml
|   |-- stage-4/
|       |-- argocd-config/
|       |   |-- argocd-cm.yaml
|       |-- projects/
|       |   |-- tenant-a-project-with-impersonation.yaml
|       |   |-- tenant-b-project-with-impersonation.yaml
|       |-- rbac/
|       |   |-- impersonation-clusterrole.yaml
|       |-- ciliumnetworkpolicies/
|           |-- shared-services-sa-scoped.yaml
|           |-- tenant-a-sa-scoped.yaml
|           |-- tenant-b-sa-scoped.yaml
|
|-- demo-apps/                           # Rogue workload for Scene 2 attack demo
    |-- rogue-workload/
        |-- deployment.yaml
        |-- cluster-rolebinding.yaml
```

### 2.2 Stage 0 -- Prologue: "The Platform Is Ready"

**What exists in git:** Everything EXCEPT `tenants/tenant-c/` and `manifests/stage-{1a,1b,2,3,4}/`. The repo contains the infrastructure, the Stage 0 Applications (in the default project), the base templates, tenant-a, tenant-b, and shared-services.

**Key files present:**

```
manifests/stage-0/applications/
  tenant-a-app.yaml          # project: default
  tenant-b-app.yaml          # project: default
  shared-services-app.yaml   # project: default

tenants/tenant-a/             # Workloads only (no network policies yet)
tenants/tenant-b/             # Workloads only
shared-services/              # Config API
```

**What ArgoCD sees:** Three Applications, all in the `default` project. Automated sync is enabled. All tenant workloads and shared-services are deployed. No NetworkPolicies exist. The flat network is wide open.

**Applied via demo script:** `kubectl apply -f manifests/stage-0/applications/`

**Important:** At Stage 0, the tenant directories under `tenants/` contain only the workload manifests (deployment, service, curl-client). They do NOT yet contain the `project.yaml`, `rbac.yaml`, or `network-policies.yaml` files. Those are introduced in later stages. The ArgoCD Applications at this stage point directly at the workloads path, not at a Kustomize overlay that includes policy files.

### 2.3 Stage 1a -- Standard NetworkPolicies Added

**What changes:** The `manifests/stage-1a/networkpolicies/` directory is applied via `kubectl apply`. No git commit is needed during the live demo for this stage -- the manifests already exist in the repo, and the demo script applies them directly.

**What ArgoCD sees:** No change. The NetworkPolicies are applied directly via kubectl, not through ArgoCD Applications. This is intentional -- at this point in the narrative, the Platform Engineer is still doing things ad-hoc. The "everything should be in git" lesson comes in Scene 3.

**Applied via demo script:**

```bash
kubectl apply -f manifests/stage-1a/networkpolicies/
```

### 2.4 Stage 1b -- CiliumNetworkPolicies Replace Standard NPs

**What changes:** The standard NetworkPolicies on `shared-services` are deleted and replaced with CiliumNetworkPolicies from `manifests/stage-1b/`. The tenant standard NPs from Stage 1a remain.

**What ArgoCD sees:** Still no change. Same three Applications in the default project. The CNPs are applied out-of-band via kubectl.

**Applied via demo script:**

```bash
kubectl delete networkpolicy -n shared-services --all
kubectl apply -f manifests/stage-1b/ciliumnetworkpolicies/
```

### 2.5 Stage 2 -- Per-Tenant ArgoCD Projects + RBAC

**What changes:** Per-tenant ArgoCD Projects are created. The existing Applications are updated to reference their tenant Projects instead of `default`. The default project is locked down. RBAC ConfigMap is updated.

**What ArgoCD sees:** Two new AppProjects (`tenant-a`, `tenant-b`). The Applications now reference `project: tenant-a` and `project: tenant-b`. The `default` project is locked (empty destinations).

**Applied via demo script:**

```bash
# Create per-tenant projects
kubectl apply -f manifests/stage-2/projects/

# Update RBAC
kubectl apply -f manifests/stage-2/argocd-config/

# Update existing Applications to use tenant projects
kubectl apply -f manifests/stage-2/applications/

# Demo the breach attempt
kubectl apply -f manifests/stage-2/applications/rogue-app-blocked.yaml
# ... show the error ...
kubectl delete application -n argocd rogue-deployment
```

**Note:** Stage 2 does not require a git push. The manifests are applied directly. The git commit for the rogue Application attempt could be staged in a pre-prepared branch if we want to show ArgoCD rejecting it via a sync, but it is simpler and more reliable to apply via kubectl and show the error message.

### 2.6 Stage 3 -- ApplicationSets + Tenant Directory Structure

This is the pivotal git moment. See Section 3 for the full breakdown.

**What changes in git:** A single commit adds `tenants/tenant-c/` with all its files (kustomization.yaml, config.json, project.yaml, rbac.yaml, network-policies.yaml, workloads/).

**What changes on the cluster:** The manually-created Stage 0/2 Applications are deleted. The ApplicationSet and platform-admin project are applied. The ApplicationSet discovers `tenants/*` and generates Applications for tenant-a, tenant-b, and tenant-c.

**What ArgoCD sees:** The ApplicationSet `tenant-onboarding` watches `tenants/*`. It generates one Application per tenant directory. Each Application deploys the full tenant stack: namespace, ArgoCD Project, RBAC, CiliumNetworkPolicies, and workloads.

### 2.7 Stage 4 -- Sync Impersonation

**What changes:** ArgoCD ConfigMap is patched to enable impersonation. AppProjects are updated with `destinationServiceAccounts`. The impersonation ClusterRole/ClusterRoleBinding is applied. SA-scoped CiliumNetworkPolicies are applied.

**What ArgoCD sees:** The existing Applications now sync using tenant ServiceAccounts. The SA-scoped CNPs restrict network access at the identity level.

**Applied via demo script:**

```bash
# Enable impersonation in argocd-cm
kubectl apply -f manifests/stage-4/argocd-config/

# Apply impersonation RBAC
kubectl apply -f manifests/stage-4/rbac/

# Update Projects with destinationServiceAccounts
kubectl apply -f manifests/stage-4/projects/

# Apply SA-scoped CiliumNetworkPolicies
kubectl apply -f manifests/stage-4/ciliumnetworkpolicies/
```

---

## 3. The Scene 3 Git Moment

This section designs the climax of the GitOps narrative. The audience watches a single directory addition trigger full tenant provisioning.

### 3.1 What the Audience Sees on Screen

The terminal is visible on the projector. The presenter (Luke, as the Platform Engineer) types the following commands. The audience watches each command execute.

### 3.2 Pre-Requisite: ApplicationSet Is Already Running

Before the git moment, the demo script has already:

1. Deleted the Stage 0/2 manual Applications.
2. Applied the `platform-admin` AppProject.
3. Applied the `tenant-onboarding` ApplicationSet.

At this point, the ApplicationSet has already generated Applications for `tenant-a` and `tenant-b` from their existing directories. The audience should see these two Applications healthy in the ArgoCD UI.

The ApplicationSet manifest references the repo at `revision: HEAD` (or `main`). For a local KinD demo, the repo URL must be accessible from inside the cluster. This requires one of:

- The repo is on GitHub and the cluster has internet access (simplest for a real demo).
- A local git server (gitea or bare repo) running inside the cluster (adds complexity).
- ArgoCD is configured with a local path (not supported natively).

**Decision: Use GitHub.** The demo runs against the real GitHub repo. The Scene 3 commit is a real `git push` to GitHub. ArgoCD polls GitHub on its default interval (~3 minutes) or can be manually triggered via `argocd app get --refresh`.

### 3.3 Directory Structure Added
<!-- STATUS: REVIEWED -->

The `tenants/tenant-c/` directory contains the complete tenant stack. All files are pre-prepared and added in a single commit.

```
tenants/tenant-c/
|-- config.json               # Tenant metadata
|-- kustomization.yaml        # Kustomize overlay referencing base/tenant-template
|-- project.yaml              # ArgoCD AppProject scoped to tenant-c
|-- rbac.yaml                 # ServiceAccount + Role + RoleBinding
|-- network-policies.yaml     # CiliumNetworkPolicies (default-deny + shared-services)
|-- workloads/
    |-- (inherited from base via kustomization.yaml)
```

**Note on workloads directory:** If using Kustomize overlays that reference `../../base/tenant-template`, the tenant directory does not need to duplicate the workload YAML files. The `kustomization.yaml` pulls resources from the base template and overlays tenant-specific values (namespace, labels). The `workloads/` directory under the tenant may be empty or omitted entirely if everything comes from the base.

### 3.4 The Exact Git Commands

These are the commands shown to the audience. They use `demo-magic.sh` simulated typing for pacing.

```bash
# Step 1 -- Show the current tenant directories
ls tenants/
# => tenant-a  tenant-b

# Step 2 -- Create the new tenant from the template
# (In practice, this is pre-staged. The presenter "types" these but
#  the files are already prepared in a staging area or branch.)
cp -r tenants/tenant-a tenants/tenant-c

# Step 3 -- Customise the tenant config
# (Show the config.json to the audience)
cat tenants/tenant-c/config.json
# => { "tenantName": "tenant-c", "team": "tenant-c-team", ... }

# Step 4 -- Stage and commit
git add tenants/tenant-c/
git status
# => new file: tenants/tenant-c/config.json
# => new file: tenants/tenant-c/kustomization.yaml
# => new file: tenants/tenant-c/project.yaml
# => new file: tenants/tenant-c/rbac.yaml
# => new file: tenants/tenant-c/network-policies.yaml

git commit -m "onboard tenant-c: full isolation stack in one commit"

# Step 5 -- Push to GitHub
git push

# Step 6 -- Trigger ArgoCD refresh (avoid waiting for poll interval)
argocd app list --refresh
```

### 3.5 What ArgoCD Does in Response

After the push and refresh, the following happens automatically:

1. **ApplicationSet detects new directory.** The git directory generator scans `tenants/*` and finds `tenant-c/` as a new entry. It generates a new Application: `tenant-stack-tenant-c`.

2. **Application syncs.** The Application points at `tenants/tenant-c/` and syncs the Kustomize output. This creates:
   - Namespace `tenant-c` (via `CreateNamespace=true`)
   - AppProject `tenant-c` in the `argocd` namespace
   - ServiceAccount `tenant-c-sa` in `tenant-c`
   - Role and RoleBinding in `tenant-c`
   - CiliumNetworkPolicy `tenant-c-default-deny` in `tenant-c`
   - CiliumNetworkPolicy `tenant-c-shared-services-access` in `tenant-c`
   - Deployment `web` in `tenant-c`
   - Service `web` in `tenant-c`
   - Pod `curl-client` in `tenant-c`

3. **ArgoCD UI updates.** A new Application card appears in the ArgoCD UI, transitioning from `OutOfSync` to `Synced` and `Healthy`.

### 3.6 Timing Expectations

| Step | Duration |
|------|----------|
| `git push` | ~1-2 seconds |
| ArgoCD poll interval (default) | up to 3 minutes |
| ArgoCD poll interval (with `--refresh`) | ~5-10 seconds |
| Application sync (namespace + all resources) | ~10-20 seconds |
| Total (with manual refresh) | ~15-30 seconds |
| Total (without manual refresh) | up to ~3.5 minutes |

**Recommendation:** Always trigger a manual refresh (`argocd app list --refresh`) after the push. The 3-minute poll interval creates dead air that kills the demo's momentum. With a manual refresh, the total time from push to resources appearing is 15-30 seconds, which is fast enough to watch live.

**Alternative: Webhook.** Configure a GitHub webhook to notify ArgoCD on push. This eliminates the need for a manual refresh and makes the "push and watch" experience seamless. However, webhooks require the KinD cluster to be reachable from GitHub, which is not possible without a tunnel (e.g., ngrok). For a local demo, manual refresh is more reliable.

### 3.7 What the Audience Should See

Split screen or tab layout on the projector:

- **Left/Tab 1:** Terminal showing the git commands.
- **Right/Tab 2:** ArgoCD UI (Applications view) showing the new Application appear and sync.

The presenter narrates: "One directory. One commit. One push. ArgoCD detected the new tenant, created the namespace, the Project, the RBAC, the CiliumNetworkPolicies, and the workloads. That tenant is fully isolated from the moment it exists."

Then the Rogue Tenant (Christian) validates:

```bash
# Verify tenant-c namespace exists
kubectl get namespace tenant-c

# Verify CiliumNetworkPolicies are in place
kubectl get ciliumnetworkpolicy -n tenant-c

# Verify the AppProject is scoped correctly
argocd proj get tenant-c

# Attempt cross-tenant access from tenant-c (should be blocked)
kubectl exec -n tenant-c curl-client -- \
  curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
  http://web.tenant-b.svc.cluster.local
# => 000 (timeout -- blocked by CNP)
```

---

## 4. Branch Strategy

### Options Evaluated

#### Option 1: Tag-Based

Each stage is a git tag (`stage/prologue`, `stage/scene-1a`, etc.). The repo state at each tag represents the complete file tree for that stage.

- **Pro:** Tags are immutable. `git checkout stage/scene-2` always gives the same state.
- **Con:** Each tag must contain the complete file tree for that stage, meaning earlier stages omit files that exist in later stages. This creates a confusing `git log` where files appear and disappear.
- **Con:** Tags do not play well with the ApplicationSet git directory generator, which watches a specific branch (`revision: main`), not tags.
- **Con:** Resetting to a tag with `git checkout` puts the repo in detached HEAD state, which is confusing if you then try to commit.

#### Option 2: Branch-Per-Stage

Separate branches: `stage/prologue`, `stage/scene-1a`, `stage/scene-1b`, `stage/scene-2`, `stage/scene-3`, `stage/scene-4`.

- **Pro:** Each branch is a clean snapshot of the repo at that stage.
- **Pro:** Switching stages is `git checkout stage/scene-2` -- fast and clear.
- **Con:** The ApplicationSet watches a specific branch. To move between stages, you would need to update the ApplicationSet's `revision` field or switch the branch that `main` points to.
- **Con:** Maintaining six branches that diverge creates a merge/maintenance burden.
- **Con:** The `git log` story is fragmented across branches. Attendees cannot read the progression with a single `git log`.

#### Option 3: Single Branch With Reset Scripts

One branch (`main`). All files for all stages exist simultaneously. The demo scripts apply or remove manifests to simulate stage progression. Git state does not change during the demo (except for the Scene 3 commit).

- **Pro:** Simplest git model. One branch, one history.
- **Pro:** The ApplicationSet always watches `main`.
- **Pro:** Attendees see all files in one place.
- **Con:** No clear way to "see" stage boundaries in git history.
- **Con:** Files for later stages are visible in earlier stages, which could confuse attendees browsing the repo.

#### Option 4: Stacked Commits

Single branch. Each stage is a commit. The history reads as a progression:

```
commit 6: "scene 4: sync impersonation for identity-aware isolation"
commit 5: "scene 3: onboard tenant-c — one commit, full isolation"
commit 4: "scene 2: per-tenant ArgoCD projects + RBAC"
commit 3: "scene 1b: CiliumNetworkPolicies for L7 filtering"
commit 2: "scene 1a: standard NetworkPolicies for L3/L4"
commit 1: "prologue: flat network, default project, no policies"
commit 0: "infrastructure: KinD, Cilium, ArgoCD bootstrap"
```

- **Pro:** `git log` tells the complete story. Each commit is a chapter.
- **Pro:** Tags can mark each commit for easy reference without branching.
- **Pro:** Resetting to a stage is `git reset --hard <tag>`.
- **Con:** The Scene 3 commit is not a "real" commit during the talk -- it was already staged. This is a minor illusion.
- **Con:** `git reset --hard` is destructive. Requires care.
- **Con:** The ApplicationSet watches `main`. If you `git reset --hard` to an earlier commit and force-push, you have rewritten history, which is uncomfortable.

### Recommendation: Option 3 -- Single Branch With Reset Scripts + Tags for Reference

**Rationale:**

The critical insight is that **the demo progression is driven by `kubectl apply`, not by git commits.** Stages 0, 1a, 1b, 2, and 4 are all applied via demo scripts that run `kubectl apply -f manifests/stage-N/`. The only stage that requires a live git commit is Scene 3 (adding `tenants/tenant-c/`).

This means the git strategy and the demo progression strategy are two different things:

- **Git strategy:** All files exist on `main` from the start. The repo is complete.
- **Demo progression:** Scripts apply manifests incrementally. The cluster state changes, not the git state.
- **Scene 3 exception:** The `tenants/tenant-c/` directory is the one thing that must be added via a live git commit. This is handled by pre-staging the files outside the repo and copying them in during the demo (see Section 3.4).

**Tags for reference:** After the demo is finalized, add lightweight tags to mark the commits that correspond to each stage of the talk. These are for post-conference browsability, not for demo execution.

**Why not stacked commits:** Stacked commits create an elegant `git log` but force the demo to use `git reset --hard` for rehearsal resets, which is destructive and error-prone. It also means the ApplicationSet's `revision: main` would need to be updated each time you reset, or you would force-push to `main`, which creates opportunities for mistakes during a live talk. The single-branch approach avoids all of this.

**Why not branches:** Branch-per-stage fragments the story and creates maintenance overhead. It also conflicts with the ApplicationSet's need to watch a single branch.

### How Scene 3 Works With This Strategy

The `tenants/tenant-c/` directory does NOT exist in the repo at the start of the demo. It is prepared in advance and stored in the `staging/` directory, which is committed to the repo. Since the demo uses explicit `git add tenants/tenant-c/`, there is no risk of accidentally committing staged files at the wrong time.

During Scene 3, the presenter copies the files into `tenants/tenant-c/`, commits, and pushes. This is a real git commit on `main`. The ApplicationSet detects it.

For rehearsal resets, `tenants/tenant-c/` is deleted and the delete is committed (or the staging copy is simply restored). See Section 5.

### Directory Layout for Staging
<!-- STATUS: REVIEWED -->

```
argoconeu26/
|-- staging/
|   |-- tenant-c/                # Pre-prepared tenant-c files, committed to the repo
|       |-- config.json
|       |-- kustomization.yaml
|       |-- project.yaml
|       |-- rbac.yaml
|       |-- network-policies.yaml
```

The Scene 3 demo command becomes:

```bash
cp -r staging/tenant-c tenants/tenant-c
git add tenants/tenant-c/
git commit -m "onboard tenant-c: full isolation stack in one commit"
git push
```

---

## 5. Git Reset Mechanism

### Requirements

1. Must be fast (seconds, not minutes).
2. Must be safe (no accidental data loss of non-demo work).
3. Must handle both git state and cluster state together.
4. Must be a single command (Makefile target).

### Reset Design

Because the demo uses Option 3 (single branch, all files present, progression via `kubectl apply`), resetting has two independent dimensions:

- **Git reset:** Restore `tenants/tenant-c/` to its pre-demo state (not present in the repo).
- **Cluster reset:** Remove all tenant namespaces, Applications, Projects, NetworkPolicies, and ApplicationSets. Restore to Stage 0.

These can be done independently or together.

### Makefile Targets
<!-- STATUS: PENDING — implemented in doc 05 -->

```makefile
# ---- Demo Reset ----

.PHONY: reset-demo
reset-demo: reset-cluster reset-git ## Full reset: cluster state + git state
	@echo "Demo fully reset. Ready for re-run."

.PHONY: reset-cluster
reset-cluster: ## Reset cluster to pre-demo state (keep infrastructure)
	kubectx kind-$(KIND_CLUSTER_NAME)
	# Delete all ArgoCD ApplicationSets
	-kubectl delete applicationsets.argoproj.io --all -n argocd 2>/dev/null
	# Delete all ArgoCD Applications
	-kubectl delete applications.argoproj.io --all -n argocd 2>/dev/null
	# Delete all non-default ArgoCD Projects
	-kubectl get appprojects -n argocd -o name | grep -v 'default' | \
		xargs -r kubectl delete -n argocd 2>/dev/null
	# Restore the default project to its wide-open state
	-kubectl apply -f manifests/stage-0/default-project.yaml 2>/dev/null
	# Delete tenant and shared-services namespaces
	-kubectl delete namespace tenant-a tenant-b tenant-c shared-services 2>/dev/null
	# Delete all NetworkPolicies and CiliumNetworkPolicies
	-kubectl delete networkpolicy --all --all-namespaces 2>/dev/null
	-kubectl delete ciliumnetworkpolicy --all --all-namespaces 2>/dev/null
	# Delete impersonation RBAC
	-kubectl delete clusterrole argocd-application-controller-impersonate 2>/dev/null
	-kubectl delete clusterrolebinding argocd-application-controller-impersonate 2>/dev/null
	# Reset argocd-cm to pre-impersonation state
	-kubectl patch configmap argocd-cm -n argocd --type merge \
		-p '{"data":{"application.sync.impersonation.enabled":"false"}}' 2>/dev/null
	@echo "Cluster reset to clean infrastructure state."

.PHONY: reset-git
reset-git: ## Remove tenant-c from git (if it was added during Scene 3)
	@if [ -d tenants/tenant-c ]; then \
		rm -rf tenants/tenant-c; \
		git add -A tenants/tenant-c; \
		git commit -m "reset: remove tenant-c for demo re-run" --allow-empty; \
		git push; \
		echo "tenant-c removed from git and pushed."; \
	else \
		echo "tenant-c does not exist in git. No reset needed."; \
	fi

.PHONY: reset-to-stage
reset-to-stage: reset-cluster ## Reset to a specific stage (usage: make reset-to-stage STAGE=2)
ifndef STAGE
	$(error STAGE is not set. Usage: make reset-to-stage STAGE=2)
endif
	@echo "Applying stages 0 through $(STAGE)..."
	@for s in $$(seq 0 $(STAGE)); do \
		stage_dir="manifests/stage-$$s"; \
		if [ "$$s" = "1" ]; then stage_dir="manifests/stage-1a"; fi; \
		if [ -d "$$stage_dir" ]; then \
			echo "  Applying $$stage_dir..."; \
			kubectl apply -R -f "$$stage_dir/" 2>/dev/null || true; \
		fi; \
	done
	@echo "Cluster reset to Stage $(STAGE)."
```

### Safety Measures

1. **No `git reset --hard`.** The reset mechanism uses `rm -rf` on a specific known directory and a normal commit. It does not rewrite history or discard uncommitted changes in other files.

2. **No force push.** The reset commit is a normal forward commit (`"reset: remove tenant-c for demo re-run"`). This keeps the git history clean and avoids force-push risks.

3. **Idempotent.** Running `make reset-demo` twice produces the same result. All `kubectl delete` commands use `--ignore-not-found` semantics (the `-` prefix in Makefile silences errors).

4. **Cluster reset is git-independent.** `make reset-cluster` does not touch git. You can reset the cluster without pushing anything. This is important for rapid rehearsal loops where you do not want to pollute the git history.

5. **Git reset is cluster-independent.** `make reset-git` only removes `tenants/tenant-c/` from git. It does not touch the cluster. This allows you to reset git while the cluster is in any state.

### Rehearsal Workflow

```bash
# Full demo run
make build-all                    # Create cluster + infrastructure
scripts/scene-0-prologue.sh       # Run prologue
scripts/scene-1-network.sh        # Run Scene 1
scripts/scene-2-projects.sh       # Run Scene 2
scripts/scene-3-scaling.sh        # Run Scene 3 (includes the git commit)
scripts/scene-4-impersonation.sh  # Run Scene 4

# Reset for re-run (keeps the KinD cluster)
make reset-demo                   # Takes ~30-60 seconds

# Run again
scripts/scene-0-prologue.sh
# ...
```

---

## 6. Commit Message Convention

### Format

Each commit message follows this structure:

```
<scope>: <what changed and why>

<optional body with detail>
```

Where `<scope>` is one of:
- `infra` -- cluster configuration, Helm values, Makefile
- `prologue` / `scene-1a` / `scene-1b` / `scene-2` / `scene-3` / `scene-4` -- demo stage content
- `docs` -- design documents, README
- `scripts` -- demo automation
- `reset` -- demo reset operations

### Commit Messages for Each Stage Transition

The following messages represent the narrative arc of the repo. Attendees reading `git log --oneline` should be able to follow the story.

```
# Foundation (pre-demo, during development)
abc1234  infra: KinD cluster with Cilium CNI and ArgoCD bootstrap
def5678  infra: shared config-api service for L7 demo
ghi9012  prologue: tenant-a and tenant-b workloads in default project

# Stage 1 manifests (pre-demo, during development)
jkl3456  scene-1a: standard NetworkPolicies — default-deny per namespace
mno7890  scene-1b: CiliumNetworkPolicies — L7 path filtering on shared service

# Stage 2 manifests (pre-demo, during development)
pqr1234  scene-2: per-tenant ArgoCD Projects with scoped destinations
stu5678  scene-2: RBAC — tenant self-service within project boundaries

# Stage 3 setup (pre-demo, during development)
vwx9012  scene-3: ApplicationSet for automated tenant onboarding
yza3456  scene-3: base tenant template with Kustomize overlays

# THE LIVE COMMIT (done on stage during the talk)
bcd7890  onboard tenant-c: full isolation stack in one commit

# Stage 4 manifests (pre-demo, during development)
efg1234  scene-4: sync impersonation configuration for identity-aware isolation
hij5678  scene-4: SA-scoped CiliumNetworkPolicies

# Reset commits (rehearsal only, not part of the narrative)
klm9012  reset: remove tenant-c for demo re-run
```

### The Live Commit Message

The Scene 3 commit message is visible on the projector. It should be concise and meaningful:

```
onboard tenant-c: full isolation stack in one commit
```

This message is intentionally short and punchy. It reinforces the talk's thesis: one commit provisions an entire tenant with full isolation. The audience reads it on screen and immediately understands what happened.

Alternative options (if a different tone is preferred):

```
add tenant-c: namespace, project, RBAC, CNPs, workloads
```

```
onboard tenant-c — gitops-driven tenant provisioning
```

---

## 7. Post-Conference Repo State

### What Attendees Find

After the conference, `main` branch should contain:

1. **All files for all stages.** The repo is in its "final" state with all manifests present.
2. **The `tenants/tenant-c/` directory.** It should exist in the final state, representing the complete three-tenant setup.
3. **The `staging/` directory.** Committed to the repo, so attendees can re-create the Scene 3 experience themselves by removing `tenant-c` and re-adding it from `staging/`.
4. **Tags marking each stage.** Lightweight tags on the commits that correspond to stage transitions, for easy reference.

### Tags

```
v0-prologue          # Commit where Stage 0 manifests were added
v1a-standard-np      # Commit where Stage 1a manifests were added
v1b-cilium-np        # Commit where Stage 1b manifests were added
v2-argocd-projects   # Commit where Stage 2 manifests were added
v3-applicationsets   # Commit where ApplicationSet + tenant-c were added
v4-impersonation     # Commit where Stage 4 manifests were added
```

These tags are informational. They do not affect the demo execution.

### README Walk-Through

The repo's `README.md` should include:

1. **Prerequisites** -- link to design doc 01 for tooling requirements.
2. **Quick start** -- `make build-all` to create the cluster.
3. **Demo stages** -- a table mapping each stage to its Makefile target and what it demonstrates.
4. **Re-running the demo** -- instructions for `make reset-demo` and re-running each scene.
5. **The Scene 3 experience** -- step-by-step instructions for attendees to do the "add tenant-c" commit themselves.
6. **Architecture note** -- "In production, separate your GitOps manifests into a dedicated repository."

### Try-It-Yourself Section

Include a section in the README specifically for attendees who want to experience the Scene 3 moment:

```markdown
## Try It Yourself: Onboard a New Tenant

1. Remove tenant-c (if it exists):
   ```bash
   rm -rf tenants/tenant-c
   git add -A tenants/tenant-c
   git commit -m "remove tenant-c for try-it-yourself"
   git push
   ```

2. Wait for ArgoCD to detect the removal and delete tenant-c resources.

3. Re-add tenant-c:
   ```bash
   cp -r staging/tenant-c tenants/tenant-c
   git add tenants/tenant-c/
   git commit -m "onboard tenant-c: full isolation in one commit"
   git push
   ```

4. Open the ArgoCD UI and watch the new Application appear.

5. Verify isolation:
   ```bash
   kubectl exec -n tenant-c curl-client -- \
     curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
     http://web.tenant-b.svc.cluster.local
   # Expected: 000 (timeout — blocked by CiliumNetworkPolicy)
   ```
```

---

## 8. Open Questions

~~**OQ-1 -- ArgoCD repo access from KinD.**~~ **RESOLVED:** Use GitHub. Assume internet connectivity is available at the venue. If unreliable, pre-configure ArgoCD with a GitHub personal access token as a fallback.

~~**OQ-2 -- ArgoCD poll interval for Scene 3.**~~ **RESOLVED:** Reduce poll interval to 30 seconds via `argocd-cm`:
```yaml
data:
  timeout.reconciliation: "30s"
```
This is fast enough for the demo without requiring manual refresh commands. The increased load on the controller and GitHub API is negligible for a KinD demo with three tenants.

~~**OQ-3 -- The `staging/` vs pre-prepared branch approach for Scene 3.**~~ **RESOLVED:** Use the `staging/` directory approach. The `staging/` directory is committed to the repo. During the demo, the presenter runs `cp -r staging/tenant-c tenants/tenant-c && git add && git commit && git push`. Simpler and more visually clear than cherry-picking from a branch.

~~**OQ-4 -- Reset commit pollution.**~~ **RESOLVED:** Accept it. Stay on `main` for both rehearsal and the real demo. Reset commits are clearly labeled (`"reset: remove tenant-c for demo re-run"`) and harmless. They also serve as documentation of the rehearsal process.

~~**OQ-5 -- ApplicationSet `preserveResourcesOnDeletion`.**~~ **RESOLVED:** Use default `false` (do not set `preserveResourcesOnDeletion`). For a demo, auto-cleanup on directory removal is acceptable. The KinD cluster can always be rebuilt from scratch if needed. This also simplifies the reset workflow -- removing `tenant-c` from git automatically cleans up the cluster resources.

**OQ-6 -- Scene 3 timing with `argocd app list --refresh`.**
The `argocd app list --refresh` command refreshes all Applications but may not immediately trigger an ApplicationSet re-evaluation. The correct command to force an ApplicationSet refresh may be:
```bash
kubectl annotate applicationset tenant-onboarding -n argocd \
  argocd.argoproj.io/refresh=normal --overwrite
```
Verify the exact mechanism during rehearsal. With the poll interval reduced to 30s (OQ-2), manual refresh may not be necessary.

**OQ-7 -- Rogue Application in Scene 2.**
The current design applies the rogue Application via `kubectl apply` rather than via a git commit. This is faster and more reliable for a live demo, but it means the audience does not see the "git-as-the-interface" pattern for the attack. An alternative is to pre-stage the rogue Application in the repo and show ArgoCD rejecting it during sync. This would make the Scene 2 demo more GitOps-native but adds complexity. Decide during rehearsal.