# OpenBao

Standalone OpenBao bootstrapped via a `postStart` hook (init, unseal, policies, KV
engines). JWT auth backends and roles are configured afterwards by
[`setup-openbao.sh`](../../infra/local/kind/setup-openbao.sh).

OpenBao is an open-source fork of Vault; the chart, CLI (`bao`), and API are
drop-in compatible. This chart mirrors the [`vault`](../vault) chart so the two
can be swapped without touching downstream consumers.

## Auth

One JWT auth backend per cluster, mounted at `jwt-<cluster>` (e.g. `jwt-management`,
`jwt-development`). Each backend is configured to trust that cluster's API server as
an OIDC identity provider; OpenBao fetches the public signing keys (JWKS) directly
from `https://<cluster-node-ip>:6443/openid/v1/jwks` at setup time.

### How a development authenticates

1. **Token request** — the pod asks its cluster's API server for a short-lived,
   audience-scoped ServiceAccount token (`TokenRequest` API). ESO does this
   automatically before each OpenBao call.

2. **Login** — the pod calls `POST /v1/auth/jwt-<cluster>/login` on OpenBao, sending
   the token and the role name (e.g. `eso-shared`).

3. **Verification** — OpenBao validates the JWT cryptographically using the cached
   public keys, then checks three claims against the role definition:
   - `iss` — must equal `bound_issuer` (`https://kubernetes.default.svc.cluster.local`)
   - `aud` — must equal `bound_audiences` (same value)
   - `sub` — must equal `bound_subject` (e.g. `system:serviceaccount:platform-system:external-secrets`)

4. **OpenBao token** — if all checks pass, OpenBao issues a short-lived token
   (TTL 1h) scoped to the role's policy. The pod uses it to read secrets, then
   discards it.

No shared secret or long-lived credential is involved. OpenBao only holds public
keys; the pod proves its identity with a token signed by its own cluster.

## Mounts

Everything lives in a single (root) namespace; isolation is by **path + ACL**, never
by namespace. There are three root KV v2 mounts:

| Mount | Purpose | Path convention |
| --- | --- | --- |
| `kv` | Platform-component secrets | `kv/data/<component>/*` |
| `kv-management` | Management-cluster tenant secrets | `kv-management/data/<tenant>/*` |
| `kv-development` | Development-cluster tenant secrets | `kv-development/data/<tenant>/*` |

Tenants are confined to their own `<tenant>/*` prefix by a single identity-templated
policy; see [`TENANCY.md`](TENANCY.md) for the path-based isolation design.

## Policies

Platform-component secrets live under the root `kv` mount.

| Policy | Paths | Capabilities |
| --- | --- | --- |
| `eso-shared-policy` | `kv/data/shared/*` | read |
| `eso-platform-system-policy` | `kv/data/platform/*` | read |
| `eso-argocd-policy` | `kv/data/argocd/*` | read |
| `backstage-policy` | `kv/data/backstage/*` | read |
| `crossplane-policy` | `kv/data/crossplane/*`, `kv/data/shared/*` | read |
| `keycloak-policy` | `kv/data/keycloak/*` | read, create, update, patch |

Tenants share one identity-templated `tenant-policy` that resolves to
`kv-<cluster>/data/<tenant>/*` from the caller's verified auth alias name, so a new
tenant needs no new policy.

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

Tenants use a single shared `tenant` role on the `jwt-development-tenants` backend.
It has no `bound_subject`; the issued token self-scopes to the calling tenant via
its verified alias name (the workload namespace), so one role serves every tenant
with zero per-tenant provisioning.
