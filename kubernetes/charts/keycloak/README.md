# Keycloak

Keycloak v26 deployed as an identity broker for the management cluster. All real user identities come from Entra ID; Keycloak acts as the single OIDC provider downstream apps (ArgoCD, Vault, etc.) trust.

## Architecture

```
Entra ID (upstream IdP)
    │  OIDC broker (keycloak.m.crossplane.io provider)
    ▼
Keycloak  ──► management realm
    │              │
    │              ├── Azure OIDC IdentityProvider (idp.yaml)
    │              ├── Attribute mappers: email, username, given_name, family_name (idp-mappers.yaml)
    │              ├── Group mappers: Entra group → Keycloak group (idp-mappers.yaml, values-driven)
    │              ├── Groups + Roles (groups.yaml, roles.yaml)
    │              └── realm-management client (client.yaml)
    │
    └── master realm
           └── crossplane-admin client (service account, created by bootstrap Job)
```

## Deployment

Deployed via ArgoCD. The chart provisions everything in the `keycloak` namespace using ArgoCD sync waves:

| Wave | What happens |
|------|--------------|
| -10  | ExternalSecrets for `keycloak-admin` and `azuread` credentials are created |
| 5    | Bootstrap Job runs (see below) |
| 20   | `crossplane` credentials secret is materialised from Vault (written by the Job) |
| 25   | Keycloak `management` Realm is created via Crossplane |
| 30   | Groups (`platform-admins`) created |
| 35   | `realm-management` client observed |
| 40   | Roles created and assigned to groups |
| 45   | Azure OIDC IdentityProvider configured |
| 50   | Attribute and group mappers configured |

The StatefulSet and PostgreSQL (`cloudnative-pg`) are deployed independently by the Keycloak Helm chart dependency. Keycloak is exposed at `https://oidc.mgmt.rezakara.demo` via a Traefik HTTPRoute.

## Secrets from Vault

All secrets are synced from Vault via ExternalSecret:

| K8s Secret | Vault Path | Purpose |
|---|---|---|
| `keycloak-admin` | `keycloak/admin` | Keycloak `admin` user credentials; also used by the StatefulSet as `KC_BOOTSTRAP_ADMIN_*` |
| `azuread` | `keycloak/azure/apps/keycloak` | Entra ID app `client_id` + `client_secret` for the OIDC broker |
| `crossplane` | `keycloak/crossplane` | `crossplane-admin` client credentials; written by the bootstrap Job, read by the Crossplane Keycloak provider |

## Bootstrap Job

The Job runs once at sync-wave 5, before Crossplane configures any realm resources. It:

1. Waits for Keycloak to be reachable on TCP
2. Authenticates to Keycloak as the `admin` user (from `keycloak-admin` secret)
3. Authenticates to Vault using the `keycloak` ServiceAccount (Kubernetes auth, role `keycloak`)
4. Creates the `crossplane-admin` OIDC client in the `master` realm (service account client, no user login)
5. Grants the `admin` realm role to the client's service account
6. Fetches the generated client secret and writes it to `local/keycloak/crossplane` in Vault

The Job is idempotent — it checks for the client's existence before creating it.

The `keycloak` ServiceAccount is shared between the StatefulSet (used by ExternalSecrets to sync secrets from OpenBao) and the bootstrap Job. A single OpenBao role (`keycloak`) bound to this SA covers both use cases via the `keycloak-policy`, which grants read/write access to `kv/data/keycloak/*` (in the `platform` namespace).

## Crossplane Realm Configuration

Once the bootstrap Job completes, the `crossplane` secret is populated and the Crossplane Keycloak provider (`keycloak.m.crossplane.io`) can authenticate. It then reconciles the remaining resources in sync waves 25–50.

### Entra ID Integration

Keycloak federates authentication to Entra ID via OIDC brokering. The tenant ID and sync mode are templated from `values.yaml`:

```yaml
entraId:
  tenantId: <tenant-uuid>
  syncMode: IMPORT   # IMPORT or FORCE
  groupMappings:
    - name: azure-platform-admins
      aadGroupId: <entra-group-uuid>
      keycloakGroup: /platform-admins
```

- **`syncMode`** on the IDP controls when Keycloak re-imports the user profile. All attribute mappers (email, username, name) use `FORCE` — attributes are overwritten from the Entra ID token on every login.
- **`groupMappings`** is a list — each entry generates an `oidc-advanced-group-idp-mapper` that maps an Entra ID security group (by object ID from the `groups` claim) to a Keycloak group. To add a new group, add an entry here; no template changes needed.
- The Entra ID app registration must include `SecurityGroup` or `ApplicationGroup` in its group claims configuration. Using `ApplicationGroup` (groups assigned to the app) avoids the >200-group token overage problem.

## Security Considerations

**Admin credentials in Kubernetes**

The `keycloak-admin` Secret is unavoidable for the StatefulSet — Keycloak requires `KC_BOOTSTRAP_ADMIN_USERNAME` and `KC_BOOTSTRAP_ADMIN_PASSWORD` env vars to create the initial admin on first boot. After that first startup, Keycloak ignores those env vars entirely. 

**Known improvement — bootstrap Job credential exposure**

The Job currently reads `ADMIN_USER`/`ADMIN_PASSWORD` from the `keycloak-admin` Secret as env vars. A stricter approach: move the Vault fetch to the start of the Job script, pull credentials at runtime via `vault kv get`, and remove the env vars from the Job spec entirely. This limits the admin credentials to the StatefulSet only.

**NOTE:** Keycloak is the authentication gateway for all downstream services. A Keycloak outage means users cannot log in to any of these services. Current setup runs a single instance, suitable for local development setup and showcasing.


## For a production-ready version ..

A few things to consider:

- If Keycloak is running in a cluster shared across multiple platform teams, there are a few things to think about, like access control, protecting Keycloak from ongoing development work, and keeping it as stable as possible.

- Running enough Keycloak and database replicas to handle the expected scale (the required [`ispn` cache mode](https://www.keycloak.org/server/caching) should be configured). With `ispn` you're basically telling Keycloak to use distributed caching so multiple replicas can run together as a cluster and share session-related data.

- A dedicated **identity cluster** might be one step to make this better
    - Security boundary
    - Blast radius isolation
    - Upgrade independence
    - Audit separation / compliance
    - Stable / low-churn environment

**The trade-off:** The overhead of maintaining one more cluster. 
