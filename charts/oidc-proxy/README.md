# oidc-proxy

Exposes the Kubernetes API server's OIDC discovery endpoints via Traefik so that
Vault can fetch the cluster's public signing keys (JWKS) and validate pod JWTs
without a long-lived reviewer token.

## How it works

Vault's JWT auth backend needs to reach two endpoints on each cluster it authenticates against:

```
/.well-known/openid-configuration   — OIDC discovery document
/openid/v1/jwks                     — public signing keys
```

These are served by the API server but only reachable at
`kubernetes.default.svc.cluster.local`, a cluster-internal address. In managed
Kubernetes services such as GKE and EKS, the OIDC endpoints are exposed by
default, so no additional configuration is required.

This chart exposes them at a stable external hostname (e.g. `oidc.wl.rezakara.demo`)
using four resources:

- **`HTTPRoute`** — routes only the two OIDC paths to the built-in `kubernetes`
  Service in the `default` namespace. That Service is a real ClusterIP with
  endpoints to the API server and exists on every cluster.
- **`ReferenceGrant`** (in `default`) — allows the HTTPRoute in `platform-system`
  to reference the `kubernetes` Service cross-namespace, as required by Gateway API.
- **`BackendTLSPolicy`** (in `default`) — tells Traefik to speak TLS to the API
  server and verify its cert against the `kube-root-ca.crt` ConfigMap (auto-created
  by Kubernetes in every namespace).
- **`ClusterRoleBinding`** — grants anonymous (`system:unauthenticated`) callers
  read access to the discovery endpoints via the built-in
  `system:service-account-issuer-discovery` ClusterRole. Requests through Traefik
  carry no credentials, so without this the API server returns 403.

Vault is then configured with `jwks_url` (not `oidc_discovery_url`) pointing at
`https://<hostname>/openid/v1/jwks`, plus `bound_issuer` set to the pod-token
issuer. `jwks_url` is used because `oidc_discovery_url` requires the discovery
document's `issuer` to equal the URL, but Kubernetes stamps tokens with
`https://kubernetes.default.svc.cluster.local` while we fetch through the proxy
hostname — those never match.

## Why the built-in `kubernetes` Service (not ExternalName)

Traefik does **not** support `ExternalName` Services as HTTPRoute backends
(`type ExternalName is not supported for Kubernetes Service reference`). The
built-in `kubernetes` Service in `default` is a real backend with endpoints to
the API server, so we target it cross-namespace via a `ReferenceGrant` instead.

## When this chart is NOT needed

- **Cloud managed clusters (GKE, EKS, AKS)**: the OIDC endpoint is public and
  managed by the cloud provider. Configure Vault's `oidc_discovery_url` directly
  with the provider's URL.

## On-prem usage

This chart works as-is on real on-prem clusters, no changes needed. The
`kubernetes` Service, `kube-root-ca.crt` ConfigMap, and
`system:service-account-issuer-discovery` ClusterRole are present on every
Kubernetes cluster. The only thing that needs setting per environment is the
`hostname` value in this chart. Everything else is portable.
