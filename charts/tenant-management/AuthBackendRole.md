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

A few things come into play here:
- K8s identity
- External Secret Operator (ESO)
- Vault authentication
- Vault policies

# A simple mental model

- **K8s SA token**: You give it to prove who you are in a K8s cluster
- **Vault JWT auth backend (`jwt-development-tenants`)**: It validates the token signature against the cluster's JWKS and enforces role constraints (`aud`, `sub`, and claim mapping). `jwt-development-tenants` is a custom mount path the bootstrap scripts creates [here](../../infra/local/kind/setup-vault.sh#248).
- **Vault `AuthBackendRole`**: This is basically the rule that defines which identity is allowed to log in or, in other words, which development in the K8s cluster is allowed to authenticate with Vault.
- **Vault policy**: This controls what they may access after login.
- **Vault token**: It's like a temporary access badge which is used by ESO for subsequent Vault requests.


# The entire flow in one picture

- ESO gets a signed Kubernetes token for the `tenant-eso` ServiceAccount in the tenant namespace (say, `foo`).

- ESO, then, sends that token to Vault and asks to log in using the Vault role named `foo`.

- Vault receives the JWT, and verifies the signature against JWKS.

- Vault checks the JWT against the `AuthBackendRole` constraints:
  - `aud` must match `boundAudiences`
  - `sub` must match `boundSubject`
- If those pass does Vault issue a Vault token. That issued Vault token then carries the Vault policy.

- Vault then attaches `tenant-policy` to the issued Vault token, and that policy resolves the entity alias `foo` into access only to `tenants/data/foo/*`. `tenant-policy` is created in the bootstrap script [here](../../infra/local/kind/setup-vault.sh#276).

What the tenant wants to do: A pod in namespace `foo` on the development cluster needs to read secrets from `tenants/foo/*` in Vault. It uses the SecretStore to do that. ESO needs to log into Vault on behalf of that namespace to get a token scoped to `foo`'s paths.

How Vault knows to trust that ServiceAccount token: Vault doesn't know anything about your development cluster by default. ESO reads the `tenant-eso` ServiceAccount token from the tenant namespace and presents it to Vault as the login credential.

`tenant-eso` is primarily the identity used by External Secrets Operator through the tenant SecretStore, as wired in [here](../../charts/tenant-workload/templates/secret-store/secret-store.yaml#35). That’s the SA Vault role is bound to.

If a development reads secrets via ExternalSecret/SecretStore, the app Deployment usually does not use `tenant-eso`; ESO uses it to fetch secrets and writes Kubernetes Secrets for the app.

For Vault to accept that token, it needs a role on the JWT auth backend that tells it:
- Which audience to expect on the token
- Which subject (ServiceAccount) is allowed
- Which claim to use as the entity alias (the namespace)
- Which policy to attach to the resulting token

That's exactly what AuthBackendRole creates. Concretely, when ESO in namespace `foo` calls:

```shell
  role=foo
  jwt=<tenant SA token>
```

Vault looks up the `foo` role on `jwt-development-tenants` and checks:
- Does the token's `audience` match `boundAudiences`? ✓
- Does `sub` match `boundSubject` (`system:serviceaccount:foo:tenant-eso`)? ✓
- Is the signature valid against the development cluster's JWKS? ✓

If all pass, Vault extracts the `userClaim` (`/kubernetes.io/namespace` → `"foo"`), sets that as the entity alias, and attaches `tenant-policy`. The identity template in `tenant-policy` then expands `{{identity.entity.aliases[<accessor>].name}}` → `foo`, producing a token scoped to `tenants/data/foo/*` only.

Why one role per tenant: Each tenant has a different `boundSubject` (`system:serviceaccount:bar:tenant-eso` for `bar`, `foo` for `foo`) and a different `roleName`. Vault uses the role name in the login URL to look up the constraints. If you had one shared role, you couldn't restrict which namespace's SA can use it; any SA could log in and claim any namespace. The per-tenant role is what makes `boundSubject` enforceable.

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
                │ role=foo, jwt=<token>
                ▼
┌───────────────────────────────┐
│ Vault JWT auth backend        │
│ jwt-development-tenants          │
│                               │
│ 1. Verify signature/JWKS      │
│ 2. Find role "foo"            │
│ 3. Check audience             │
│ 4. Check subject              │
│ 5. Extract namespace "foo"    │
└───────────────┬───────────────┘
                │
                │ Returns temporary Vault token
                ▼
┌───────────────────────────────┐
│ Vault token                   │
│                               │
│ Policy: tenant-policy         │
│ Alias: foo                    │
│ Access: tenants/data/foo/*    │
└───────────────────────────────┘
```
