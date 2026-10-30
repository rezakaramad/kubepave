# OpenBao `cubbyhole/`

## Start with External Secrets Operator in Kubernetes

If you run **External Secrets Operator (ESO)** against OpenBao, your normal secret flow looks like this:

```text
OpenBao KV
   ↓
External Secrets Operator
   ↓
Kubernetes Secret
   ↓
Pod
```

ESO authenticates to OpenBao, reads a secret such as:

```text
secret/data/payments/db
```

and writes it into a Kubernetes `Secret`.

In this flow, **`cubbyhole/` is usually not involved at all**.

That is because ESO is **intentionally trusted** to read the real secret.

---

## So what is `cubbyhole/`?

`cubbyhole/` is **private temporary storage attached to one OpenBao token**.

A useful mental model:

```text
Token = ticket
Cubbyhole = private locker behind that ticket
```

If Token A stores something in:

```text
cubbyhole/foo
```

Token B cannot see it, even if it asks for the same path.

The data also disappears when the token expires or is revoked.

---

## What problem does it solve?

The main problem is **secure handoff**.

Sometimes you want to deliver a sensitive value to a recipient, but you do **not** want the intermediary carrying it to see the value.

Example:

```text
OpenBao → CI system → new server
```

You want the new server to receive an AppRole `SecretID`.

You do **not** want the CI system to see that `SecretID`.

Without wrapping:

```text
OpenBao → CI → Server
           ↑
           sees SecretID
```

With response wrapping:

```text
OpenBao → CI → Server
           ↑
           sees only wrapping token
```

The server then gives the wrapping token back to OpenBao and gets the real secret.

This is basically what is called [response wrapping](https://developer.hashicorp.com/vault/docs/concepts/response-wrapping?productSlug=vault&tutorialSlug=secrets-management&tutorialSlug=cubbyhole-response-wrapping).

---

## Real example: AppRole SecretID delivery

AppRole is an OpenBao authentication method commonly used for machines that do not already have a native workload identity.

An application logs in with:

```text
RoleID + SecretID
        ↓
    AppRole login
        ↓
    OpenBao token
```

The important bootstrap detail is that the application does not authenticate to OpenBao to create its own `SecretID`.

Instead, an **already-trusted system** such as CI, Terraform, Ansible, or another provisioning service is authenticated to OpenBao and is allowed to create a `SecretID` for the application.

```text
Trusted provisioning system
        ↓
asks OpenBao to create a SecretID
        ↓
new application uses that SecretID
        ↓
AppRole login
```

The problem is then: how do we deliver that SecretID without exposing it to the provisioning system?

This is where response wrapping and `cubbyhole/` come in.

The trusted provisioning system requests a wrapped `SecretID`:

```text
bao write \
  -wrap-ttl=5m \
  -f auth/approle/role/payments-api/secret-id
```

Instead of receiving the actual `SecretID`, it receives:

```text
wrapping_token = hvs.CAESI...
wrapping_ttl   = 5m
```

OpenBao keeps the real response tied to that wrapping token:

```text
Wrapping token W
└── cubbyhole
    └── wrapped response
        └── secret_id = 8f2ab931-...
```

The provisioning system passes only `W` to the target machine:

```text
OpenBao
   │
   │ wrapping token W
   ▼
Trusted provisioning system
   │
   │ W only
   ▼
Target machine
```

The target machine unwraps it:

```text
bao unwrap hvs.CAESI...
```

and receives the real `SecretID`.

It can now authenticate:

```text
RoleID + SecretID
        ↓
    AppRole login
        ↓
    OpenBao token
```

So the responsibilities are:

Trusted system
→ bootstraps the application's credential

AppRole
→ lets the application authenticate

Cubbyhole + response wrapping
→ lets the credential pass through the trusted system without exposing the credential itself

The trusted system still needs its own authentication to OpenBao. AppRole does not remove the initial trust problem; it lets an already-trusted system securely bootstrap a new machine identity.

---

## Why not just use normal KV?

You could create temporary KV paths for every handoff:

```text
secret/handoff/abc123
```

but then you would need to manage:

- temporary paths
- temporary permissions
- cleanup
- expiration
- access isolation

`cubbyhole/` gives OpenBao a built-in token-scoped place for this kind of temporary data.

The important part is not the storage itself.

The important part is:

> **this data belongs to this token**

---

## Where it fits with ESO

For a normal ESO setup:

```text
OpenBao
   ↓
ESO
   ↓
Kubernetes Secret
   ↓
Pod
```

use normal KV secrets.

`cubbyhole/` is generally irrelevant because ESO is already trusted to read the real secret.

`cubbyhole/` becomes useful when the problem changes to:

```text
"I need to hand this sensitive value through another system,
but that system should not be able to read it."
```

That is why `cubbyhole/` is most commonly associated with **response wrapping**, bootstrap workflows, and one-time secret delivery.

---

## TL;DR

- `cubbyhole/` is private storage scoped to one OpenBao token.
- It is not a replacement for KV.
- It is usually not part of an ESO secret-sync flow.
- Its main value is temporary, token-bound secret delivery.
- Response wrapping uses this model so intermediaries can transport a token without seeing the underlying secret.
