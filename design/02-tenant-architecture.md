# 02 - Application and Tenant Architecture

**Document:** Tenant workloads, shared services, ArgoCD Applications/Projects, and ApplicationSet design
**Talk:** Network Segmentation at Scale: GitOps-Driven Multi-Tenant Isolation With Argo CD
**Conference:** ArgoCon EU 2026

---

## 1. Namespace Layout

Six namespaces are required. Four exist from initial cluster bootstrap; the remaining two are created dynamically during the demo.

| Namespace | Purpose | Created |
|-----------|---------|---------|
| `argocd` | ArgoCD control plane | Cluster bootstrap |
| `shared-services` | Config API service used by all tenants (L7 demo target) | Cluster bootstrap |
| `tenant-a` | Platform Engineer's "legitimate" tenant | Cluster bootstrap |
| `tenant-b` | Rogue Tenant's team namespace | Cluster bootstrap |
| `tenant-c` | Dynamically created by ApplicationSet in Scene 3 | Scene 3 (git commit) |
| `kube-system` | Cilium, Hubble, system components | Exists by default |

Namespace manifests are straightforward. Each tenant namespace carries a label used for network policy identity:

```yaml
# namespaces/tenant-a.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-a
  labels:
    tenant: tenant-a
    environment: demo
```

```yaml
# namespaces/tenant-b.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-b
  labels:
    tenant: tenant-b
    environment: demo
```

```yaml
# namespaces/shared-services.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shared-services
  labels:
    role: shared-services
    environment: demo
```

The `tenant: <name>` label is critical -- CiliumNetworkPolicies use `matchLabels` on namespace selectors to scope ingress/egress rules per tenant.

---

## 2. Tenant Workloads

Each tenant runs two lightweight services. The workloads exist solely to demonstrate network connectivity (and the blocking of it). They must support `curl` from within pods.

### 2.1 Workload Design

**Choice: nginx with a custom default page + curl installed.**

Rationale:
- Lighter than httpbin (no Python runtime).
- Simpler than a custom Go app (no build step, no container registry).
- nginx serves HTTP on port 80, responds to any path with 200, making it easy to test connectivity.
- The `curlimages/curl` sidecar or `exec` into nginx with curl handles client-side testing.

However, stock nginx images do not include curl. Two options:

1. **Use `nginx:alpine` for the server, exec into a separate `curlimages/curl` pod for testing.** This keeps images minimal and avoids custom builds.
2. **Build a tiny image with both nginx and curl.** Adds a build step.

**Decision: Option 1.** Each tenant namespace gets an nginx Deployment (the "service") and a long-running curl pod (the "client"). This avoids any custom image builds.

### 2.2 Tenant Service (nginx)

Identical structure in each tenant namespace. The service name encodes the tenant for clarity in demo output.

```yaml
# tenants/tenant-a/workloads/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: tenant-a
  labels:
    app: web
    tenant: tenant-a
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
        tenant: tenant-a
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              cpu: 50m
              memory: 32Mi
---
# tenants/tenant-a/workloads/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: tenant-a
  labels:
    app: web
    tenant: tenant-a
spec:
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
```

Tenant-b has the same structure with `namespace: tenant-b` and `tenant: tenant-b` labels.

### 2.3 Curl Client Pod

A long-running curl pod in each tenant namespace for interactive testing:

```yaml
# tenants/tenant-a/workloads/curl-client.yaml
apiVersion: v1
kind: Pod
metadata:
  name: curl-client
  namespace: tenant-a
  labels:
    app: curl-client
    tenant: tenant-a
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.11.0
      command: ["sleep", "infinity"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          cpu: 50m
          memory: 32Mi
```

### 2.4 Demo Curl Commands

These are the exact commands used during the talk:

```bash
# Scene 1 Beat 1 — flat network, cross-tenant access (expect 200)
kubectl exec -n tenant-a curl-client -- curl -s -o /dev/null -w "%{http_code}" http://web.tenant-b.svc.cluster.local

# Scene 1 Beat 1 — access shared service (expect 200)
kubectl exec -n tenant-a curl-client -- curl -s -o /dev/null -w "%{http_code}" http://config-api.shared-services.svc.cluster.local:8080/api/config

# Scene 1 Beat 2 — L7 bypass on shared service (expect 200 with standard NP, 403 with CiliumNP)
kubectl exec -n tenant-b curl-client -- curl -s -o /dev/null -w "%{http_code}" http://config-api.shared-services.svc.cluster.local:8080/admin/tenant-a/config
```

---

## 3. Shared Config API Service

This is the key service for the L7 filtering demo in Scene 1. It must:

1. Run on port 8080.
2. Serve `/api/config` -- returns 200 with a JSON payload (legitimate path all tenants use).
3. Serve `/admin/tenant-b/config` (and `/admin/tenant-a/config`) -- returns 200 with sensitive data (restricted paths that CiliumNetworkPolicy should block).
4. Be simple enough that the audience immediately understands what it does.

### 3.1 Implementation: nginx with Location Blocks

A custom nginx configuration handles this without any application code. No custom image build -- use a ConfigMap to inject the nginx config.

```yaml
# shared-services/config-api/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: config-api-nginx
  namespace: shared-services
data:
  default.conf: |
    server {
      listen 8080;
      server_name _;

      # Legitimate endpoint — all tenants should reach this
      location /api/config {
        default_type application/json;
        return 200 '{"status":"ok","message":"shared configuration","version":"1.0"}\n';
      }

      # Health check
      location /healthz {
        default_type text/plain;
        return 200 'ok\n';
      }

      # Admin endpoints — per-tenant config (should be restricted by CiliumNP)
      location ~ ^/admin/(?<tenant_id>[^/]+)/config$ {
        default_type application/json;
        return 200 '{"status":"ok","tenant":"$tenant_id","secret_key":"s3cr3t-$tenant_id","admin":true}\n';
      }

      # Catch-all
      location / {
        default_type text/plain;
        return 404 'not found\n';
      }
    }
```

```yaml
# shared-services/config-api/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: config-api
  namespace: shared-services
  labels:
    app: config-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: config-api
  template:
    metadata:
      labels:
        app: config-api
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: nginx-config
              mountPath: /etc/nginx/conf.d
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              cpu: 50m
              memory: 32Mi
      volumes:
        - name: nginx-config
          configMap:
            name: config-api-nginx
---
# shared-services/config-api/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: config-api
  namespace: shared-services
  labels:
    app: config-api
spec:
  selector:
    app: config-api
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
```

### 3.2 Validation

```bash
# From tenant-a curl client — legitimate access (always 200)
kubectl exec -n tenant-a curl-client -- curl -s http://config-api.shared-services.svc.cluster.local:8080/api/config
# => {"status":"ok","message":"shared configuration","version":"1.0"}

# From tenant-b curl client — admin path (200 before CiliumNP, blocked after)
kubectl exec -n tenant-b curl-client -- curl -s http://config-api.shared-services.svc.cluster.local:8080/admin/tenant-a/config
# Before CiliumNP => {"status":"ok","tenant":"tenant-a","secret_key":"s3cr3t-tenant-a","admin":true}
# After CiliumNP  => connection dropped / 403 (Cilium drops the request at L7)
```

### 3.3 Why nginx Over a Custom App

- Zero build step. No container registry. Stock `nginx:1.27-alpine` image plus a ConfigMap.
- The audience can read the nginx config on-screen and immediately understand the API surface.
- Location blocks map directly to the CiliumNetworkPolicy HTTP rules, making the cause-and-effect obvious.
- If a richer API is needed later (e.g., POST endpoints, dynamic responses), this can be swapped for a Go binary without changing the Service or Deployment structure.

---

## 4. ArgoCD Application Definitions Per Stage

The ArgoCD configuration evolves across the talk. Each stage below shows the relevant Application and Project state.

### 4.1 Stage 0 -- Prologue: Everything in the Default Project

All Applications reference the `default` ArgoCD Project. No restrictions on destinations, source repos, or resource types. This is intentionally insecure.

```yaml
# manifests/stage-0/applications/tenant-a-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tenant-a
  namespace: argocd
spec:
  project: default          # <-- the problem
  source:
    repoURL: https://github.com/argo-multiverse-labs/argoconeu26.git
    targetRevision: main
    path: tenants/tenant-a
  destination:
    server: https://kubernetes.default.svc
    namespace: tenant-a
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

```yaml
# manifests/stage-0/applications/tenant-b-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tenant-b
  namespace: argocd
spec:
  project: default          # <-- same problem
  source:
    repoURL: https://github.com/argo-multiverse-labs/argoconeu26.git
    targetRevision: main
    path: tenants/tenant-b
  destination:
    server: https://kubernetes.default.svc
    namespace: tenant-b
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

```yaml
# manifests/stage-0/applications/shared-services-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: shared-services
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argo-multiverse-labs/argoconeu26.git
    targetRevision: main
    path: shared-services
  destination:
    server: https://kubernetes.default.svc
    namespace: shared-services
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**What the Rogue Tenant exploits (Scene 2):** Because tenant-b's Application uses `project: default`, and the default Project allows all destinations, the Rogue Tenant can change the destination namespace to `tenant-a` and deploy resources there. They can also create cluster-scoped resources like ClusterRoleBindings.

### 4.2 Stage 2 -- Per-Tenant ArgoCD Projects

After the Scene 2 breach, the Platform Engineer creates scoped Projects. The Applications are updated to reference their tenant Project instead of `default`.

**Per-tenant Projects:**

```yaml
# manifests/stage-2/projects/tenant-a-project.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: tenant-a
  namespace: argocd
spec:
  description: "Tenant A project — scoped to tenant-a namespace only"

  sourceRepos:
    - 'https://github.com/argo-multiverse-labs/argoconeu26.git'

  destinations:
    - server: https://kubernetes.default.svc
      namespace: tenant-a           # Can ONLY deploy to their own namespace
    - server: https://kubernetes.default.svc
      namespace: shared-services    # Read-only access to shared services (for app references)

  # Block all cluster-scoped resources by default
  clusterResourceWhitelist: []

  # Only allow these namespaced resource types
  namespaceResourceWhitelist:
    - group: ''
      kind: ConfigMap
    - group: ''
      kind: Service
    - group: ''
      kind: Pod
    - group: apps
      kind: Deployment
    - group: apps
      kind: ReplicaSet
    - group: networking.k8s.io
      kind: NetworkPolicy
```

```yaml
# manifests/stage-2/projects/tenant-b-project.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: tenant-b
  namespace: argocd
spec:
  description: "Tenant B project — scoped to tenant-b namespace only"

  sourceRepos:
    - 'https://github.com/argo-multiverse-labs/argoconeu26.git'

  destinations:
    - server: https://kubernetes.default.svc
      namespace: tenant-b
    - server: https://kubernetes.default.svc
      namespace: shared-services

  clusterResourceWhitelist: []

  namespaceResourceWhitelist:
    - group: ''
      kind: ConfigMap
    - group: ''
      kind: Service
    - group: ''
      kind: Pod
    - group: apps
      kind: Deployment
    - group: apps
      kind: ReplicaSet
    - group: networking.k8s.io
      kind: NetworkPolicy
```

**Updated Applications (stage 2):**

```yaml
# manifests/stage-2/applications/tenant-a-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tenant-a
  namespace: argocd
spec:
  project: tenant-a          # <-- now scoped
  source:
    repoURL: https://github.com/argo-multiverse-labs/argoconeu26.git
    targetRevision: main
    path: tenants/tenant-a
  destination:
    server: https://kubernetes.default.svc
    namespace: tenant-a
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Key demo moment:** After applying the Projects, the Rogue Tenant tries to deploy to `tenant-a`'s namespace from the `tenant-b` Project. ArgoCD rejects it:

```
application destination {https://kubernetes.default.svc tenant-a} is not permitted
in project 'tenant-b'
```

**Note on `shared-services` destination in tenant Projects:** Tenants need to reference the shared config API but should not be able to deploy arbitrary resources into `shared-services`. This destination entry allows the Application to reference the namespace. Actual write access is further restricted by RBAC (covered in design doc 04). If this feels too permissive, the `shared-services` destination can be removed from tenant Projects entirely -- tenants simply reference the service by DNS name without needing ArgoCD awareness of it.

### 4.3 Stage 3 -- ApplicationSet Replaces Manual Applications

In Scene 3, the manually-defined Applications and Projects are replaced by an ApplicationSet that generates everything from a git directory structure. See Section 5 below for the full ApplicationSet design.

The manually-created Applications (`tenant-a-app.yaml`, `tenant-b-app.yaml`) are deleted and replaced by ApplicationSet-generated Applications. The behavior is identical but the mechanism is automated.

---

## 5. ApplicationSet Design for Scene 3

### 5.1 Generator Choice: Git Directory Generator

The **git directory generator** is the right fit. It watches a directory in the git repo and creates one Application per subdirectory. Adding a new tenant is a matter of adding a new directory with a config file.

Why git directory over alternatives:
- **Git file generator** works but requires a centralized list file -- less intuitive for the "add a directory" demo.
- **Matrix generator** is powerful but adds complexity the audience does not need in a 25-minute talk.
- **Git directory** has the clearest cause-and-effect: "I added a folder, ArgoCD created everything."

### 5.2 Git Directory Structure for Tenant Onboarding

Each tenant gets a directory under `tenants/`. The ApplicationSet detects these directories:

```
tenants/
  tenant-a/
    config.yaml          # Tenant-specific values (name, allowed paths, etc.)
    workloads/
      deployment.yaml    # nginx web service
      service.yaml       # ClusterIP service
      curl-client.yaml   # Test pod
  tenant-b/
    config.yaml
    workloads/
      deployment.yaml
      service.yaml
      curl-client.yaml
  tenant-c/              # <-- Added in Scene 3 to trigger onboarding
    config.yaml
    workloads/
      deployment.yaml
      service.yaml
      curl-client.yaml
```

The `config.yaml` in each tenant directory provides tenant-specific values. For the git directory generator, this file's contents are not directly read by the ApplicationSet -- the generator only detects the directory. However, the file serves as documentation and can be consumed by Helm/Kustomize when the Application syncs.

```yaml
# tenants/tenant-c/config.yaml
tenant:
  name: tenant-c
  team: "New Team"
  contact: "newteam@bigcorp.example.com"
  allowedPaths:
    - /api/config
```

### 5.3 Base Templates for Tenant Resources

A `base/` directory contains the template resources that every tenant gets. Each tenant's Application uses Kustomize to overlay tenant-specific values onto these bases.

```
base/
  tenant-template/
    kustomization.yaml
    namespace.yaml
    network-policies/
      default-deny.yaml        # Default-deny CiliumNetworkPolicy
      allow-shared-services.yaml   # Allow L7-filtered access to shared services
      allow-dns.yaml           # Allow DNS resolution
    rbac/
      service-account.yaml     # Tenant ServiceAccount
      role.yaml                # Namespace-scoped Role
      role-binding.yaml        # RoleBinding for the tenant SA
    workloads/
      deployment.yaml          # nginx web service
      service.yaml             # ClusterIP service
      curl-client.yaml         # Test pod
```

Each tenant directory then uses Kustomize to reference the base and overlay tenant-specific values:

```yaml
# tenants/tenant-c/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base/tenant-template

namespace: tenant-c

commonLabels:
  tenant: tenant-c

patches:
  - target:
      kind: Namespace
      name: tenant-template
    patch: |
      - op: replace
        path: /metadata/name
        value: tenant-c
```

### 5.4 The ApplicationSet Manifest

This is the central piece. One ApplicationSet generates per-tenant Applications from the git directory structure. A second ApplicationSet (or the same one with a matrix generator) handles the ArgoCD Projects.

**Option A -- Two ApplicationSets (recommended for clarity):**

**ApplicationSet 1: Tenant Workloads + Network Policies**

```yaml
# manifests/stage-3/applicationsets/tenant-workloads.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: tenant-workloads
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: https://github.com/argo-multiverse-labs/argoconeu26.git
        revision: main
        directories:
          - path: tenants/*
  template:
    metadata:
      name: '{{ .path.basename }}'
    spec:
      project: '{{ .path.basename }}'    # References per-tenant Project
      source:
        repoURL: https://github.com/argo-multiverse-labs/argoconeu26.git
        targetRevision: main
        path: '{{ .path.path }}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{ .path.basename }}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

**ApplicationSet 2: Tenant ArgoCD Projects**

```yaml
# manifests/stage-3/applicationsets/tenant-projects.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: tenant-projects
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: https://github.com/argo-multiverse-labs/argoconeu26.git
        revision: main
        directories:
          - path: tenants/*
  template:
    metadata:
      name: '{{ .path.basename }}-project'
    spec:
      project: default     # Project-management Apps live in default project
      source:
        repoURL: https://github.com/argo-multiverse-labs/argoconeu26.git
        targetRevision: main
        path: base/argocd-project
        helm:
          parameters:
            - name: tenantName
              value: '{{ .path.basename }}'
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

**Base Helm chart for ArgoCD Projects:**

```
base/
  argocd-project/
    Chart.yaml
    values.yaml
    templates/
      project.yaml
```

```yaml
# base/argocd-project/templates/project.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: {{ .Values.tenantName }}
  namespace: argocd
spec:
  description: "Project for {{ .Values.tenantName }}"
  sourceRepos:
    - 'https://github.com/argo-multiverse-labs/argoconeu26.git'
  destinations:
    - server: https://kubernetes.default.svc
      namespace: {{ .Values.tenantName }}
  clusterResourceWhitelist: []
  namespaceResourceWhitelist:
    - group: ''
      kind: ConfigMap
    - group: ''
      kind: Service
    - group: ''
      kind: Pod
    - group: apps
      kind: Deployment
    - group: apps
      kind: ReplicaSet
    - group: networking.k8s.io
      kind: NetworkPolicy
```

### 5.5 "Add tenant-c With One Git Commit"

This is the demo climax for Scene 3. The Platform Engineer adds a single directory and commits:

```bash
# Copy the base template for the new tenant
cp -r tenants/tenant-a tenants/tenant-c

# Update kustomization.yaml to reference tenant-c
sed -i 's/tenant-a/tenant-c/g' tenants/tenant-c/kustomization.yaml

# Commit and push
git add tenants/tenant-c/
git commit -m "onboard tenant-c"
git push
```

Within seconds, ArgoCD detects the new directory and creates:
1. An ArgoCD Project named `tenant-c` (scoped to `tenant-c` namespace only).
2. An Application named `tenant-c` deploying workloads, CiliumNetworkPolicies, and RBAC into the `tenant-c` namespace.
3. The namespace itself (via `CreateNamespace=true` sync option).

**What the audience sees:** The ArgoCD UI shows two new Applications appearing and syncing automatically. The Rogue Tenant can immediately verify that `tenant-c` has default-deny network policies and a properly scoped Project -- no manual configuration was needed.

### 5.6 Ordering Concern: Project Must Exist Before Application

The `tenant-workloads` ApplicationSet creates Applications that reference `project: {{ .path.basename }}`. The `tenant-projects` ApplicationSet creates the Projects. If the workload Application syncs before the Project exists, it will fail.

**Mitigation options:**

1. **Sync waves.** The Project-generating Application uses `argocd.argoproj.io/sync-wave: "-1"` to sync before the workloads. However, sync waves are per-Application, not across Applications.
2. **App-of-apps pattern.** A single ApplicationSet generates one Application per tenant that deploys everything (Project + workloads + policies) from a single Kustomize/Helm source, using sync waves within that Application. This guarantees ordering.
3. **Accept transient failure.** ArgoCD will retry the workload Application. Once the Project exists (a few seconds later), the retry succeeds. This is the simplest approach and acceptable for a demo.

**Recommendation: Option 3 for the demo** (accept transient failure -- ArgoCD auto-retries). If the retry delay looks bad on stage, switch to Option 2 (single app-of-apps per tenant). Document this as a rehearsal decision point.

---

## 6. Repository Structure

The canonical directory layout is defined in [00-index.md](./00-index.md#canonical-directory-layout). All stage manifests live under `manifests/stage-N/`. There is no `argocd/` or `network-policies/` top-level directory -- everything ArgoCD-related and all network policies are organized under their respective stage directories.

Key directories relevant to tenant architecture:

```
manifests/
  stage-0/              # Prologue: flat network, default project
    applications/       #   tenant-a-app.yaml, tenant-b-app.yaml, shared-services-app.yaml
  stage-1a/             # Scene 1: standard K8s NetworkPolicies
    networkpolicies/
  stage-1b/             # Scene 1: CiliumNetworkPolicies (L7)
    ciliumnetworkpolicies/
  stage-2/              # Scene 2: per-tenant Projects + locked default
    projects/           #   tenant-a-project.yaml, tenant-b-project.yaml
    argocd-config/
    applications/       #   tenant-a-app.yaml (now scoped to tenant project)
  stage-3/              # Scene 3: ApplicationSet
    projects/
    applicationsets/    #   tenant-workloads.yaml, tenant-projects.yaml
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
base/                   # Shared templates
  tenant-template/
  argocd-project/       # Helm chart for per-tenant ArgoCD Project
shared-services/        # Shared services (not per-tenant)
  config-api/
scripts/                # Demo automation
```

### 6.1 Key Design Decisions in the Layout

**`tenants/` is the ApplicationSet source.** The git directory generator watches `tenants/*`. Each subdirectory becomes a tenant. This is the directory the audience watches when tenant-c is added.

**`base/` contains shared templates.** Tenant directories use Kustomize to overlay the base. This prevents the copy-paste problem the talk explicitly calls out in Scene 3 Beat 1.

**Network policies live within their stage directories.** Network policies progress through the talk independently of the tenant workloads: `manifests/stage-1a/networkpolicies/` for standard K8s NetworkPolicies, `manifests/stage-1b/ciliumnetworkpolicies/` for CiliumNetworkPolicies, and `manifests/stage-4/ciliumnetworkpolicies/` for SA-scoped CNPs. This allows the demo scripts to swap policy stages without touching tenant workload state. Once the demo reaches Scene 3, the base tenant template includes the final CiliumNetworkPolicies, so new tenants get correct policies automatically.

**`manifests/stage-N/applications/` has per-stage application definitions.** The demo scripts apply the appropriate stage directory. The ApplicationSets in `manifests/stage-3/applicationsets/` replace the staged Applications in Scene 3.

**`shared-services/` is top-level.** It is not a tenant and should not be managed by the tenant ApplicationSet. It has its own ArgoCD Application (either manually created or as a separate app-of-apps entry).

---

## Open Questions

1. **Kustomize vs Helm for tenant overlays.** This design uses Kustomize for tenant directories overlaying `base/tenant-template`. Helm is used only for the ArgoCD Project template (because it needs a single parameter substitution). Is there a preference for using Helm consistently throughout, or is this mix acceptable?

Mix is ok

2. **Shared-services destination in tenant Projects.** Section 4.2 includes `shared-services` as a permitted destination in tenant Projects. This is necessary only if tenants deploy Applications that reference `shared-services`. If tenants merely curl the service by DNS, this destination can be removed. Which behavior does the demo require?

Please verify, keeping shared-services is ok

3. **Single ApplicationSet vs two.** Section 5.4 proposes two ApplicationSets (one for workloads, one for Projects). A single ApplicationSet using an app-of-apps pattern per tenant is simpler to present on stage but slightly more complex in implementation. Which is preferred for the talk's clarity?

the former, less complex is ok

4. **Ordering: Project before workload Application.** Section 5.6 recommends accepting transient failure (ArgoCD retries). If this looks bad during rehearsal, the fallback is an app-of-apps with sync waves. This should be tested early in rehearsal.

We will test and find out

5. **Source repo for ApplicationSet.** The ApplicationSets reference `https://github.com/argo-multiverse-labs/argoconeu26.git`. During local development, this could be a local git server or ArgoCD could be configured to watch a local path. The demo automation design doc should address how source repo references work in the KinD environment.

The git repo is fine

6. **Workload identity for curl-client.** The curl-client Pod uses a default ServiceAccount. In Scene 4 (sync impersonation), should the curl-client run under the tenant's dedicated ServiceAccount to demonstrate identity-scoped CiliumNetworkPolicies? This would require adding `serviceAccountName: tenant-a-sa` to the pod spec.

Yes, we are emphasizing multi-tenancy segmentation with networking

7. **Config API response for blocked requests.** When CiliumNetworkPolicy blocks an L7 request, the client sees a connection drop (not a 403 from nginx). The demo script should account for this -- `curl` will timeout or receive a TCP reset, not an HTTP error code. Confirm with Christian how Cilium L7 enforcement surfaces to the client (TCP RST vs drop vs 403 injection).

We can verify
