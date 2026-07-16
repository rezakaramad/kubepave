# Vault

Standalone Vault bootstrapped via a `postStart` hook (init, unseal, policies, KV
engine). JWT auth backends and roles are configured afterwards by
[`setup-vault.sh`](../../infra/local/kind/setup-vault.sh).

## Auth

One JWT backend per cluster, mounted at `jwt-<cluster>` (e.g. `jwt-management`,
`jwt-workload`). Vault validates pod ServiceAccount tokens by fetching each
cluster's JWKS directly from its API server — no long-lived reviewer token.

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
