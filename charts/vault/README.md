# Vault

Standalone Vault bootstrapped via a `postStart` hook (init, unseal, policies, KV
engine). JWT auth backends and roles are configured afterwards by
[`setup-vault.sh`](../../infra/local/kind/setup-vault.sh).

## Auth

One JWT auth backend per cluster, mounted at `jwt-<cluster>` (e.g. `jwt-management`,
`jwt-development`). Each backend is configured to trust that cluster's API server as
an OIDC identity provider; Vault fetches the public signing keys (JWKS) directly
from `https://<cluster-node-ip>:6443/openid/v1/jwks` at setup time.

### How a development authenticates

1. **Token request** — the pod asks its cluster's API server for a short-lived,
   audience-scoped ServiceAccount token (`TokenRequest` API). ESO does this
   automatically before each Vault call.

2. **Login** — the pod calls `POST /v1/auth/jwt-<cluster>/login` on Vault, sending
   the token and the role name (e.g. `eso-shared`).

3. **Verification** — Vault validates the JWT cryptographically using the cached
   public keys, then checks three claims against the role definition:
   - `iss` — must equal `bound_issuer` (`https://kubernetes.default.svc.cluster.local`)
   - `aud` — must equal `bound_audiences` (same value)
   - `sub` — must equal `bound_subject` (e.g. `system:serviceaccount:platform-system:external-secrets`)

4. **Vault token** — if all checks pass, Vault issues a short-lived Vault token
   (TTL 1h) scoped to the role's policy. The pod uses it to read secrets, then
   discards it.

No shared secret or long-lived credential is involved. Vault only holds public
keys; the pod proves its identity with a token signed by its own cluster.

## Policies

All paths are under the `local` KV v2 mount.

| Policy | Paths | Capabilities |
| --- | --- | --- |
| `eso-shared-policy` | `shared/*` | read |
| `eso-platform-system-policy` | `platform/*` | read |
| `eso-argocd-policy` | `argocd/*` | read |
| `crossplane-policy` | `crossplane/*`, `shared/*` | read |
| `keycloak-policy` | `keycloak/*` | read, create, update, patch |

## Roles

Each role binds a ServiceAccount (`bound_subject`) to a policy. Roles exist under
every cluster's `jwt-<cluster>` backend, except `keycloak` (management only).

| Role | ServiceAccount | Policy |
| --- | --- | --- |
| `eso-shared` | `platform-system:external-secrets` | `eso-shared-policy` |
| `eso-platform-system` | `platform-system:external-secrets` | `eso-platform-system-policy` |
| `eso-argocd` | `argocd:argocd-server` | `eso-argocd-policy` |
| `crossplane` | `crossplane-system:crossplane` | `crossplane-policy` |
| `keycloak` | `keycloak:keycloak` | `keycloak-policy` |
