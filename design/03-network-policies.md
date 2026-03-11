# Design Document 03: Network Policy Progression

**Talk:** Network Segmentation at Scale — ArgoCon EU 2026
**Scene coverage:** Prologue (Stage 0), Scene 1 Beats 1–2 (Stages 1a and 1b), Scene 4 (Stage 4)
**Author note:** WebFetch was unavailable during authoring. All Cilium YAML syntax is drawn from
training knowledge of Cilium 1.14–1.16 stable documentation (knowledge cutoff August 2025).
**Updated:** Pinned to Cilium 1.19.1 (current stable as of March 2026). All CiliumNetworkPolicy
syntax is compatible. Verify manifests against 1.19.x docs before the demo.

---

## Overview

The network policy progression is the spine of Scene 1 and the technical centrepiece of the talk.
The audience watches isolation go from completely absent to L7-path-aware in three steps, each
introduced by a failure. This document covers every manifest, every validation command, and every
expected output for those steps.

The four stages map to the talk narrative as follows:

| Stage | Talk location | What changes | Failure that motivates it |
|-------|---------------|--------------|--------------------------|
| Stage 0 | Prologue | No policies exist | — (sets baseline) |
| Stage 1a | Scene 1 Beat 1 | Standard Kubernetes NetworkPolicies added | Rogue Tenant curls tenant-b directly |
| Stage 1b | Scene 1 Beat 2 | CiliumNetworkPolicies replace/extend standard NPs | Rogue Tenant hits /admin path on shared service |
| Stage 4 | Scene 4 | ServiceAccount-scoped CNPs + sync impersonation | Rogue Tenant exploits ArgoCD sync privileges |

---

## Namespace Topology

All policies in this document assume the following namespaces exist. (Full namespace and workload
design is in `design/02-tenant-architecture.md`.)

```
tenant-a          # Rogue Tenant's workloads
tenant-b          # Second tenant's workloads
shared-services   # Config API on port 8080 — the L7 demo target
kube-system       # kube-dns lives here (UDP/TCP 53)
argocd            # ArgoCD controller and server
```

Pod label convention used throughout (matches `design/02-tenant-architecture.md`):

```
app: web               # tenant nginx web service (Deployment)
app: curl-client       # tenant curl test pods (Pod)
app: config-api        # shared-services config API pod (Deployment)
```

ServiceAccount convention:

```
tenant-a/sa-tenant-a   # ServiceAccount for tenant-a workloads
tenant-b/sa-tenant-b   # ServiceAccount for tenant-b workloads
```

---

## Stage 0 — Prologue: Flat Network (No Policies)

### State description

Kubernetes default network model: no NetworkPolicy objects exist in any namespace. Every pod can
initiate a TCP connection to every other pod on every port, across all namespaces. This is not a
Cilium behaviour — it is the Kubernetes specification. Cilium enforces the same open default when
no policy selects a pod.

### What the audience sees

The Platform Engineer shows the empty cluster. The Rogue Tenant deploys a workload pod in
`tenant-a` and immediately curls the `tenant-b` internal service. It returns HTTP 200. No firewall,
no warning — just open connectivity.

### Validation commands

Run these from the demo script in sequence. The presenter runs them as the Rogue Tenant character.

**Step 1 — confirm no policies exist:**

```bash
kubectl get networkpolicy --all-namespaces
# Expected: No resources found.

kubectl get ciliumnetworkpolicy --all-namespaces
# Expected: No resources found.
```

**Step 2 — exec into tenant-a workload pod and curl tenant-b service:**

```bash
TENANT_A_POD=$(kubectl get pod -n tenant-a -l app=curl-client -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n tenant-a "$TENANT_A_POD" -- \
  curl -s -o /dev/null -w "%{http_code}" http://web.tenant-b.svc.cluster.local/
# Expected output: 200
```

**Step 3 — curl shared-service (to establish baseline before policies):**

```bash
kubectl exec -n tenant-a "$TENANT_A_POD" -- \
  curl -s -o /dev/null -w "%{http_code}" http://config-api.shared-services.svc.cluster.local:8080/api/config
# Expected output: 200

kubectl exec -n tenant-a "$TENANT_A_POD" -- \
  curl -s -o /dev/null -w "%{http_code}" http://config-api.shared-services.svc.cluster.local:8080/admin/tenant-b/config
# Expected output: 200  (this is the gap we will close in Stage 1b)
```

### Audience talking point

Christian (Rogue Tenant) delivers the fourth-wall break here: "Kubernetes namespaces are an
organisational boundary, not a security boundary. The network sees them as labels, not walls."

---

## Stage 1a — Standard Kubernetes NetworkPolicies (L3/L4)

### What changes

The Platform Engineer adds Kubernetes-native `NetworkPolicy` resources. Strategy:

- **Default-deny ingress AND egress** in every tenant namespace and in `shared-services`.
- **Explicit allow rules** restore only the legitimate traffic paths:
  - Intra-namespace pod-to-pod traffic (same namespace)
  - Egress to kube-dns (UDP and TCP port 53) from every namespace
  - Egress from tenant namespaces to `shared-services` on port 8080
  - Ingress on port 8080 into `shared-services` from tenant namespaces

The policies do NOT allow cross-tenant traffic. After applying these, the Rogue Tenant's curl to
`tenant-b` will time out.

### Policy manifests

#### 1. Default-deny ingress and egress — tenant-a
<!-- STATUS: REVIEWED -->

```yaml
# manifests/stage-1a/networkpolicies/tenant-a-default-deny.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tenant-a
spec:
  podSelector: {}        # selects ALL pods in the namespace
  policyTypes:
    - Ingress
    - Egress
  # No ingress or egress rules = deny everything
```

#### 2. Allow intra-namespace traffic — tenant-a
<!-- STATUS: REVIEWED -->

```yaml
# manifests/stage-1a/networkpolicies/tenant-a-allow-intra-namespace.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-intra-namespace
  namespace: tenant-a
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector: {}   # any pod in the same namespace (namespaceSelector omitted = same ns)
  egress:
    - to:
        - podSelector: {}
```

#### 3. Allow egress to kube-dns — tenant-a
<!-- STATUS: REVIEWED -->

```yaml
# manifests/stage-1a/networkpolicies/tenant-a-allow-dns.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-dns
  namespace: tenant-a
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

#### 4. Allow egress to shared-services:8080 — tenant-a
<!-- STATUS: REVIEWED -->

```yaml
# manifests/stage-1a/networkpolicies/tenant-a-allow-shared-services.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-to-shared-services
  namespace: tenant-a
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: shared-services
          podSelector:
            matchLabels:
              app: config-api
      ports:
        - protocol: TCP
          port: 8080
```

#### 5–8. Mirror policies for tenant-b
<!-- STATUS: REVIEWED -->

Apply the exact same four policies to `tenant-b` — only the `namespace:` field changes. For
brevity, the manifests are shown as a single combined file:

```yaml
# manifests/stage-1a/networkpolicies/tenant-b-all.yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tenant-b
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-intra-namespace
  namespace: tenant-b
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector: {}
  egress:
    - to:
        - podSelector: {}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-dns
  namespace: tenant-b
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-to-shared-services
  namespace: tenant-b
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: shared-services
          podSelector:
            matchLabels:
              app: config-api
      ports:
        - protocol: TCP
          port: 8080
```

#### 9. Default-deny and ingress allow — shared-services
<!-- STATUS: REVIEWED -->

```yaml
# manifests/stage-1a/networkpolicies/shared-services-all.yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: shared-services
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
# Allow tenants to reach the config API on 8080
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-from-tenants
  namespace: shared-services
spec:
  podSelector:
    matchLabels:
      app: config-api
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchExpressions:
              - key: kubernetes.io/metadata.name
                operator: In
                values:
                  - tenant-a
                  - tenant-b
      ports:
        - protocol: TCP
          port: 8080
---
# shared-services needs DNS egress too
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-dns
  namespace: shared-services
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

### Apply command

```bash
kubectl apply -f manifests/stage-1a/networkpolicies/
```

### What is allowed after Stage 1a

| Source | Destination | Port | Result |
|--------|-------------|------|--------|
| tenant-a pod | tenant-a pod | any | ALLOWED (intra-namespace) |
| tenant-a pod | tenant-b pod | any | BLOCKED (no cross-tenant rule) |
| tenant-a pod | config-api.shared-services | 8080 | ALLOWED |
| tenant-a pod | config-api.shared-services | any other | BLOCKED |
| tenant-a pod | kube-dns | 53 UDP/TCP | ALLOWED |
| tenant-a pod | external internet | any | BLOCKED (default-deny egress) |
| tenant-b pod | tenant-a pod | any | BLOCKED |

### Validation commands

**Cross-tenant block (the payoff of Beat 1):**

```bash
TENANT_A_POD=$(kubectl get pod -n tenant-a -l app=curl-client -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n tenant-a "$TENANT_A_POD" -- \
  curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
  http://web.tenant-b.svc.cluster.local/
# Expected output: 000
# curl exits with code 28 (timeout). The connection is dropped, not refused.
# On screen: "000" and "curl: (28) Connection timed out"
```

> Note: With Cilium's default policy enforcement, the behaviour is a silent drop (no TCP RST),
> which means curl will hang until `--max-time` expires. This is deliberate — it prevents
> information leakage about whether the destination exists. Use `--max-time 5` in the demo to
> avoid dead air.

**Shared-service allow (still works at L4):**

```bash
kubectl exec -n tenant-a "$TENANT_A_POD" -- \
  curl -s -o /dev/null -w "%{http_code}" \
  http://config-api.shared-services.svc.cluster.local:8080/api/config
# Expected output: 200
```

**THE GAP — L7 path bypass (the motivating failure for Stage 1b):**

```bash
kubectl exec -n tenant-a "$TENANT_A_POD" -- \
  curl -s -o /dev/null -w "%{http_code}" \
  http://config-api.shared-services.svc.cluster.local:8080/admin/tenant-b/config
# Expected output: 200
# Standard NetworkPolicy allowed TCP 8080 — it cannot distinguish /api/* from /admin/*
```

This is the moment Christian delivers the fourth-wall break about CiliumNetworkPolicies.

---

## Stage 1b — CiliumNetworkPolicies (L7 + DNS-aware)

### What changes

The platform engineer makes two upgrades:

1. **L7 HTTP path filtering on shared-services** — a `CiliumNetworkPolicy` replaces the standard
   `NetworkPolicy` on `shared-services`. It allows `GET /api/*` from any tenant but denies any
   request to `/admin/*`.

2. **DNS-aware egress** — `toFQDNs` rules replace the hardcoded `namespaceSelector` approach for
   any external egress, eliminating the pitfall of hardcoded IP CIDRs. (For the demo, a
   representative example using an external hostname is included even if the primary traffic is
   cluster-internal, to illustrate the feature.)

The standard `NetworkPolicy` objects from Stage 1a for `tenant-a` and `tenant-b` are retained
unchanged — standard NPs and CiliumNPs coexist and both must be satisfied. Only the
`shared-services` policies are replaced with CiliumNetworkPolicies.

### Cilium version requirement

L7 HTTP policy filtering (`rules.http`) is available in all Cilium versions that support
`CiliumNetworkPolicy` (v1.0+). The `toFQDNs` feature was promoted to stable in Cilium 1.6.
ServiceAccount-based selectors (`k8s:io.cilium.k8s.policy.serviceaccount`) have been available
since Cilium 1.5. For the demo, target **Cilium 1.19.1** (latest stable as of March 2026)
to ensure all features are supported without workarounds.

**Flag:** Cilium's L7 HTTP policy requires the Envoy proxy to be active. In Cilium 1.13+, the
Envoy DaemonSet is deployed by default. If using an older version, verify
`bpf.tproxy: true` and that `cilium-envoy` pods are running. Check with:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-envoy
```

### Policy manifests

#### 1. Remove shared-services standard NetworkPolicies

```bash
kubectl delete networkpolicy -n shared-services --all
```

#### 2. CiliumNetworkPolicy — L7 HTTP path filtering on shared-services
<!-- STATUS: REVIEWED -->

```yaml
# manifests/stage-1b/ciliumnetworkpolicies/shared-services-l7.yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: config-api-l7-policy
  namespace: shared-services
spec:
  endpointSelector:
    matchLabels:
      app: config-api
  ingress:
    # Allow GET /api/* from tenant-a
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: tenant-a
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/api/.*"
    # Allow GET /api/* from tenant-b
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: tenant-b
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/api/.*"
    # NOTE: No rule for /admin/* = implicit deny for that path.
    # Cilium L7 policy is allowlist-only: anything not explicitly allowed is denied.
    # A request to /admin/tenant-b/config will receive HTTP 403 Forbidden from Envoy.
  egress:
    # Allow shared-services to reach kube-dns for its own resolution
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
          rules:
            dns:
              - matchPattern: "*"
```

> Design note on path syntax: Cilium's `path` field in `http` rules is a RE2 regular expression.
> `/api/.*` matches `/api/` followed by any characters. If the shared-service's router strips the
> trailing slash, also consider `/api(/.*)?` as an alternative. Validate with the actual service
> router before the demo. See Open Question OQ-1.

#### 3. DNS-aware egress — CiliumNetworkPolicy for tenant-a external access (OPTIONAL / BONUS)
<!-- STATUS: REVIEWED -->

> **Note:** This `toFQDNs` policy is optional and is NOT exercised during the live demo. It is
> included here as a bonus example to illustrate DNS-aware egress filtering. If time permits,
> the presenter can mention it as a capability without applying it on stage. The primary demo
> flow (Stages 0 -> 1a -> 1b -> 4) does not depend on this policy.

This manifest demonstrates `toFQDNs` for any external egress the tenant workloads need. In the
demo context, this could represent a tenant calling an external API (e.g., a package registry or
webhook endpoint) without hardcoding its IP.

```yaml
# manifests/stage-1b/ciliumnetworkpolicies/tenant-a-fqdn-egress.yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: allow-egress-external-api
  namespace: tenant-a
spec:
  endpointSelector:
    matchLabels:
      app: curl-client
  egress:
    # DNS must be allowed first so Cilium can intercept and learn the IPs
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
          rules:
            dns:
              - matchPattern: "*"
    # Allow HTTPS to a specific external hostname (example: github.com)
    - toFQDNs:
        - matchName: "github.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
    # Allow HTTPS to any *.example-corp.internal subdomain (wildcard pattern)
    - toFQDNs:
        - matchPattern: "*.example-corp.internal"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

> Design note: `toFQDNs` requires Cilium's DNS proxy to intercept DNS responses and learn the
> resolved IPs before the workload initiates the connection. The `dns` rule on port 53 (shown
> above) must be in the same policy or a companion policy for `toFQDNs` to function. Without the
> DNS intercept rule, the FQDN-to-IP mapping is never populated and connections will be dropped.
> This is a common misconfiguration — worth calling out in the talk.

#### 4. Combined manifest for applying Stage 1b in one command

```yaml
# manifests/stage-1b/ciliumnetworkpolicies/kustomization.yaml
# (or apply with kubectl apply -f manifests/stage-1b/ciliumnetworkpolicies/)
```

Apply command:

```bash
# Remove old standard NPs from shared-services
kubectl delete networkpolicy -n shared-services --all

# Apply Cilium policies
kubectl apply -f manifests/stage-1b/ciliumnetworkpolicies/
```

### What is allowed after Stage 1b

| Source | Destination | Path | Result |
|--------|-------------|------|--------|
| tenant-a pod | tenant-b pod | any | BLOCKED (standard NP from Stage 1a) |
| tenant-a pod | config-api:8080 | GET /api/* | ALLOWED (CNP L7 rule) |
| tenant-a pod | config-api:8080 | GET /admin/* | 403 FORBIDDEN (Envoy returns 403) |
| tenant-a pod | config-api:8080 | POST /api/* | 403 FORBIDDEN (only GET is allowed) |
| tenant-a pod | github.com:443 | any | ALLOWED (toFQDNs rule) |
| tenant-a pod | arbitrary-external:443 | any | BLOCKED (default-deny egress from Stage 1a) |

### Validation commands

**L7 allow — API path:**

```bash
TENANT_A_POD=$(kubectl get pod -n tenant-a -l app=curl-client -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n tenant-a "$TENANT_A_POD" -- \
  curl -s -o /dev/null -w "%{http_code}" \
  http://config-api.shared-services.svc.cluster.local:8080/api/config
# Expected output: 200
```

**L7 block — admin path (the payoff of Beat 2):**

```bash
kubectl exec -n tenant-a "$TENANT_A_POD" -- \
  curl -s -o /dev/null -w "%{http_code}" \
  http://config-api.shared-services.svc.cluster.local:8080/admin/tenant-b/config
# Expected output: 403
# Cilium's Envoy proxy intercepts the HTTP request and returns 403 Forbidden.
# Unlike Stage 1a where this returned 200, the path is now policy-enforced.
```

**Hubble observe — show the denied flow:**

```bash
# In a separate terminal, start watching flows before running the curl above
hubble observe \
  --namespace shared-services \
  --verdict DROPPED \
  --output jsonpb \
  | jq '{time: .time, source: .source.namespace, dest: .destination.namespace, verdict: .verdict, http: .l7.http}'

# Or simpler for demo:
hubble observe --namespace shared-services --verdict DROPPED
```

Expected Hubble output (approximate — exact field names depend on Hubble version):

```
DROPPED   tenant-a/curl-client   shared-services/config-api-xxxx   HTTP/1.1 GET /admin/tenant-b/config
```

> Demo tip: Start `hubble observe` before running the curl commands. Pipe through `--follow` to
> stream flows live. The Hubble UI (if port-forwarded) provides a visual flow map that reads well
> on a conference projector. Show both CLI and UI for maximum impact in Beat 2.

**Hubble observe — confirm allowed flows too (for contrast):**

```bash
hubble observe \
  --namespace shared-services \
  --verdict FORWARDED
# Shows the /api/config request being allowed
```

---

## Stage 4 — ServiceAccount-Scoped CiliumNetworkPolicies (Sync Impersonation)

### Context

Scene 4 exposes a subtle gap: ArgoCD's sync process runs as its own high-privilege ServiceAccount,
not the tenant's. The Rogue Tenant crafts an ArgoCD Application that deploys a permissive
CiliumNetworkPolicy into `tenant-b`'s namespace, punching a hole in their isolation. The fix is
two-part:

1. **ArgoCD sync impersonation** — ArgoCD 2.10+ allows the sync to impersonate the tenant's own
   ServiceAccount. The ArgoCD controller's RBAC only permits the actions that ServiceAccount can
   perform, which means a tenant cannot create resources (including CNPs) in another tenant's
   namespace.

2. **ServiceAccount-scoped CNPs** — CiliumNetworkPolicies that use
   `k8s:io.cilium.k8s.policy.serviceaccount` in their `fromEndpoints` selectors enforce at the
   workload identity level, not just the namespace level. This means a pod running as
   `sa-tenant-a` is treated differently from a pod running as `sa-tenant-b`, even if they are in
   the same namespace.

The network policy design for Stage 4 focuses on point 2 — the SA-scoped CNPs. The sync
impersonation configuration is in `design/04-argocd-security.md`.

### ServiceAccount label convention

Cilium automatically adds the following label to every pod's Cilium identity based on the pod's
`spec.serviceAccountName`:

```
k8s:io.cilium.k8s.policy.serviceaccount=<serviceaccount-name>
```

This label is injected by Cilium from the Kubernetes API — it cannot be spoofed by a tenant
modifying their pod spec, because Cilium reads the actual ServiceAccount binding, not a pod label.

**Flag:** Confirm this with Christian. The label is derived from the pod's ServiceAccount binding
as observed by the Cilium agent, not from pod metadata labels. However, if a tenant can create
pods with arbitrary ServiceAccount names (subject to Kubernetes RBAC), they could potentially
impersonate another ServiceAccount. The RBAC policy that restricts which ServiceAccounts a tenant
can use is therefore a prerequisite for this policy to be meaningful. See Open Question OQ-2.

### Policy manifests

#### 1. SA-scoped ingress on shared-services — only allow known tenant SAs
<!-- STATUS: REVIEWED -->

```yaml
# manifests/stage-4/ciliumnetworkpolicies/shared-services-sa-scoped.yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: config-api-sa-scoped-policy
  namespace: shared-services
spec:
  endpointSelector:
    matchLabels:
      app: config-api
  ingress:
    # Allow tenant-a workload ServiceAccount to reach GET /api/*
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: tenant-a
            k8s:io.cilium.k8s.policy.serviceaccount: sa-tenant-a
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/api/.*"
    # Allow tenant-b workload ServiceAccount to reach GET /api/*
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: tenant-b
            k8s:io.cilium.k8s.policy.serviceaccount: sa-tenant-b
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/api/.*"
    # NOTE: An admin SA rule (e.g., sa-shared-admin) for /admin/* access could be added here
    # for operator use, but is omitted because no such ServiceAccount is defined in the demo.
    # In production, you would add a fromEndpoints rule scoped to a dedicated admin SA.
```

#### 2. SA-scoped egress within tenant-a — restrict which SAs can reach shared-services
<!-- STATUS: REVIEWED -->

```yaml
# manifests/stage-4/ciliumnetworkpolicies/tenant-a-sa-scoped.yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: tenant-a-sa-egress-policy
  namespace: tenant-a
spec:
  # Only the authorised workload SA may egress to shared-services
  endpointSelector:
    matchLabels:
      k8s:io.cilium.k8s.policy.serviceaccount: sa-tenant-a
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: shared-services
            app: config-api
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
          rules:
            dns:
              - matchPattern: "*"
```

#### 3. Mirror for tenant-b
<!-- STATUS: REVIEWED -->

```yaml
# manifests/stage-4/ciliumnetworkpolicies/tenant-b-sa-scoped.yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: tenant-b-sa-egress-policy
  namespace: tenant-b
spec:
  endpointSelector:
    matchLabels:
      k8s:io.cilium.k8s.policy.serviceaccount: sa-tenant-b
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: shared-services
            app: config-api
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
          rules:
            dns:
              - matchPattern: "*"
```

### Interaction with ArgoCD sync impersonation

With sync impersonation enabled, ArgoCD syncs resources using the tenant's ServiceAccount
(`sa-tenant-a`), not the ArgoCD controller SA. This means:

- The ArgoCD sync cannot create `CiliumNetworkPolicy` objects in `tenant-b` because `sa-tenant-a`
  has no RBAC permission to create resources in `tenant-b` namespace.
- The `sa-tenant-a`-scoped CNP on egress ensures that even if a rogue pod somehow runs in
  `tenant-a` without using `sa-tenant-a`, it gets no allowed egress paths (the default-deny
  from Stage 1a covers all pods; the SA-scoped egress rule only opens paths for `sa-tenant-a`
  pods).

This is the two-layer argument: ArgoCD Projects + RBAC prevent the rogue Application from being
created at the orchestration layer; SA-scoped CNPs enforce at the network layer even if the
orchestration layer were somehow bypassed.

### Validation commands

**Confirm the SA label is present on pods:**

```bash
kubectl get pod -n tenant-a -l app=curl-client \
  -o jsonpath='{.items[0].metadata.labels}' | jq .
# You will NOT see the Cilium SA label here — it is a Cilium identity label, not a k8s pod label.
# To confirm Cilium identity, use:

TENANT_A_POD=$(kubectl get pod -n tenant-a -l app=curl-client -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kube-system -l name=cilium -- \
  cilium endpoint list | grep "$TENANT_A_POD"
# Or via cilium CLI if installed locally:
cilium endpoint list --output json | jq '.[] | select(.status["external-identifiers"]["pod-name"] | contains("tenant-a"))'
```

**Attempt cross-SA access (demonstrate the gap before SA scoping):**

This validation is done with standard L7 policy in place but before SA scoping. A pod running
without `sa-tenant-a` can still reach shared-services because the L7 policy selects by namespace,
not SA. After applying Stage 4 SA-scoped policies, the same pod is blocked.

```bash
# Create a test pod in tenant-a with a DIFFERENT service account (simulates rogue pod)
kubectl run rogue-pod -n tenant-a \
  --image=curlimages/curl:latest \
  --serviceaccount=default \
  --restart=Never \
  --command -- sleep 3600

kubectl exec -n tenant-a rogue-pod -- \
  curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
  http://config-api.shared-services.svc.cluster.local:8080/api/config
# Before Stage 4: 200 (namespace selector allows it)
# After Stage 4 SA-scoped policies: 000 (timeout — no egress allowed for 'default' SA)
```

**Hubble observe for SA-level verdict:**

```bash
hubble observe \
  --namespace tenant-a \
  --verdict DROPPED \
  --follow
# Shows flows from the 'default' SA pod being dropped after Stage 4 is applied
```

---

## File Layout

All manifests referenced in this document should live at:

```
manifests/
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
  stage-4/
    ciliumnetworkpolicies/
      shared-services-sa-scoped.yaml
      tenant-a-sa-scoped.yaml
      tenant-b-sa-scoped.yaml
```

---

## Demo Reset Procedure

To reset to a specific stage during rehearsal:

```bash
# Reset to Stage 0 (no policies)
kubectl delete networkpolicy --all --all-namespaces
kubectl delete ciliumnetworkpolicy --all --all-namespaces

# Reset to Stage 1a (standard NPs only)
kubectl delete ciliumnetworkpolicy --all --all-namespaces
kubectl apply -f manifests/stage-1a/networkpolicies/

# Reset to Stage 1b (standard NPs for tenants + CNPs for shared-services and FQDN)
kubectl apply -f manifests/stage-1a/networkpolicies/
kubectl delete networkpolicy -n shared-services --all
kubectl apply -f manifests/stage-1b/ciliumnetworkpolicies/

# Reset to Stage 4 (SA-scoped CNPs)
kubectl apply -f manifests/stage-4/ciliumnetworkpolicies/
```

These commands are idempotent when using `kubectl apply`. Include them as Makefile targets
(e.g., `make reset-stage-0`, `make reset-stage-1a`) as specified in
`design/05-demo-automation.md`.

---

## Pitfalls Called Out in the Talk

These are woven into the live demo moments, not separate slides:

| Pitfall | Where demonstrated | How it appears |
|---------|--------------------|----------------|
| Hardcoded IP CIDRs instead of DNS-aware rules | Stage 1b intro | Christian explains `toFQDNs` as the fix |
| Missing default-deny on new namespaces | Stage 1b (policy gap exists until applied) | The Stage 1a policies omit default-deny until the Platform Engineer adds them |
| Copy-paste CNPs referencing wrong namespace | Scene 3 Beat 1 (drift) | Shown in ApplicationSet scene, not network policy scene |
| Standard NP cannot filter HTTP paths | Stage 1a validation (the /admin 200 response) | The motivating failure for Stage 1b |
| toFQDNs without a DNS intercept rule | Stage 1b design note | Mentioned as a common misconfiguration |

---

## Open Questions

**OQ-1 — HTTP path regex for the shared service router**

The `path` field in `CiliumNetworkPolicy` http rules is a RE2 regex. The exact pattern depends on
how the demo shared service (the config API) handles routing. If it uses exact path matching,
`/api/.*` works. If it uses prefix matching or the router strips query parameters differently, the
regex may need adjustment. Validate the actual HTTP server's routing before the demo.

Candidates to test:
- `/api/.*` (matches /api/ followed by anything, including empty string only if the server sends `/api/`)
- `/api(/.*)?` (also matches bare `/api` with no trailing slash)

Please verify from documentation, this doesn't need to be exhaustive

**OQ-2 — ServiceAccount identity spoofing risk**

If a tenant has RBAC permission to create pods with arbitrary `spec.serviceAccountName` values,
they could run a pod claiming to be `sa-tenant-b`'s ServiceAccount and potentially bypass SA-scoped
policies. The security of SA-scoped CNPs depends on:

1. RBAC restrictions preventing tenants from creating pods with other tenants' ServiceAccounts.
2. Kubernetes admission controllers (e.g., Kyverno) enforcing SA naming conventions.

This is worth discussing with Christian to determine whether to raise it in Scene 4 or defer to a
blog post.

Good question, probably 1 RBAC for now to keep it easier.

**OQ-3 — Scene 4 framing (API-level vs identity-level)**

The talk outline flags this as needing Christian's input. From a network policy perspective:

- The **API-level framing** (sync impersonation prevents ArgoCD from writing CNPs into other
  tenants' namespaces) is straightforward to demonstrate — apply Stage 4 SA-scoped CNPs, show that
  the rogue Application's sync fails due to RBAC on the ServiceAccount.
- The **identity-level framing** (SA-scoped CNPs don't apply during sync because sync runs as
  ArgoCD SA) is subtler and harder to demo — it requires showing that traffic from the ArgoCD
  controller SA takes a different policy path than traffic from the tenant SA.

Recommendation: Lead with the API-level framing (cleaner demo), mention identity-level as an
additional benefit.

Your recommendation is correct

**OQ-4 — Cilium Envoy DaemonSet on KinD**

L7 HTTP policies require the Cilium Envoy proxy. On KinD (Linux kernel), this should work
without special configuration in Cilium 1.13+. However, KinD nodes are Docker containers, and
some kernel features required for Cilium's eBPF programs (particularly `cgroup v2` and
`BPF_PROG_TYPE_CGROUP_SOCK_ADDR`) require the KinD node image to be configured correctly.
Validate that `cilium-envoy` DaemonSet pods are Running after cluster creation before rehearsing
the L7 demo. See `design/01-infrastructure.md` for KinD configuration details.

Noted

**OQ-5 — Hubble output format for conference display**

The `hubble observe` output format depends on the Hubble CLI version. The `--output jsonpb`
flag with `jq` filtering produces dense output; `hubble observe` with default tabular output
is more readable on a projector. Decide on the output format during rehearsal and fix it in the
demo script. The Hubble UI (browser-based) may be more visually impactful for the audience than
a terminal.

We can do either
