# ArgoCD

App-of-Apps GitOps hub running in the management cluster. Manages the workload
platform stack (cert-manager, external-secrets, Traefik, external-dns, Crossplane).

## How ArgoCD authenticates to workload clusters

### Current setup (local kind)

ArgoCD uses the **pull model** with a **long-lived ServiceAccount token**. During
`setup-secrets.sh`, an `argocd-manager` SA with `cluster-admin` binding is
created on each workload cluster, and a permanent `kubernetes.io/service-account-token`
secret is generated for it:

```
setup-secrets.sh
  → creates argocd-manager SA + ClusterRoleBinding on workload
  → generates a long-lived SA token Secret
  → stores { server, token } in Vault at local/argocd/clusters/<name>
  → ESO materialises it as an ArgoCD cluster Secret in the argocd namespace
  → ArgoCD uses that token to reach https://<node-ip>:6443
```

The token **never expires** and is the one remaining static long-lived credential
in this setup.

### Why the long-lived token exists here

The current ArgoCD cluster registration API expects a static `{ server, token }`
pair in a `Secret`. ArgoCD itself reads that secret and uses the token for every
`kubectl` operation against the workload cluster. It has no native support for
calling `TokenRequest` on each use.

### How to mature this

**Option 1 — ArgoCD Agent (argocd-agent)**
The proper fix. An agent pod runs *on the workload cluster* and initiates an
outbound connection to the ArgoCD server. No inbound token needed on the hub side.
The hub never holds a credential for the spoke; the spoke authenticates to the hub.
This is the direction ArgoCD is investing in for hub-and-spoke production setups
and is directly analogous to how SPIRE works.

**Option 2 — `execProviderConfig` on the cluster Secret**
ArgoCD cluster Secrets support an `exec` credential plugin block. You configure
ArgoCD to call an external binary that calls `kubectl create token argocd-manager`
(the `TokenRequest` API, short-lived) on each use. More complex to wire up, but
eliminates the static token without waiting for the agent model to mature.

**Option 3 — Periodic rotation**
Simplest. A CronJob re-generates the SA token on a schedule. Doesn't eliminate
the long-lived nature but limits the blast radius. Acceptable for non-critical
environments where the agent model hasn't landed yet.

### How GKE / Workload Identity solves this

On GKE, this problem disappears because ArgoCD (running on GKE) can be given a
**Kubernetes ServiceAccount bound to a GCP Service Account** via Workload
Identity Federation. The flow:

```
ArgoCD pod (KSA: argocd-server)
  → Kubernetes automatically mounts a short-lived OIDC token (aud: GCP STS)
  → GCP STS exchanges it for a GCP access token (via WIF binding)
  → ArgoCD uses the GCP access token to call the GKE API (not a static SA token)
```

For a GKE workload cluster, ArgoCD can authenticate to it with a GCP identity
rather than a static `argocd-manager` token — either by using the GKE Connect
Gateway (which accepts GCP IAM identities) or by binding the ArgoCD GSA to the
appropriate GKE RBAC role via `gcloud container clusters get-credentials`.

In practice on GCP the setup is:

1. ArgoCD's KSA is annotated with a GSA (`iam.gke.io/gcp-service-account`).
2. The GSA is granted `roles/container.developer` (or a custom role) on the
   target GKE project.
3. ArgoCD uses the GKE Connect Gateway endpoint
   (`https://connectgateway.googleapis.com/v1/projects/.../locations/...`)
   instead of a direct API server IP.
4. No static token anywhere — GCP STS issues a fresh access token on every call
   and it expires in 1 hour.

This is the GCP-native equivalent of the ArgoCD Agent: identity flows through the
cloud IAM plane, not through a stored credential.
