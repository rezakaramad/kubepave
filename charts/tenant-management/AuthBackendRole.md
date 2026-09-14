There are several ways to set up authentication for Kubernetes pods using **short-lived tokens**.
Before getting into it, [read this](./VaultAuthK8s.md) for a quick review of what TokenReview is in Kubernetes.

Before Kubernetes 1.21, ServiceAccount tokens were long-lived and static, minted once, never expiring, stored in a Secret, and reused by every pod on that SA.

A leaked token was therefore a permanent credential: it kept working forever, survived deletion of the pod and SA, and couldn't be revoked without deleting the Secret.

Since 1.21 made pod tokens short-lived, Vault needs a way to validate them, and there are three approaches worth considering. 

Two of them keep using the **Kubernetes auth** method, where Vault calls the **TokenReview API** to check each token; they differ only in which credential Vault presents when it makes that call, the reviewer JWT:

- **Local token as reviewer JWT**: Vault runs inside the cluster and reviews tokens using its own pod's ServiceAccount token, re-reading it from disk as it rotates. Only Vault's ServiceAccount needs the `system:auth-delegator` role. Simplest option, and the recommended one for in-cluster Vault.

**Client JWT as reviewer JWT**: Vault stores no reviewer token at all; it reuses the client's own login token to call TokenReview (the same token is both the credential and the thing being reviewed). This means every client ServiceAccount must hold `system:auth-delegator`, nothing is stored, but there's a binding to maintain per development.

The third approach, **JWT auth**, drops TokenReview entirely. Instead of asking Kubernetes to validate each token, Vault **treats the cluster as an OIDC provider**: it fetches the cluster's **public JWKS** once and verifies every token's signature offline, needing no reviewer JWT and no RBAC on the development cluster. The tradeoff is that tokens can't be revoked before their TTL expires, so the TTL is kept short; and this is the method this platform uses (jwt-development-tenants), because the management Vault validates tokens from remote development clusters it holds no credentials into.

Now let's look into what AuthBackendRole is in Crossplane Vault provider.

> `AuthBackendRole` tells Vault which Kubernetes ServiceAccount may log in and which secrets it may access.

> **Note:** with path-based tenancy this platform no longer creates a per-tenant
> `AuthBackendRole`. A single shared role named `tenant` is created once, centrally,
> by [`setup-openbao.sh`](../../infra/local/kind/setup-openbao.sh); every tenant token
> self-scopes to its own path. The walkthrough below explains the role mechanics
> that role still relies on.

A few things come into play here:
- K8s identity
- External Secret Operator (ESO)
- Vault authentication
- Vault policies

# A simple mental model

- **K8s SA token**: You give it to prove who you are in a K8s cluster
- **Vault JWT auth backend (`jwt-development-tenants`)**: It validates the token signature against the cluster's JWKS and enforces role constraints (`aud` and claim mapping). `jwt-development-tenants` is a custom mount path the bootstrap scripts creates [here](../../infra/local/kind/setup-openbao.sh).
- **Vault `AuthBackendRole`**: This is basically the rule that defines which identity is allowed to log in or, in other words, which development in the K8s cluster is allowed to authenticate with Vault.
- **Vault policy**: This controls what they may access after login.
- **Vault token**: It's like a temporary access badge which is used by ESO for subsequent Vault requests.


# The entire flow in one picture

- ESO gets a signed Kubernetes token for the `tenant-eso` ServiceAccount in the tenant namespace (say, `foo`).

- ESO, then, sends that token to Vault and asks to log in using the shared Vault role named `tenant`.

- Vault receives the JWT, and verifies the signature against JWKS.

- Vault checks the JWT against the shared role's constraints:
  - `aud` must match `boundAudiences`
- If those pass does Vault issue a Vault token. That issued Vault token then carries the Vault policy.

- Vault then attaches `tenant-policy` to the issued Vault token, and that policy resolves the entity alias `foo` (the login namespace) into access only to `kv-development/data/foo/*`. `tenant-policy` is created in the bootstrap script [here](../../infra/local/kind/setup-openbao.sh).

What the tenant wants to do: A pod in namespace `foo` on the development cluster needs to read secrets from `kv-development/data/foo/*` in Vault. It uses the SecretStore to do that. ESO needs to log into Vault on behalf of that namespace to get a token scoped to `foo`'s paths.

How Vault knows to trust that ServiceAccount token: Vault doesn't know anything about your development cluster by default. ESO reads the `tenant-eso` ServiceAccount token from the tenant namespace and presents it to Vault as the login credential.

`tenant-eso` is primarily the identity used by External Secrets Operator through the tenant SecretStore, as wired in [here](../../charts/tenant-workload/templates/secret-store/secret-store.yaml#35). That’s the SA Vault role is bound to.

If a development reads secrets via ExternalSecret/SecretStore, the app Deployment usually does not use `tenant-eso`; ESO uses it to fetch secrets and writes Kubernetes Secrets for the app.

For Vault to accept that token, it needs a role on the JWT auth backend that tells it:
- Which audience to expect on the token
- Which claim to use as the entity alias (the namespace)
- Which policy to attach to the resulting token

That's exactly what the shared `tenant` role provides. Concretely, when ESO in namespace `foo` calls:

```shell
  role=tenant
  jwt=<tenant SA token>
```

Vault looks up the `tenant` role on `jwt-development-tenants` and checks:
- Does the token's `audience` match `boundAudiences`? ✓
- Is the signature valid against the development cluster's JWKS? ✓

If all pass, Vault extracts the `userClaim` (`/kubernetes.io/namespace` → `"foo"`), sets that as the entity alias, and attaches `tenant-policy`. The identity template in `tenant-policy` then expands `{{identity.entity.aliases[<accessor>].name}}` → `foo`, producing a token scoped to `kv-development/data/foo/*` only.

Why one shared role is safe: the role has NO `boundSubject`, so any development-cluster SA with a valid, audience-bound token may log in — but the token is always self-scoped to ITS OWN namespace. Vault sets the entity alias from the `userClaim` (`/kubernetes.io/namespace`), a value signed by the cluster's API server that a tenant cannot forge. `tenant-policy` then resolves that alias into `kv-development/data/<namespace>/*`, so a pod in `foo` can only ever reach `foo`'s path and a pod in `bar` only `bar`'s. The namespace claim — not a per-tenant `boundSubject` — is the boundary, which is why a single role safely serves every current and future tenant.

```
┌───────────────────────────────┐
│ Kubernetes namespace foo      │
│                               │
│ ServiceAccount: tenant-eso    │
│ ESO / SecretStore             │
└───────────────┬───────────────┘
                │
                │ Kubernetes issues signed JWT
                │
                ▼
┌───────────────────────────────┐
│ JWT claims                    │
│                               │
│ sub = system:serviceaccount:  │
│       foo:tenant-eso          │
│ aud = vault                   │
│ namespace = foo               │
└───────────────┬───────────────┘
                │
                │ role=tenant, jwt=<token>
                ▼
┌───────────────────────────────┐
│ Vault JWT auth backend        │
│ jwt-development-tenants          │
│                               │
│ 1. Verify signature/JWKS      │
│ 2. Find role "tenant"         │
│ 3. Check audience             │
│ 4. Extract namespace "foo"    │
└───────────────┬───────────────┘
                │
                │ Returns temporary Vault token
                ▼
┌───────────────────────────────┐
│ Vault token                   │
│                               │
│ Policy: tenant-policy         │
│ Alias: foo                    │
│ Access: kv-development/data/foo/* │
└───────────────────────────────┘
```
