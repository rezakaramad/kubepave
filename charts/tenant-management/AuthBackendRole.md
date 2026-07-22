`AuthBackendRole` tells Vault which Kubernetes ServiceAccount may log in and which secrets it may access.

A few things come into play here::
- K8s identity
- External Secret Operator (ESO)
- Vault authenticataion
- Vault policies

# A simple mental model
- K8s SA token → you give it to prove who you are in a K8s cluster
- Vault JWT auth. backend → it's the verification system checking whether K8s really issued the passport
- Vault `AuthBackendRole` → this is basically the rule that defines which identity is allowed to log in or, in other words, which workload in the K8s cluster is allowed to authenticate with Vault.
- Vault policy → this controls what they may access after login.
- Vault token → it's like a temporary access badge which is used by ESO for subsequent Vault requests

# The entire flow in one picture

ESO gets a signed Kubernetes token for the `tenant-eso` ServiceAccount in namespace `foo`.
ESO sends that token to Vault and asks to log in using the Vault role named `foo`.
Vault verifies that Kubernetes issued the token and checks that its audience and ServiceAccount identity match the role’s rules.
Vault reads `foo` from the token’s namespace claim and uses it as the Vault identity alias.
Vault returns a temporary token with the tenant policy, allowing ESO to read secrets only from `foo`’s Vault path.











What the tenant wants to do: A pod in namespace `foo` on the workload cluster needs to read secrets from `tenants/foo/*` in Vault. It uses ESO's SecretStore to do that. ESO needs to log into Vault on behalf of that namespace to get a token scoped to foo's paths.

How Vault knows to trust that ServiceAccount token: Vault doesn't know anything about your workload cluster by default. ESO reads the `tenant-eso` ServiceAccount token from the tenant namespace and presents it to Vault as the login credential. For Vault to accept that token, it needs a role on the JWT auth backend that tells it:
- Which audience to expect on the token
- Which subject (ServiceAccount) is allowed
- Which claim to use as the entity alias (the namespace)
- Which policy to attach to the resulting token

That's exactly what AuthBackendRole creates. Concretely, when ESO in namespace `foo` calls:
```shell
  role=foo
  jwt=<tenant SA token>
```
Vault looks up the `foo` role on `jwt-workload-tenants` and checks:
- Does the token's audience match boundAudiences? ✓
- Does `sub` match `boundSubject` (`system:serviceaccount:foo:tenant-eso`)? ✓
- Is the signature valid against the workload cluster's JWKS? ✓
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
│ jwt-workload-tenants          │
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
