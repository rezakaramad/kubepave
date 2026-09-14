Before diving into tenancy strategy, let's review some fundamental concepts in Vault/OpenBao:
**mount**, **paths** and **namespaces**.

# Mount
In Vault/OpenBao, a mount is a entry point to a *secrets engine* or *auth method*.

For example, suppose you enable the KV v2 secrets engine at:
```
secret/
```

That means:
- `secret/` is the mount point
- KV v2 is the **secrets engine** running at that mount
- Requests hitting `secret/` are routed to that KV engine.

For example:
```
secret/data/app/password
```

Roughly means:
> Route the request to the KV engine mounted at `secret/`, then handle `data/app/password` according to the KV v2 API.

There are two kinds of things you mount in Vault/OpenBao:
- **Secrets engines**: used to store, generate, or transform secrets
- **Auth methods**: used to log users or machines in. Auth methods are mounted under `auth/`

If you're curious what secret engines are supported, go read [the official doc](https://openbao.org/docs/next/secrets/).

OpenBao supports multiple authentication backends, documented [here](https://openbao.org/docs/concepts/identity/#mount-bound-aliases).

# Path

A path identifies both *who should handle* a request and *what operation/resource* the request refers to.

A Vault/OpenBao path is an **API route** in a hierarchical namespace. The first part typically selects a mounted backend, and the remaining path is **interpreted** by that backend.

A way to visualize the whole flow is:
```
Client
  |
  | GET /v1/apps/data/myapp/database
  v
+-----------------------+
| OpenBao HTTP API      |
+-----------------------+
          |
          | inspect path
          v
+-----------------------+
| Router                |
| apps/* -> KV engine A |
+-----------------------+
          |
          | data/myapp/database
          v
+-----------------------+
| KV v2 engine          |
|                       |
| route: data/:path     |
+-----------------------+
          |
          | reads its isolated
          | storage view
          v
+-----------------------+
| Encrypted storage     |
+-----------------------+
```
Before the engine is allowed to service the request, OpenBao evaluates the client’s token policies against the requested path and capability.

> Path = mount point + engine-specific API route + resource name.

**NOTE:** `data/` is specific to KV v2. Other secret engines define completely different endpoint names based on what they do.

For example, the **Transit** engine exposes endpoints such as:

```
transit/keys/my-key
        ^^^^
        manage encryption keys

transit/encrypt/my-key
        ^^^^^^^
        encrypt with that key

transit/decrypt/my-key
        ^^^^^^^
        decrypt with that key
```
Transit uses endpoints like `keys`, `encrypt`, `decrypt`, and `rewrap`.

The **Database** secrets engine looks different:
```
database/config/my-postgres
         ^^^^^^
         configure a database connection

database/roles/app-role
         ^^^^^
         define how credentials should be generated

database/creds/app-role
         ^^^^^
         generate dynamic credentials
```
So the path structure is defined by the secrets engine itself.

# Namespace

Namespaces are isolated environments that functionally behave like *Vaults within a Vault*.

Each namespace can manage its own:

- auth methods
- policies
- secrets engines
- identities
- groups
- tokens

This isolation makes namespaces suitable for multi-tenancy. Each tenant can operate within its own namespace without having access to resources belonging to another tenant.

Because auth methods are mounted inside a namespace, authentication is namespace-scoped. OpenBao therefore needs to know both the auth path and the namespace in which that auth method exists.

The namespace can be supplied either as part of the API path or through the `X-Vault-Namespace` header.

For example:
```sh
tenants/pillow-factory/auth/oidc/login
```

or:

```sh
auth/oidc/login
X-Vault-Namespace: tenants/pillow-factory/
```

Both identify the OIDC auth method inside the `tenants/pillow-factory/` namespace.

The namespace determines which instance of the auth method, policies, identities, tokens, and other resources the request is operating against.

# Isolation strategies

There are three levels of isolation to think about.

## Namespace-based isolation

*create a namespace for each tenant*. Each tenant gets a full mini-Vault (own mounts, policies, auth, identities, tokens). Strong isolation, supports delegating admin to the tenant.

This provides the strongest tenant-level administrative separation and supports delegating administration to the tenant.

> Without namespace-based isolation:
> - Teams can still be separated using *paths*, *mounts*, and *ACLs*, but they remain part of the same overall administrative and identity domain.
> - With path-based isolation, a badly written *ACL* such as `secret/data/*` can accidentally cross tenant boundaries.
> - Safe delegation becomes harder because giving a team more control over its own area can also require permissions that reach beyond that tenant boundary.

## Mount/path-based isolation

Keep teams within one shared namespace and separate them either by giving each team its own **secrets-engine mount** (e.g. `team-a-kv/`, `team-b-kv/`) or **its own path prefix** within a shared mount, with **ACL policies** restricting each team to its mount/path. This is lighter weight than namespace-based isolation, but provides weaker tenant separation and less clean per-tenant administration.

These lead to two slightly different setups.

Path-based isolation optimizes for simplicity. Mount-based isolation trades some simplicity for stronger separation and independent secrets-engine configuration. Both are lighter-weight than namespace-based isolation, but they provide weaker tenant separation and no per-tenant self-administration.

# Chosen approach: path-based isolation

In *kubepave* uses **path-based isolation within a single namespace**, not
namespaces-per-tenant.

**Layout**
- **One KV v2 secrets engine per cluster**, named after the cluster it serves,
  matching the existing `jwt-<cluster>` *auth-mount* convention: `kv-management/`,
  `kv-development/`.
- Inside each mount, every tenant owns a **path prefix**: `kv-<cluster>/data/<tenant>/*`
  (e.g. `kv-development/data/pillow-factory/*`).
- Tenants are confined to their prefix by a single **identity-templated ACL policy**;
  the tenant segment is resolved from the caller's verified identity, not from user input.

**Why this approach**
- **Developers only need CRUD on their own secrets.** They do not create mounts,
  policies, auth methods, or child namespaces; so the main reason to adopt
  namespaces (administration *delegation*) does not apply here.
- **No namespace-switching friction.** With one namespace, operators log in and
  land directly on their secrets. There is no "authenticate at root, then switch
  namespace" step, and no per-namespace auth mounts to provision.
- **Zero-touch onboarding + scaling.** A new tenant needs no new mount and no new
  policy; the templated policy (`kv-<cluster>/data/{{identity.entity.metadata.tenant}}/*`)
  already scopes every tenant automatically. This scales to many tenants cheaply,
  without per-mount overhead.
- **Simplicity of operation.** One engine, one policy template, one login path.

**Why not the alternatives**
- *Namespace-per-tenant*: strongest isolation and delegation, but heavier; a full
  mini-Vault per tenant, per-namespace auth, and the login-then-switch UX. Overkill
  for a CRUD-only IDP.
- *Mount-per-tenant*: firmer structural boundary and per-team engine tuning, but
  requires provisioning a mount per tenant and it becomes more cumbersome to manage as the number of tenants grows. Not needed when every tenant uses the same KV v2 configuration.

**Trade-off we accept**
Path-based isolation is enforced **entirely by ACL policy** (namespaces isolate
structurally). That places the burden on getting the policy right:
- the tenant segment MUST come from a trusted claim mapped into entity metadata;
- **no** `list`/`read` may be granted at or above the mount root (in KV v2 that is
  `kv-<cluster>/metadata/`), or tenants could enumerate other tenants' prefixes;
- **no** bare wildcards (`kv-<cluster>/data/*`) — the tenant segment always precedes the
  glob.

With those rules, one tenant has no path by which to reach another's secrets. See
the isolation policy and verification steps in the setup for the enforced template.
