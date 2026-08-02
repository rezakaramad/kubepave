# Vault SSO for tenant operators (Policy + Group + GroupAlias)

`AuthBackendRole` (see the sibling doc) is for **machines** — a pod logs into Vault
with its Kubernetes ServiceAccount token.

These three objects are for **humans** — a tenant operator logs into the Vault UI/CLI
with their Azure Entra ID account and should see **only their own tenant's secrets**.

They are created per tenant by this chart:
- `Policy`      → the permissions
- `Group`       → the bucket that carries the permissions
- `GroupAlias`  → the rule that decides who lands in the bucket

# A simple mental model — the building keycard

- **Policy** = the list of doors a card can open (e.g. only the `pillow-factory` room).
- **Group** = a type of keycard (the "Pillow-Factory card") that carries that door list.
- **GroupAlias** = the front-desk rule: "anyone whose badge says `pillow-factory` gets the Pillow-Factory card."
- **The Entra label** = the `roles` claim in the login token. It says the tenant name (`pillow-factory`).

One sentence:

> When a person logs in, Entra ID stamps their token with their tenant name.
> The **GroupAlias** sees that stamp and drops them into the matching **Group**,
> which carries the **Policy** that unlocks only their tenant's folder.

# Where the "label" comes from

The label is not magic — the platform puts it there. For every tenant, the
`xtenantentra` Crossplane function creates on the Entra side:

1. An **App Role** on the Vault app registration with `Value = <tenant name>`.
2. An Entra **security group** the tenant's people belong to.
3. A **role assignment** linking that group to the app role.

So: user is in the Entra group → group has the app role → Entra puts `<tenant name>`
into the token's `roles` claim. That is the same label ArgoCD SSO already uses.

# What each object looks like (for `pillow-factory`)

```yaml
# 1. Policy — the actual permissions
kind: Policy            # tenant-pillow-factory
policy: |
  path "tenants/data/pillow-factory/*"     { capabilities = [read,list,create,update,delete] }
  path "tenants/metadata/pillow-factory/*" { capabilities = [read,list,delete] }

# 2. Group — carries the policy, membership decided at login (type: external)
kind: Group             # vault-tenant-pillow-factory
type: external
policies: [tenant-pillow-factory]

# 3. GroupAlias — matches the Entra label to the group
kind: GroupAlias
name: pillow-factory              # MUST equal the roles-claim value
mountAccessor: <oidc accessor>    # only for the 'oidc' login method
canonicalIdRef: vault-tenant-pillow-factory
```

# The entire flow in one picture

A tenant operator runs `vault login -method=oidc` and is sent to Entra ID.
Entra returns a signed token whose `roles` claim contains the tenant name.
Vault's `oidc` role reads that claim (`groups_claim=roles`) and looks for a
GroupAlias with the same name on the `oidc` method. If it matches, the user's
entity joins the external Group for this session, which attaches the tenant
Policy — so the token can touch only `tenants/.../pillow-factory/*`.
No match means only the built-in `default` policy: no tenant access at all.

```
┌───────────────────────────────┐
│ Tenant operator (a person)    │
│ vault login -method=oidc      │
└───────────────┬───────────────┘
                │ browser redirect
                ▼
┌───────────────────────────────┐
│ Azure Entra ID                │
│                               │
│ user ∈ tenant group           │
│ group ↔ app role (Value=      │
│         pillow-factory)       │
└───────────────┬───────────────┘
                │ signed ID token
                │ roles = ["pillow-factory"]   ← the label
                ▼
┌───────────────────────────────┐
│ Vault oidc auth method        │
│ role "default"                │
│ groups_claim = roles          │
│ reads "pillow-factory"        │
└───────────────┬───────────────┘
                │ match by name + oidc accessor
                ▼
┌───────────────────────────────┐
│ GroupAlias                    │
│ name = pillow-factory         │
└───────────────┬───────────────┘
                │ canonicalIdRef
                ▼
┌───────────────────────────────┐
│ External Group                │
│ vault-tenant-pillow-factory   │
│ policies = [tenant-...]       │
└───────────────┬───────────────┘
                │ attaches
                ▼
┌───────────────────────────────┐
│ Policy tenant-pillow-factory  │
│                               │
│ Access: tenants/data/         │
│         pillow-factory/*      │
└───────────────────────────────┘

  No label match → only "default" policy → no tenant access
```

# Why three objects and not one

Each answers a different question, and Vault won't let you merge them:

- **Policy** → *what* can they touch? (rules only, no login matching)
- **Group** → *who* gets it? (a bucket of identities, no rules inline)
- **GroupAlias** → *how* is membership decided? (match the Entra label)

Chained together:

```
Entra label "pillow-factory" → GroupAlias → Group → Policy → tenants/pillow-factory/*
```

# How this differs from AuthBackendRole

| | AuthBackendRole (machine) | Policy + Group + GroupAlias (human) |
|---|---|---|
| Who logs in | A pod's ServiceAccount | A person via Entra ID SSO |
| Login method | `jwt-workload-tenants` backend | `oidc` auth method |
| Identity source | Namespace claim in the SA token | `roles` claim in the Entra token |
| How tenant is scoped | Identity-template on one shared `tenant-policy` | A dedicated per-tenant `tenant-<t>` policy via the group |

Same goal — a hard, per-tenant boundary — but one is for workloads and one is
for the people who operate them.
