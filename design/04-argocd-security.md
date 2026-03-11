# Design Document 04: ArgoCD Security Progression

**Talk:** Network Segmentation at Scale — ArgoCon EU 2026
**Scope:** ArgoCD configuration at each stage of the demo, from insecure defaults to fully isolated multi-tenant RBAC with sync impersonation
**ArgoCD Version:** 3.3.3 (chart 9.4.9; sync impersonation available since 2.10, mature in 3.x)
**Scenes Covered:** Prologue (Stage 0), Scene 2 (Stage 2), Scene 3 (Stage 3), Scene 4 (Stage 4)

---

## Table of Contents

1. [Stage 0 — Default Project (Insecure Baseline)](#stage-0--default-project-insecure-baseline)
2. [Stage 2 — Per-Tenant ArgoCD Projects + RBAC](#stage-2--per-tenant-argocd-projects--rbac)
3. [Stage 3 — ApplicationSet for Automated Tenant Onboarding](#stage-3--applicationset-for-automated-tenant-onboarding)
4. [Stage 4 — Sync Impersonation](#stage-4--sync-impersonation-argocd-210)
5. [Version Pinning and Gotchas](#version-pinning-and-gotchas)
6. [Open Questions](#open-questions)

---

## Stage 0 — Default Project (Insecure Baseline)

**Talk scene:** Prologue + Scene 2 opening
**Purpose:** Demonstrate that ArgoCD's out-of-the-box configuration provides zero tenant isolation at the deployment plane.

### The Problem

When ArgoCD is installed, it creates a single `default` AppProject. This project permits:

- Deployments to **any namespace** on **any cluster**
- Pulling from **any source repository**
- Creation of **any resource type**, including cluster-scoped resources

All tenants share this project. There is no boundary between what tenant-a and tenant-b can deploy.

### Default AppProject Manifest
<!-- STATUS: REVIEWED -->

This is what ships with ArgoCD out of the box:

```yaml
# This is the BUILT-IN default project — you do not create this; ArgoCD ships it.
# Shown here to make explicit what "no restrictions" looks like.
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: default
  namespace: argocd
spec:
  # Allow deployments to ANY namespace on ANY cluster
  destinations:
    - namespace: "*"
      server: "*"

  # Allow pulling from ANY git repo or Helm chart repo
  sourceRepos:
    - "*"

  # No cluster-scoped resource restrictions (implicit: all allowed)
  clusterResourceWhitelist:
    - group: "*"
      kind: "*"
```

### Demo Scenario: Cross-Tenant Deployment Attack
<!-- STATUS: REVIEWED -->

The Rogue Tenant (tenant-a) creates an Application that deploys a workload into tenant-b's namespace. Because everyone shares the `default` project, this succeeds.

**Attacker Application — tenant-a deploys into tenant-b's namespace:**

```yaml
# manifests/stage-0/applications/rogue-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rogue-deployment
  namespace: argocd
spec:
  project: default  # <-- shared project, no restrictions
  source:
    repoURL: https://github.com/argo-multiverse-labs/argoconeu26.git
    targetRevision: HEAD
    path: demo-apps/rogue-workload
  destination:
    server: https://kubernetes.default.svc
    namespace: tenant-b  # <-- deploying into ANOTHER tenant's namespace
  syncPolicy:
    automated:
      selfHeal: true
```

**The rogue workload it deploys (a simple pod in tenant-b's namespace):**

```yaml
# demo-apps/rogue-workload/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rogue-implant
  namespace: tenant-b
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rogue-implant
  template:
    metadata:
      labels:
        app: rogue-implant
    spec:
      containers:
        - name: rogue
          image: curlimages/curl:8.7.1
          command: ["sleep", "infinity"]
```

**Expected result at Stage 0:** The Application syncs successfully. `rogue-implant` is running in the `tenant-b` namespace. This is the problem.

**Demo validation:**

```bash
# Create the rogue Application
kubectl apply -f manifests/stage-0/applications/rogue-app.yaml

# Wait for sync
until kubectl get application -n argocd rogue-deployment -o jsonpath='{.status.sync.status}' 2>/dev/null | grep -q "Synced"; do sleep 2; done

# Verify the rogue pod is running in tenant-b (this SHOULD NOT be possible)
kubectl get pods -n tenant-b -l app=rogue-implant
# NAME                              READY   STATUS    RESTARTS   AGE
# rogue-implant-xxxxx-xxxxx         1/1     Running   0          10s
```

**Additionally — cluster-scoped resource escalation:**

A tenant in the default project can also create ClusterRoleBindings to grant themselves admin access across namespaces:

```yaml
# demo-apps/rogue-workload/cluster-rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rogue-tenant-escalation
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: default
    namespace: tenant-a
```

This succeeds because the default project has no `clusterResourceWhitelist` restrictions (wildcard allows everything).

---

## Stage 2 — Per-Tenant ArgoCD Projects + RBAC

**Talk scene:** Scene 2
**Purpose:** Introduce ArgoCD Projects as the orchestration-layer boundary. Each tenant gets their own project scoped to their namespaces, repos, and permitted resource types. Combined with RBAC, tenants have self-service within their boundary and cannot see or modify other projects.

### Per-Tenant AppProject Manifests
<!-- STATUS: REVIEWED -->

**Tenant-A Project:**

```yaml
# manifests/stage-2/projects/tenant-a-project.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: tenant-a
  namespace: argocd
spec:
  description: "Project for Tenant A — scoped to tenant-a namespace only"

  # DESTINATIONS: tenant-a can ONLY deploy to the tenant-a namespace
  # on the local cluster. This is the most commonly misconfigured field.
  destinations:
    - namespace: tenant-a
      server: https://kubernetes.default.svc

  # SOURCE REPOS: tenant-a can ONLY deploy from their own repo(s)
  sourceRepos:
    - https://github.com/argo-multiverse-labs/argoconeu26.git

  # CLUSTER-SCOPED RESOURCES: tenant-a CANNOT create any cluster-scoped
  # resources. This prevents ClusterRoleBinding escalation attacks.
  clusterResourceWhitelist: []

  # NAMESPACE-SCOPED RESOURCES: explicitly allow only what tenants need.
  # This is an allowlist — anything not listed is denied.
  namespaceResourceWhitelist:
    - group: ""
      kind: ConfigMap
    - group: ""
      kind: Secret
    - group: ""
      kind: Service
    - group: ""
      kind: ServiceAccount
    - group: apps
      kind: Deployment
    - group: apps
      kind: StatefulSet
    - group: apps
      kind: ReplicaSet
    - group: networking.k8s.io
      kind: Ingress
    - group: networking.k8s.io
      kind: NetworkPolicy

  # DENY creating CiliumNetworkPolicies — only the platform team
  # should manage network segmentation. This is enforced via the
  # allowlist above: CiliumNetworkPolicy is simply not listed.

  # ROLES: project-scoped roles for tenant self-service (see RBAC below)
  roles:
    - name: tenant-admin
      description: "Full access within the tenant-a project"
      policies:
        - p, proj:tenant-a:tenant-admin, applications, *, tenant-a/*, allow
        - p, proj:tenant-a:tenant-admin, logs, get, tenant-a/*, allow
      groups:
        - tenant-a-team
```

**Tenant-B Project:**

```yaml
# manifests/stage-2/projects/tenant-b-project.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: tenant-b
  namespace: argocd
spec:
  description: "Project for Tenant B — scoped to tenant-b namespace only"

  destinations:
    - namespace: tenant-b
      server: https://kubernetes.default.svc

  sourceRepos:
    - https://github.com/argo-multiverse-labs/argoconeu26.git

  clusterResourceWhitelist: []

  namespaceResourceWhitelist:
    - group: ""
      kind: ConfigMap
    - group: ""
      kind: Secret
    - group: ""
      kind: Service
    - group: ""
      kind: ServiceAccount
    - group: apps
      kind: Deployment
    - group: apps
      kind: StatefulSet
    - group: apps
      kind: ReplicaSet
    - group: networking.k8s.io
      kind: Ingress
    - group: networking.k8s.io
      kind: NetworkPolicy

  roles:
    - name: tenant-admin
      description: "Full access within the tenant-b project"
      policies:
        - p, proj:tenant-b:tenant-admin, applications, *, tenant-b/*, allow
        - p, proj:tenant-b:tenant-admin, logs, get, tenant-b/*, allow
      groups:
        - tenant-b-team
```

**Lock down the default project (prevent anyone from using it):**

```yaml
# manifests/stage-2/projects/default-project-locked.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: default
  namespace: argocd
spec:
  description: "Default project — locked down, do not use"

  # No destinations — nothing can be deployed via the default project
  destinations: []

  # No source repos
  sourceRepos: []

  # No cluster-scoped resources
  clusterResourceWhitelist: []
```

### RBAC Configuration (argocd-rbac-cm)
<!-- STATUS: REVIEWED -->

The RBAC ConfigMap controls who can do what in the ArgoCD API and UI. This is separate from the AppProject roles above — AppProject roles control what Applications within a project can do, while RBAC controls what users/groups can do in the ArgoCD API.

```yaml
# manifests/stage-2/argocd-config/argocd-rbac-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  # Default policy: deny everything. Users must be explicitly granted access.
  policy.default: role:none

  # Scopes controls which OIDC scopes to examine for group membership.
  # Default is '[groups]'.
  scopes: "[groups]"

  policy.csv: |
    # ============================================================
    # Platform Admin — full access to everything
    # ============================================================
    p, role:platform-admin, applications, *, */*, allow
    p, role:platform-admin, clusters, *, *, allow
    p, role:platform-admin, repositories, *, *, allow
    p, role:platform-admin, certificates, *, *, allow
    p, role:platform-admin, accounts, *, *, allow
    p, role:platform-admin, gpgkeys, *, *, allow
    p, role:platform-admin, logs, *, *, allow
    p, role:platform-admin, exec, *, */*, allow
    p, role:platform-admin, projects, *, *, allow

    g, platform-admins, role:platform-admin

    # ============================================================
    # Tenant A — can only see and manage their own project
    # ============================================================
    # Applications: full CRUD within tenant-a project only
    p, role:tenant-a-role, applications, get, tenant-a/*, allow
    p, role:tenant-a-role, applications, create, tenant-a/*, allow
    p, role:tenant-a-role, applications, update, tenant-a/*, allow
    p, role:tenant-a-role, applications, delete, tenant-a/*, allow
    p, role:tenant-a-role, applications, sync, tenant-a/*, allow
    p, role:tenant-a-role, applications, action/*, tenant-a/*, allow

    # Logs: can view logs for their own applications
    p, role:tenant-a-role, logs, get, tenant-a/*, allow

    # Projects: can view (but not modify) their own project
    p, role:tenant-a-role, projects, get, tenant-a, allow

    # Repositories: can view repos (needed for Application creation)
    p, role:tenant-a-role, repositories, get, *, allow

    # Map the tenant-a-team group to this role
    g, tenant-a-team, role:tenant-a-role

    # ============================================================
    # Tenant B — identical structure, scoped to tenant-b project
    # ============================================================
    p, role:tenant-b-role, applications, get, tenant-b/*, allow
    p, role:tenant-b-role, applications, create, tenant-b/*, allow
    p, role:tenant-b-role, applications, update, tenant-b/*, allow
    p, role:tenant-b-role, applications, delete, tenant-b/*, allow
    p, role:tenant-b-role, applications, sync, tenant-b/*, allow
    p, role:tenant-b-role, applications, action/*, tenant-b/*, allow
    p, role:tenant-b-role, logs, get, tenant-b/*, allow
    p, role:tenant-b-role, projects, get, tenant-b, allow
    p, role:tenant-b-role, repositories, get, *, allow

    g, tenant-b-team, role:tenant-b-role
```

**Key points about the RBAC format:**

- `p, <role>, <resource>, <action>, <object>, allow/deny` defines a policy
- For applications, `<object>` is `<project>/<application-name-or-wildcard>`
- `g, <group>, <role>` maps a group (from OIDC/SSO) to a role
- `policy.default: role:none` ensures unauthenticated or unmapped users have zero access

### Before/After: Cross-Tenant Deployment Attempt
<!-- STATUS: REVIEWED -->

**The same rogue Application from Stage 0, but now assigned to the tenant-a project:**

```yaml
# manifests/stage-2/applications/rogue-app-blocked.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rogue-deployment
  namespace: argocd
spec:
  project: tenant-a  # <-- now uses per-tenant project
  source:
    repoURL: https://github.com/argo-multiverse-labs/argoconeu26.git
    targetRevision: HEAD
    path: demo-apps/rogue-workload
  destination:
    server: https://kubernetes.default.svc
    namespace: tenant-b  # <-- still trying to deploy into tenant-b
  syncPolicy:
    automated:
      selfHeal: true
```

**Expected result at Stage 2:** ArgoCD REJECTS this Application. The error message will be:

```
application destination {https://kubernetes.default.svc tenant-b} is not permitted
in project 'tenant-a'
```

**Demo validation:**

```bash
# Apply the rogue Application (it will be created but will fail to sync)
kubectl apply -f manifests/stage-2/applications/rogue-app-blocked.yaml

# Check the Application status — it should show an error
kubectl get application -n argocd rogue-deployment -o jsonpath='{.status.conditions[*].message}'; echo
# application destination {https://kubernetes.default.svc tenant-b}
# is not permitted in project 'tenant-a'

# Verify no rogue pod exists in tenant-b
kubectl get pods -n tenant-b -l app=rogue-implant
# No resources found in tenant-b namespace.

# Clean up
kubectl delete application -n argocd rogue-deployment
```

**Cluster-scoped resource escalation is also blocked:**

If a tenant tries to create a ClusterRoleBinding through their Application, ArgoCD rejects it because `clusterResourceWhitelist` is empty:

```
resource ClusterRoleBinding is not permitted in project 'tenant-a'
```

### What This Achieves

| Control | Before (Stage 0) | After (Stage 2) |
|---------|-------------------|------------------|
| Namespace targeting | Any namespace | Tenant's own namespace only |
| Source repos | Any repo | Tenant's designated repos only |
| Cluster-scoped resources | All allowed | None allowed (empty whitelist) |
| Namespace-scoped resources | All allowed | Explicit allowlist only |
| RBAC visibility | All projects visible | Own project only |
| RBAC modification | Anyone can modify anything | Self-service within project boundary |

---

## Stage 3 — ApplicationSet for Automated Tenant Onboarding

**Talk scene:** Scene 3
**Purpose:** Replace manual per-tenant Project/RBAC/CNP creation with an ApplicationSet that provisions a full tenant stack from a single git commit. One commit = one tenant fully onboarded.

### Generator Pattern: Git Directory Generator

The git directory generator is the best fit for this use case. Each tenant gets a directory in the repo. Adding a new directory (with a tenant config file) triggers ArgoCD to generate the full stack.

**Repository structure for tenant onboarding:**

```
tenants/
  tenant-a/
    config.json          # Tenant metadata (name, team, allowed repos)
    kustomization.yaml   # Kustomize overlay for tenant-specific resources
    workloads/           # Tenant application manifests
  tenant-b/
    config.json
    kustomization.yaml
    workloads/
  tenant-c/             # <-- adding this directory triggers full onboarding
    config.json
    kustomization.yaml
    workloads/
```

**Tenant config file (`config.json`):**

```json
{
  "tenantName": "tenant-c",
  "team": "tenant-c-team",
  "namespace": "tenant-c",
  "sourceRepos": [
    "https://github.com/argo-multiverse-labs/argoconeu26.git"
  ]
}
```

### ApplicationSet Manifest
<!-- STATUS: REVIEWED -->

This single ApplicationSet provisions the entire tenant stack. It uses the git directory generator to discover tenant directories and templates out an Application per tenant that deploys their full stack (Project, RBAC, CNPs, workloads).

```yaml
# manifests/stage-3/applicationsets/tenant-onboarding.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: tenant-onboarding
  namespace: argocd
spec:
  generators:
    # Git directory generator: discovers tenant directories
    - git:
        repoURL: https://github.com/argo-multiverse-labs/argoconeu26.git
        revision: HEAD
        directories:
          - path: tenants/*

  template:
    metadata:
      name: "tenant-stack-{{path.basename}}"
      namespace: argocd
      labels:
        app.kubernetes.io/part-of: tenant-onboarding
        tenant: "{{path.basename}}"
    spec:
      # IMPORTANT: The onboarding ApplicationSet itself runs in a
      # platform-admin project with broad permissions, because it
      # needs to create AppProjects and namespace-level RBAC.
      project: platform-admin

      source:
        repoURL: https://github.com/argo-multiverse-labs/argoconeu26.git
        targetRevision: HEAD
        path: "{{path}}"

      destination:
        server: https://kubernetes.default.svc
        # Each tenant's resources are applied to their namespace.
        # The AppProject and RBAC resources within the tenant stack
        # target the argocd namespace and cluster scope respectively —
        # those are handled by the Kustomize overlay.
        namespace: "{{path.basename}}"

      syncPolicy:
        automated:
          selfHeal: true
          prune: true
        syncOptions:
          - CreateNamespace=true
          - PruneLast=true

      # Allow this Application to manage resources in multiple namespaces
      # (the tenant namespace + argocd namespace for the AppProject)
      ignoreDifferences:
        - group: argoproj.io
          kind: AppProject
          jsonPointers:
            - /spec/roles
```

### What Each Tenant Directory Contains

Each tenant directory uses Kustomize to produce the full tenant stack. A single `kustomization.yaml` references all the resources:

```yaml
# tenants/tenant-c/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: tenant-c

resources:
  # ArgoCD Project for this tenant
  - project.yaml
  # Kubernetes RBAC (Role + RoleBinding)
  - rbac.yaml
  # CiliumNetworkPolicy: default-deny + tenant-specific allows
  - network-policies.yaml
  # Tenant workloads
  - workloads/
```

**Tenant ArgoCD Project (templated per tenant):**

```yaml
# tenants/tenant-c/project.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: tenant-c
  namespace: argocd  # AppProjects always live in the argocd namespace
spec:
  description: "Auto-provisioned project for tenant-c"

  destinations:
    - namespace: tenant-c
      server: https://kubernetes.default.svc

  sourceRepos:
    - https://github.com/argo-multiverse-labs/argoconeu26.git

  clusterResourceWhitelist: []

  namespaceResourceWhitelist:
    - group: ""
      kind: ConfigMap
    - group: ""
      kind: Secret
    - group: ""
      kind: Service
    - group: ""
      kind: ServiceAccount
    - group: apps
      kind: Deployment
    - group: apps
      kind: StatefulSet
    - group: apps
      kind: ReplicaSet
    - group: networking.k8s.io
      kind: Ingress
    - group: networking.k8s.io
      kind: NetworkPolicy

  roles:
    - name: tenant-admin
      description: "Full access within the tenant-c project"
      policies:
        - p, proj:tenant-c:tenant-admin, applications, *, tenant-c/*, allow
        - p, proj:tenant-c:tenant-admin, logs, get, tenant-c/*, allow
      groups:
        - tenant-c-team
```

**Tenant RBAC (Kubernetes Role + RoleBinding):**

```yaml
# tenants/tenant-c/rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tenant-c-sa
  namespace: tenant-c
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-c-role
  namespace: tenant-c
rules:
  - apiGroups: ["", "apps", "batch"]
    resources: ["pods", "deployments", "services", "configmaps", "secrets",
                "statefulsets", "replicasets", "jobs"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Tenants can VIEW their CiliumNetworkPolicies but NOT modify them
  - apiGroups: ["cilium.io"]
    resources: ["ciliumnetworkpolicies"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-c-rolebinding
  namespace: tenant-c
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: tenant-c-role
subjects:
  - kind: ServiceAccount
    name: tenant-c-sa
    namespace: tenant-c
```

**Tenant CiliumNetworkPolicies (default-deny + allows):**

```yaml
# tenants/tenant-c/network-policies.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: tenant-c-default-deny
  namespace: tenant-c
spec:
  endpointSelector: {}
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: tenant-c
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: tenant-c
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
          rules:
            dns:
              - matchPattern: "*"
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: tenant-c-shared-services-access
  namespace: tenant-c
spec:
  endpointSelector: {}
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: shared-services
            app: config-api
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: GET
                path: "/api/.*"
```

### Platform-Admin Project
<!-- STATUS: REVIEWED -->

The ApplicationSet itself needs to run in a project with broad permissions to create AppProjects and resources across tenant namespaces:

```yaml
# manifests/stage-3/projects/platform-admin-project.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform-admin
  namespace: argocd
spec:
  description: "Platform admin project — used by tenant onboarding ApplicationSet"

  destinations:
    # Can target any tenant namespace (for tenant stack resources)
    - namespace: "tenant-*"
      server: https://kubernetes.default.svc
    # Can target the argocd namespace (for AppProjects)
    - namespace: argocd
      server: https://kubernetes.default.svc

  sourceRepos:
    - https://github.com/argo-multiverse-labs/argoconeu26.git

  clusterResourceWhitelist: []

  namespaceResourceWhitelist:
    - group: "*"
      kind: "*"
```

### Onboarding a New Tenant

To onboard tenant-c, the platform engineer makes a single git commit:

```bash
# 1. Create the tenant directory from a template
cp -r tenants/_template tenants/tenant-c

# 2. Edit the config (tenant name, team, repos)
# ... edit tenants/tenant-c/config.json, project.yaml, rbac.yaml, etc.

# 3. Commit and push
git add tenants/tenant-c/
git commit -m "onboard tenant-c: project, rbac, cnps, workloads"
git push

# 4. ArgoCD detects the new directory via the git directory generator,
#    creates an Application "tenant-stack-tenant-c", and syncs it.
#    Within ~3 minutes (default poll interval), tenant-c has:
#    - A namespace (created by CreateNamespace=true)
#    - An ArgoCD AppProject scoped to their namespace
#    - Kubernetes RBAC (ServiceAccount, Role, RoleBinding)
#    - CiliumNetworkPolicies (default-deny + shared-service access)
```

### How This Solves Scene 3 Problems

| Problem | Solution |
|---------|----------|
| Copy-paste CNPs referencing wrong namespace | Templates generate correct namespace automatically |
| Missing default-deny on new namespaces | Default-deny CNP is part of every tenant stack |
| Manual Project creation does not scale | ApplicationSet generates Projects from git |
| Drift from `kubectl edit` | ArgoCD self-heal reverts out-of-band changes |
| No audit trail | Git history = complete audit trail with commit, reviewer, timestamp |

---

## Stage 4 — Sync Impersonation (ArgoCD 2.10+)

**Talk scene:** Scene 4
**Purpose:** Demonstrate that even with per-tenant Projects, ArgoCD's sync process runs with its own highly-privileged ServiceAccount. Sync impersonation constrains the controller to act as the tenant's ServiceAccount during sync.

### The Problem

ArgoCD's application controller uses its own ServiceAccount (`argocd-application-controller`) to apply resources to the cluster. This ServiceAccount typically has broad permissions (often `cluster-admin` or equivalent). Even though AppProjects restrict what Applications can target, the actual Kubernetes API calls during sync are made with the controller's identity, not the tenant's.

This creates two gaps:

1. **API-level gap:** If the AppProject configuration has a subtle misconfiguration (e.g., a wildcard in destinations), the controller's broad permissions mean resources get applied successfully. There is no secondary enforcement at the Kubernetes API level.

2. **Identity-level gap:** CiliumNetworkPolicies can be scoped to ServiceAccount identity. During sync, resources are created by the ArgoCD controller's ServiceAccount, not the tenant's. Identity-based policies that reference the tenant's ServiceAccount do not apply during the sync operation.

**Concrete attack scenario:**

A tenant crafts an Application that deploys a permissive CiliumNetworkPolicy into their own namespace (or, if destinations are misconfigured, into another tenant's namespace). Without impersonation, the ArgoCD controller has the RBAC permissions to create CiliumNetworkPolicies because it needs broad access. The AppProject `namespaceResourceWhitelist` blocks this at the ArgoCD level, but if CiliumNetworkPolicy is accidentally permitted (or the project is misconfigured), there is no Kubernetes-level enforcement.

With sync impersonation, the sync runs as the tenant's ServiceAccount. That ServiceAccount's Kubernetes RBAC explicitly denies CiliumNetworkPolicy creation (see the tenant RBAC in Stage 3 — tenants can only `get`, `list`, `watch` CNPs, not `create`, `update`, `delete`). This provides defense in depth.

### The Fix: Sync Impersonation Configuration

Sync impersonation is configured in three places:

1. **`argocd-cm` ConfigMap** — enable the feature globally
2. **AppProject spec** — specify which ServiceAccount to impersonate per project
3. **ServiceAccount RBAC** — ensure each tenant's ServiceAccount has appropriate (limited) permissions

#### Step 1: Enable Impersonation in argocd-cm
<!-- STATUS: REVIEWED -->

```yaml
# manifests/stage-4/argocd-config/argocd-cm.yaml (patch)
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  # Enable sync impersonation globally.
  # When enabled, the application controller will impersonate the
  # ServiceAccount specified in the Application or AppProject spec
  # when syncing resources to the target cluster.
  application.sync.impersonation.enabled: "true"
```

> **NOTE:** In ArgoCD 2.10-2.13, the setting key was `application.sync.impersonation.enabled`. Verify the exact key name against the documentation for the pinned ArgoCD version. See [Open Questions](#open-questions).

#### Step 2: Configure Impersonation in AppProject
<!-- STATUS: REVIEWED -->

Each tenant's AppProject specifies the ServiceAccount to impersonate during sync. This is set via the `spec.destinationServiceAccounts` field:

```yaml
# manifests/stage-4/projects/tenant-a-project-with-impersonation.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: tenant-a
  namespace: argocd
spec:
  description: "Project for Tenant A — with sync impersonation"

  destinations:
    - namespace: tenant-a
      server: https://kubernetes.default.svc

  sourceRepos:
    - https://github.com/argo-multiverse-labs/argoconeu26.git

  clusterResourceWhitelist: []

  namespaceResourceWhitelist:
    - group: ""
      kind: ConfigMap
    - group: ""
      kind: Secret
    - group: ""
      kind: Service
    - group: ""
      kind: ServiceAccount
    - group: apps
      kind: Deployment
    - group: apps
      kind: StatefulSet
    - group: apps
      kind: ReplicaSet
    - group: networking.k8s.io
      kind: Ingress
    - group: networking.k8s.io
      kind: NetworkPolicy

  # SYNC IMPERSONATION: specify the ServiceAccount to use when
  # syncing Applications that target each destination.
  destinationServiceAccounts:
    - server: https://kubernetes.default.svc
      namespace: tenant-a
      defaultServiceAccount: tenant-a-sa

  roles:
    - name: tenant-admin
      description: "Full access within the tenant-a project"
      policies:
        - p, proj:tenant-a:tenant-admin, applications, *, tenant-a/*, allow
        - p, proj:tenant-a:tenant-admin, logs, get, tenant-a/*, allow
      groups:
        - tenant-a-team
```

The key addition is `spec.destinationServiceAccounts`. This tells ArgoCD: "When syncing any Application in the tenant-a project that targets the tenant-a namespace, impersonate the `tenant-a-sa` ServiceAccount."

#### Step 3: Grant the ArgoCD Controller Permission to Impersonate
<!-- STATUS: REVIEWED -->

The ArgoCD application controller needs Kubernetes RBAC permission to impersonate tenant ServiceAccounts. Create a ClusterRole and ClusterRoleBinding:

```yaml
# manifests/stage-4/rbac/impersonation-clusterrole.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argocd-application-controller-impersonate
rules:
  # Allow the ArgoCD controller to impersonate ServiceAccounts
  # in tenant namespaces
  - apiGroups: [""]
    resources: ["serviceaccounts"]
    verbs: ["impersonate"]
    # Optionally restrict to specific ServiceAccount names:
    # resourceNames: ["tenant-a-sa", "tenant-b-sa", "tenant-c-sa"]
  # Allow impersonating groups (needed if the SA has group memberships)
  - apiGroups: [""]
    resources: ["groups"]
    verbs: ["impersonate"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-application-controller-impersonate
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: argocd-application-controller-impersonate
subjects:
  - kind: ServiceAccount
    name: argocd-application-controller
    namespace: argocd
```

#### Step 4: Tenant ServiceAccount RBAC (Already Done in Stage 3)

The tenant ServiceAccounts created in Stage 3 already have the correct RBAC. The key constraints:

- **CAN** create/update/delete: Deployments, Services, ConfigMaps, Secrets, etc.
- **CANNOT** create/update/delete: CiliumNetworkPolicies (only get/list/watch)
- **CANNOT** create any cluster-scoped resources

This means when ArgoCD impersonates `tenant-a-sa` to sync an Application, the sync will fail if the Application tries to create a CiliumNetworkPolicy, because the ServiceAccount lacks permission.

### Config Diff: Before and After Impersonation

**Before (Stage 2 AppProject):**

```yaml
spec:
  destinations:
    - namespace: tenant-a
      server: https://kubernetes.default.svc
  # No destinationServiceAccounts — syncs run as argocd-application-controller
```

**After (Stage 4 AppProject):**

```yaml
spec:
  destinations:
    - namespace: tenant-a
      server: https://kubernetes.default.svc
  # NEW: syncs impersonate the tenant's ServiceAccount
  destinationServiceAccounts:
    - server: https://kubernetes.default.svc
      namespace: tenant-a
      defaultServiceAccount: tenant-a-sa
```

**Before (argocd-cm):**

```yaml
data:
  # No impersonation setting — feature is disabled by default
```

**After (argocd-cm):**

```yaml
data:
  application.sync.impersonation.enabled: "true"
```

### Updated ApplicationSet Template for Stage 4

The tenant onboarding ApplicationSet from Stage 3 should be updated to include `destinationServiceAccounts` in the templated AppProject:

```yaml
# tenants/tenant-c/project.yaml (updated for Stage 4)
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: tenant-c
  namespace: argocd
spec:
  description: "Auto-provisioned project for tenant-c"

  destinations:
    - namespace: tenant-c
      server: https://kubernetes.default.svc

  sourceRepos:
    - https://github.com/argo-multiverse-labs/argoconeu26.git

  clusterResourceWhitelist: []

  namespaceResourceWhitelist:
    - group: ""
      kind: ConfigMap
    - group: ""
      kind: Secret
    - group: ""
      kind: Service
    - group: ""
      kind: ServiceAccount
    - group: apps
      kind: Deployment
    - group: apps
      kind: StatefulSet
    - group: apps
      kind: ReplicaSet
    - group: networking.k8s.io
      kind: Ingress
    - group: networking.k8s.io
      kind: NetworkPolicy

  # Stage 4 addition: sync impersonation
  destinationServiceAccounts:
    - server: https://kubernetes.default.svc
      namespace: tenant-c
      defaultServiceAccount: tenant-c-sa

  roles:
    - name: tenant-admin
      description: "Full access within the tenant-c project"
      policies:
        - p, proj:tenant-c:tenant-admin, applications, *, tenant-c/*, allow
        - p, proj:tenant-c:tenant-admin, logs, get, tenant-c/*, allow
      groups:
        - tenant-c-team
```

### Interaction with ServiceAccount-Scoped CiliumNetworkPolicies

CiliumNetworkPolicies can use `fromEndpoints` with ServiceAccount labels to scope policies by identity. When sync impersonation is enabled, the pods created during sync are associated with the tenant's ServiceAccount (since the resources are created by that SA). This means:

```yaml
# Example: CiliumNetworkPolicy allowing traffic only from pods
# running under a specific ServiceAccount
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: tenant-a-identity-policy
  namespace: tenant-a
spec:
  endpointSelector:
    matchLabels:
      app: internal-api
  ingress:
    - fromEndpoints:
        - matchLabels:
            # Cilium tracks ServiceAccount identity via these labels
            io.cilium.k8s.policy.serviceaccount: tenant-a-sa
            io.kubernetes.pod.namespace: tenant-a
```

Without sync impersonation, the ServiceAccount identity during sync is `argocd-application-controller` in the `argocd` namespace, which does not match the policy selector. With sync impersonation, the created pods run under `tenant-a-sa`, and the identity-based policy applies correctly.

> **IMPORTANT:** The ServiceAccount identity on the pod's `spec.serviceAccountName` is set by the Deployment manifest, not by who creates the Deployment. Sync impersonation affects who makes the API call to create/update the Deployment, not the pod's runtime identity. The identity-level framing is therefore about ensuring that the API-level caller is constrained, not about changing the pod's runtime ServiceAccount. See [Open Questions](#open-questions) for further discussion.

### Demo Validation for Stage 4

```bash
# 1. Attempt to deploy a permissive CiliumNetworkPolicy via an Application
#    (add this to the tenant's workload directory)
cat > demo-apps/rogue-cnp/allow-all.yaml << 'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-all-rogue
  namespace: tenant-a
spec:
  endpointSelector: {}
  ingress:
    - {}
  egress:
    - {}
EOF

# 2. Create an Application that tries to sync this CNP
cat > /tmp/rogue-cnp-app.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rogue-cnp-attempt
  namespace: argocd
spec:
  project: tenant-a
  source:
    repoURL: https://github.com/argo-multiverse-labs/argoconeu26.git
    targetRevision: HEAD
    path: demo-apps/rogue-cnp
  destination:
    server: https://kubernetes.default.svc
    namespace: tenant-a
  syncPolicy:
    automated:
      selfHeal: true
EOF

kubectl apply -f /tmp/rogue-cnp-app.yaml

# 3. Without impersonation: the sync would be blocked by the AppProject
#    namespaceResourceWhitelist (CiliumNetworkPolicy is not listed).
#    But IF it were listed, the controller's broad permissions would
#    allow the CNP to be created.
#
#    With impersonation: even if the AppProject allowed CNPs, the
#    tenant-a-sa ServiceAccount lacks RBAC to create CiliumNetworkPolicies.
#    The sync fails with a Kubernetes RBAC error:
#
#    CONDITION: ComparisonError
#    MESSAGE:   serviceaccounts "tenant-a-sa" is not allowed to create
#               resource "ciliumnetworkpolicies" in API group "cilium.io"
#               in the namespace "tenant-a"

# 4. Check the sync status
kubectl get application -n argocd rogue-cnp-attempt -o jsonpath='{.status.conditions[*].message}'; echo
# Shows sync failed due to impersonation RBAC denial
```

---

## Version Pinning and Gotchas

### ArgoCD Version

- **Minimum version:** 2.10 (sync impersonation introduced)
- **Recommended version:** 3.3.3 (latest stable as of early 2026)
- **Helm chart:** `argo/argo-cd` chart version should be pinned (e.g., `9.4.9` for ArgoCD 3.3.3)

### Known Gotchas

| Issue | Impact | Mitigation |
|-------|--------|------------|
| `destinationServiceAccounts` requires ArgoCD 2.10+ | Feature does not exist in older versions | Pin ArgoCD >= 2.10 |
| The `application.sync.impersonation.enabled` key name may vary by version | Wrong key = feature silently disabled | Verify against release notes for the exact pinned version |
| AppProject `destinations` with wildcards (`namespace: "*"`) bypass all namespace restrictions | Tenants can deploy anywhere if wildcard is present | Never use wildcards in tenant projects; only in platform-admin |
| `clusterResourceWhitelist: []` (empty list) denies all cluster-scoped resources, but omitting the field entirely allows all | Subtle YAML difference between empty list and missing field | Always explicitly set `clusterResourceWhitelist: []` |
| ApplicationSet `preserveResourcesOnDeletion` prevents cleanup if a tenant directory is removed | Orphaned resources remain in the cluster | Document the manual cleanup process; consider setting to `false` in dev environments |
| RBAC `policy.default` must be explicitly set to `role:none` | Default is `role:readonly` in some ArgoCD versions, which leaks visibility across projects | Always set explicitly |
| Impersonation ClusterRole must allow impersonating ServiceAccounts across all tenant namespaces | Missing permission causes all syncs to fail | Test with a single tenant before rolling out to all |
| When using `CreateNamespace=true` in the ApplicationSet, the namespace is created by the controller SA, not the impersonated SA | Namespace creation happens before impersonation takes effect | Pre-create namespaces via a separate platform-admin Application, or accept that namespace creation uses controller permissions |

### ArgoCD Helm Chart Values for Impersonation

When installing ArgoCD via Helm, enable impersonation in the values:

```yaml
# manifests/stage-4/argocd-helm-values.yaml (relevant section)
configs:
  cm:
    application.sync.impersonation.enabled: "true"

  rbac:
    policy.default: role:none
    scopes: "[groups]"
    policy.csv: |
      # ... (same RBAC policy.csv as shown in Stage 2)
```

---

## Open Questions

1. **Exact `argocd-cm` key for sync impersonation.** The feature was introduced in ArgoCD 2.10. The configuration key is documented as `application.sync.impersonation.enabled`, but this should be verified against the exact pinned ArgoCD version's release notes. Some early implementations used different key paths. **Action:** Verify with `argocd version` and the corresponding release documentation before finalizing manifests.

We will run the latest ArgoCD 3.3

2. **Identity-level vs API-level framing for Scene 4.** The talk outline flags this as needing Christian's input. The API-level framing (impersonation constrains what resources the controller can create/update during sync) is straightforward and provably correct. The identity-level framing (CiliumNetworkPolicies scoped to ServiceAccount identity) is more nuanced: sync impersonation changes who makes the API call, but a pod's runtime ServiceAccount is set by `spec.serviceAccountName` in the Deployment manifest, not by who created the Deployment. The identity framing may only fully apply if the CiliumNetworkPolicy references the creator's identity (the API caller), which is not standard Cilium behavior. **Recommendation:** Use the API-level framing for the talk; mention the identity angle as a secondary benefit if Christian confirms it holds up.

Recommendation is correct

3. **Namespace creation with impersonation.** When `CreateNamespace=true` is used in the ApplicationSet sync options, the namespace is created before impersonation takes effect (the controller creates it with its own SA). If the demo needs to show that even namespace creation is scoped, namespaces should be pre-created by a platform-admin Application. **Action:** Decide whether to pre-create namespaces or accept that namespace creation uses controller permissions.

Please review/verify

4. **`destinationServiceAccounts` field availability.** This field was introduced alongside sync impersonation in ArgoCD 2.10. Confirm it is present in the AppProject CRD for the pinned version. If it was added in a later minor version (e.g., 2.11 or 2.12), adjust the minimum version requirement. **Action:** Check the ArgoCD changelog for the exact version that introduced `spec.destinationServiceAccounts`.

5. **Platform-admin project scope.** The `platform-admin` project uses `namespace: "tenant-*"` as a wildcard destination. Verify that ArgoCD supports glob patterns in `spec.destinations[].namespace`. If not, each tenant namespace must be listed explicitly (which defeats the purpose of automated onboarding). **Action:** Test wildcard namespace support in the pinned ArgoCD version. ArgoCD does support `*` as a wildcard in destination namespaces, but confirm that `tenant-*` prefix matching works as expected (it should, as ArgoCD uses glob matching for this field).

6. **RBAC policy.csv generation for new tenants.** The `argocd-rbac-cm` ConfigMap needs to be updated when new tenants are onboarded (to add their role and group mapping). The ApplicationSet-generated AppProject includes project-scoped roles, but the global RBAC ConfigMap is a separate resource. Options: (a) manage `argocd-rbac-cm` via a separate Application that aggregates all tenant roles, (b) use only project-scoped roles (defined in `spec.roles`) and avoid global RBAC per tenant, or (c) use ArgoCD's RBAC policy from a ConfigMap that references project roles. **Recommendation:** Use project-scoped roles (`spec.roles` in the AppProject) for tenant access, which avoids the need to update the global ConfigMap for each tenant. The global ConfigMap only needs the platform-admin role and the default deny policy.

7. **Demo simplification for SSO/auth.** The RBAC configuration assumes OIDC/SSO with group claims. For the KinD demo, ArgoCD will likely use local accounts or the admin account. The RBAC policies will still be applied and visible in the manifests, but the actual authentication flow (proving that tenant-a-team cannot see tenant-b's project) requires either (a) setting up a local OIDC provider (e.g., Dex with static users), (b) using ArgoCD local accounts with group assignments, or (c) simply showing the RBAC configuration and explaining it without a live auth demo. **Recommendation:** Use ArgoCD local accounts for the demo (configured in `argocd-cm`) and show the RBAC deny in the CLI/API rather than the UI login flow.
