# Concepts

Vault/OpenBao is not simply a place where secrets are stored; rather, it is a system built around identity, policy, cryptographic trust, and short-lived credentials.

## 1. Start with this architecture

```text
                    USERS / APPLICATIONS
                           │
                           │ HTTPS
                           ▼
                  ┌───────────────────┐
                  │    Vault/OpenBao  │
                  │                   │
                  │   Authentication  │
                  │        ↓          │
                  │      Token        │
                  │        ↓          │
                  │      Policy       │
                  │        ↓          │
                  │  Secrets Engine   │
                  │                   │
                  │  Encryption       │
                  │     Barrier       │
                  └────────┬──────────┘
                           │
                       encrypted
                           │
                           ▼
                  ┌───────────────────┐
                  │ Storage Backend   │
                  │                   │
                  │ Raft / etcd / ... │
                  └───────────────────┘
```

The critical point is that **the storage backend is deliberately treated as untrusted**. Vault assumes that an attacker could potentially gain access to the underlying storage or database.

So before data reaches storage, it passes through an **encryption barrier**.

That design decision explains a huge amount of Vault's architecture.

---

## 2. The encryption barrier

Suppose you write:

```text
secret/data/database

username = production
password = SuperSecret123
```

Conceptually, Vault/OpenBao does something like:

```text
Client
   │
   ▼
Vault Core
   │
   ▼
Encryption Barrier
   │
   │ encrypt
   ▼
Storage

AF84F92BD01AE...
```

The physical storage backend doesn't need the plaintext password.

If someone copies the underlying storage, they shouldn't simply be able to grep for:

```text
SuperSecret123
```

This also explains **sealing**.

When Vault does not possess the keys necessary to operate the encryption barrier, the data might physically exist on disk, but Vault itself cannot meaningfully read it.

---

## 3. Why doesn't Vault just have one encryption key?

A simplified conceptual hierarchy looks like:

```text
                      Unseal Key
                          │
                          │ decrypts
                          ▼
                       Root Key
                          │
                          │ decrypts/protects
                          ▼
                     Keyring (key v1, key v2, ...)
                          │
                   Encryption Keys
                          │
                          │ encrypt
                          ▼
                  Vault/OpenBao data
```

There are multiple layers deliberately.

The encryption keys used by the barrier live in a **keyring**.

That keyring is protected using another key—the **root key**:
```text
Root Key
   │
   │ decrypts
   ▼
Keyring
   │
   ├── Encryption Key 1
   ├── Encryption Key 2
   └── Encryption Key 3
   Root Key
   │
   │ decrypts
   ▼
Keyring
   │
   ├── Encryption Key 1
   ├── Encryption Key 2
   └── Encryption Key 3
```



And access to that root key is protected through the **unseal mechanism**.

This allows Vault to rotate internal encryption keys without requiring operators to redistribute an entirely new set of unseal material every time.

The root key itself is encrypted.

The unseal key is what lets Vault recover it.

```text
Unseal Key
    │
    ▼
encrypted Root Key
    │
    ▼
Root Key
```

Vault needs something outside that encrypted storage hierarchy to bootstrap the process. That's what the unseal mechanism provides.

---

## 4. What "sealed" actually means

Imagine the server starts:

```text
systemctl start openbao
```

The process can start.

It can find its storage.

It might see something equivalent to:

```text
/storage/
    raft.db
    encrypted-config
    encrypted-secrets
    encrypted-policies
    encrypted-auth-config
```

But the process does **not yet possess the cryptographic material needed to open the encryption barrier**.

So:

```text
OpenBao process:        running
Storage:                reachable
Encrypted data:         present
Barrier key available:  NO

State: SEALED
```

A sealed Vault/OpenBao is essentially saying:

> “I know where my data is, but I cannot decrypt it.”

Before unsealing, only a very limited set of operations, such as checking seal status and performing the unseal process, are possible.

---

## 5. Shamir's Secret Sharing

You don't necessarily want this:

```text
MASTER UNSEAL KEY

7ac00fe151ef...
```

given to one administrator.

If that person is compromised, your entire security model becomes weaker.

Instead Vault/OpenBao can apply **Shamir's Secret Sharing**.

For example:

```text
Unseal key

        ↓ Shamir

Share 1 ───── Alice
Share 2 ───── Bob
Share 3 ───── Charlie
Share 4 ───── Diana
Share 5 ───── Eric
```

And configure:

```text
shares    = 5
threshold = 3
```

Meaning:

```text
any 3 of 5 shares
      ↓
reconstruct enough key material
      ↓
unseal Vault
```

But:

```text
1 share  ❌
2 shares ❌
```

aren't enough.

This is fundamentally a **quorum mechanism**.

A subtle but important point: the shares aren't pieces that you simply concatenate:

```text
KEY_PART_A + KEY_PART_B + KEY_PART_C
```

Shamir Secret Sharing uses mathematics so that fewer than the threshold shares don't reveal useful portions of the secret.

With manual Shamir unseal, human intervention is needed.
Suppose you initialize OpenBao with:

```text
Key shares: 5
Threshold: 3
```

OpenBao produces five different unseal shares. You distribute them to five trusted people:

```text
Alice   → Share 1
Bob     → Share 2
Charlie → Share 3
Diana   → Share 4
Eric    → Share 5
```

Whenever OpenBao becomes sealed—after a manual bao operator seal, certain restarts depending on your setup, or an operational event requiring unseal—you need any 3 of those 5 people to participate.

For example:

```text
OpenBao starts

Seal Status:
sealed = true
threshold = 3
progress = 0
```

Alice connects securely to the OpenBao node and runs:

```text
bao operator unseal
```

The CLI prompts her:

```text
Unseal Key (will be hidden):
```

She enters **her own share**.

OpenBao now reports conceptually:

```text
sealed   = true
progress = 1/3
```

Alice does not give her key to Bob.

Bob independently connects and runs:

```text
bao operator unseal
```

and enters his own share:
```text
progress = 2/3
```

Then Charlie:
```text
bao operator unseal
```

enters his share.

Now:

```text
progress = 3/3
```

and OpenBao reconstructs what it needs internally:

```text
Share A ─┐
Share B ─┼─► reconstruction ─► unseal key
Share C ─┘                       │
                                ▼
                          decrypt root key
                                │
                                ▼
                         unlock keyring
                                │
                                ▼
                            UNSEALED
```

The important security property is that the three humans don't need to disclose their shares to each other. Each person submits their own share directly to OpenBao.

---

## 6. The full unseal process

Let's follow boot from the beginning.

### Server starts

```text
              ┌─────────────┐
              │ OpenBao     │
              │ starts      │
              └──────┬──────┘
                     │
                     ▼
                SEALED
```

Storage is reachable, but the encryption barrier isn't operational.

Then operators provide shares:

```text
Alice
share A
   │
   ▼

OpenBao

1 / 3
```

Then:

```text
Bob
share B
   │
   ▼

OpenBao

2 / 3
```

Then:

```text
Charlie
share C
   │
   ▼

OpenBao

3 / 3
```

At the threshold:

```text
Shamir shares
      │
      ▼
reconstruct unseal key
      │
      ▼
decrypt root key
      │
      ▼
unlock keyring
      │
      ▼
encryption barrier operational
      │
      ▼
UNSEALED
```

Vault/OpenBao can now load things such as configured auth methods, secrets engines, policies, audit devices, and other encrypted configuration.

That's the core meaning of **unseal**.

---

## 7. What happens to the shares afterward?

Vault does not need operators to submit their shares with every request.

The shares are needed to cross the startup trust boundary.

Once unsealed:

```text
          required cryptographic material
                      │
                      ▼
                    RAM
                      │
           ┌──────────┴───────────┐
           │                      │
      decrypt data          encrypt data
```

Vault can operate.

Once unsealed, OpenBao keeps the necessary cryptographic key material in RAM and operates normally.

So the lifecycle is:

```text
sealed
  ↓
provide enough unseal shares
  ↓
unsealed
  ↓
key material stays in RAM
  ↓
normal operation
```

You only need the shares again if OpenBao becomes sealed again, for example after a restart or an explicit seal operation.

---

## 8. Auto-unseal

Manually having three executives wake up after every server restart doesn't scale very well.

That's why production deployments commonly use **auto-unseal**.

Instead of:

```text
Alice ─┐
Bob ───┼──► OpenBao
Carol ─┘
```

you can have:

```text
               ┌─────────────┐
               │ AWS KMS     │
               │ Azure Key   │
OpenBao ──────►│ GCP KMS     │
               │ HSM         │
               └─────────────┘
```

The external trusted cryptographic system protects the material required for unsealing.

At startup:

```text
OpenBao
   │
   │ request decrypt operation
   ▼
KMS/HSM
   │
   │ authorized?
   ▼
yes
   │
   ▼
OpenBao obtains what it needs
   │
   ▼
UNSEALED
```

It does **not** mean encryption goes away.

You've changed who protects the key that opens the barrier.

---

## 9. Authentication and authorization are separate

Authentication in Vault is mainly a way to obtain a token; authorization is then enforced through policies attached to that token.

So, the flow would be like this:
```
Auth method
   ↓
proves identity
   ↓
Vault issues token
   ↓
policies attached to that token determine access
```

---

## 10. Auth methods

Vault/OpenBao supports different ways of proving identity.

Humans might use:

```text
OIDC
LDAP
userpass
```

Applications might use things such as:

```text
AppRole
Kubernetes
JWT/OIDC
certificates
cloud identity
```

The important part:

**The auth method isn't normally what you use for every subsequent request.**

Authentication ultimately results in Vault/OpenBao issuing a **token**.

```text
              Identity Provider
                     │
Alice ──OIDC────────►│
                     │
                     ▼
                 OpenBao
                     │
                authenticated
                     │
                     ▼
               Vault token
```

That token becomes Alice's credential when interacting with Vault.

---

## 11. Tokens are the center of Vault

Understanding tokens makes the rest much easier.

Conceptually:

```text
OIDC
LDAP
AppRole
Kubernetes
JWT
Certificate
   │
   │ authenticate
   ▼
┌───────────────────┐
│ Vault/OpenBao     │
└─────────┬─────────┘
          │
          ▼
       TOKEN
          │
          ├── policies
          ├── TTL
          ├── renewable?
          ├── metadata
          └── identity information
```

Then:

```text
GET /v1/secret/data/foo

X-Vault-Token: hvs....
```

Vault resolves the token and determines what it permits.

A useful sentence to remember:

> **Auth methods prove identity; Vault tokens carry authorization context afterward.**

---

## 12. Policies are path-based ACLs

Vault's world is essentially an API tree.

Think:

```text
secret/
database/
pki/
transit/
auth/
sys/
```

Policies say what operations you can perform against those API paths.

For example:

```hcl
path "secret/data/acme/*" {
  capabilities = ["read", "list"]
}
```

Alice's token might carry:

```text
policies:
    default
    acme-developers
```

Then Alice requests:

```text
secret/data/acme/database
```

Vault conceptually does:

```text
TOKEN
  │
  ▼
valid?
  │
 yes
  │
  ▼
load policies
  │
  ▼
does any policy allow READ on this path?
  │
  ├── no ──► 403
  │
  └── yes
        │
        ▼
    execute request
```

Vault/OpenBao is **default deny**: permission has to be explicitly granted.

---

## 13. Secrets engines

It's effectively a backend plugin mounted at a particular API path.

For example:

```text
secret/     → KV engine
database/   → Database engine
pki/        → PKI engine
transit/    → Transit engine
```

Therefore:

```text
database/creds/readonly
```

means roughly:

```text
route request to database secrets engine
                 │
                 ▼
          role = readonly
                 │
                 ▼
     generate DB credentials
```

This architecture is why Vault is so extensible.

Paths aren't necessarily files.

They're **API routes handled by mounted backends**.

---

## 14. Static secrets versus dynamic secrets

Traditional secret management:

```text
Vault KV

db-password = VerySecret123
```

The password already exists.

Vault stores it securely.

That's a **static secret**.

Dynamic secrets are like instead of storing:

```text
username = app
password = permanent123
```

Vault itself talks to PostgreSQL:

```text
Application
     │
     ▼
Vault
     │
     ▼
PostgreSQL

CREATE USER
temporary-a7d21
PASSWORD randomValue
VALID FOR 1h
```

Then Vault returns:

```text
username: temporary-a7d21
password: ...
lease: 1 hour
```

After that hour:

```text
Vault → PostgreSQL

DROP USER temporary-a7d21
```

Now credentials are:

```text
generated on demand
      +
time limited
      +
revocable
```

That's a fundamentally stronger model than keeping permanent database credentials everywhere.

---

## 15. Leases and TTLs

Suppose Vault gives an application:

```text
Postgres username: vault-abc123
TTL: 60 minutes
```

Internally Vault tracks a **lease**.

Conceptually:

```text
lease_id
    │
    ├── secret
    ├── expiration = 20:30
    ├── renewable = true
    └── revocation operation
```

Before expiration:

```text
Application
    │
    ├── renew
    │
    ▼
Vault

60 min → another 60 min
```

Or if it expires:

```text
Expiration manager
       │
       ▼
Database plugin
       │
       ▼
REVOKE / DROP credential
```

This leads to a very important Vault philosophy:

> Don't just protect secrets. **Reduce how long secrets remain useful.**

---

## 16. Revocation is one of Vault's superpowers

Traditional system:

```text
password leaked

Where is it being used?

Server A?
Server B?
CI?
Developer laptop?
Kubernetes Secret?
Terraform?
```

Painful.

Vault's dynamic model can say:

```text
revoke lease abc123
```

and Vault knows how to tell the upstream system:

```text
Database:
DROP ROLE ...

AWS:
delete temporary credentials

PKI:
certificate lifecycle management
```

Vault knows the relationship between:

```text
identity
  ↓
token
  ↓
secret
  ↓
lease
```

That relationship makes lifecycle management possible.

---

## 17. Identity is different from tokens

```text
Alice
```

is an **identity**.

Alice may log in through:

```text
OIDC today
LDAP tomorrow
```

and obtain many different tokens over time.

Conceptually:

```text
            Alice
              │
        Identity Entity
         /          \
        /            \
OIDC alias          LDAP alias
     │                  │
     ▼                  ▼
 token1               token2
 token3
```

This identity layer lets Vault reason about the same human or application across authentication mechanisms.

---

## 18. Mounts

You'll often see:

```bash
bao secrets enable -path=foo kv
```

What really happened?

Vault/OpenBao effectively added a routing entry:

```text
foo/*

→ send requests to KV secrets engine instance #X
```

Likewise:

```bash
bao auth enable -path=employees oidc
```

creates something like:

```text
auth/employees/*

→ OIDC auth backend instance
```

A very useful mental model is:

> **Vault is a giant authenticated HTTP router with cryptographic storage behind it.**

Routes point to auth backends, secrets engines, system endpoints, and identity endpoints, while policies control who may invoke those routes.

---

## 19. `sys/` is special

You'll frequently encounter:

```text
sys/mounts
sys/policies
sys/health
sys/auth
```

Think of `sys/` as Vault/OpenBao's **control plane API**.

For example:

```text
secret/*
```

often means working with secrets.

Whereas:

```text
sys/mounts/*
```

means configuring the Vault system itself.

This distinction becomes extremely useful when reading policies.

```hcl
path "sys/mounts/*" {
    capabilities = ["create", "update", "delete"]
}
```

is much more privileged than:

```hcl
path "secret/data/team-a/*" {
    capabilities = ["read"]
}
```

---

## 20. Audit devices

Vault/OpenBao is also designed around accountability.

Conceptually every sensitive interaction can produce an audit event:

```text
Alice
  │
  │ read secret/database
  ▼
OpenBao
  │
  ├── authenticate token
  ├── evaluate policy
  ├── service request
  │
  └──────────────► Audit device
```

You want to be able to answer:

```text
Who accessed this?
When?
Using what identity?
Against what path?
What operation?
```

This is part of why directly reading the underlying database is contrary to Vault's model—you'd bypass authentication, authorization, leases, and auditing.

---

## 21. Storage and HA are separate ideas

Suppose you run three OpenBao servers:

```text
bao-1
bao-2
bao-3
```

In a typical HA setup:

```text
          Client
             │
             ▼
        Load Balancer
         /    |    \
        /     |     \
     bao-1  bao-2  bao-3
```

One node may be active while others act as standbys depending on architecture/configuration.

With integrated Raft storage:

```text
              OpenBao cluster

        node1 ── node2 ── node3
          │        │        │
          └──── Raft ───────┘
```

There are two related but distinct concerns:

```text
Availability of OpenBao servers

             vs

Durability/consistency of OpenBao data
```

Understanding that distinction helps greatly when debugging clusters.

---

## 22. Initialization is not the same as unsealing

You perform:

```bash
bao operator init
```

**once when creating the Vault/OpenBao installation.**

Initialization creates critical initial cryptographic material and the initial administrative/root credential.

Then throughout the server's lifetime you may have:

```text
start
↓
unseal

restart
↓
unseal

restart
↓
unseal
```

So:

```text
INIT

done once
│
├── establishes cryptographic foundation
├── generates unseal material
└── produces initial root token
```

versus:

```text
UNSEAL

performed whenever necessary
│
└── makes existing cryptographic material usable again
```

Do **not** reinitialize an existing Vault because it restarted.

That's one of the most dangerous beginner misunderstandings.

---

## 23. Root token versus unseal keys

Burn this distinction into memory:

```text
                UNSEAL KEYS
                     │
                     ▼
              cryptographic access
                     │
                     ▼
          Make Vault operational


                 ROOT TOKEN
                     │
                     ▼
             authorization
                     │
                     ▼
          Make API requests
```

An unseal share does not mean:

> “I am an administrator.”

And a root token does not necessarily give you the material required to perform a manual Shamir unseal.

Different trust mechanisms.

---

## 24. Transit engine

Vault doesn't necessarily have to **give you secrets**.

It can also perform cryptographic operations for you.

Suppose your application has:

```text
credit_card = 4111...
```

Instead of managing an AES encryption key itself:

```text
App
 │
 │ plaintext
 ▼
Vault Transit
 │
 │ encrypt using key that app never sees
 ▼
ciphertext
```

Later:

```text
ciphertext
 │
 ▼
Vault Transit
 │
 ▼
plaintext
```

The application never receives the encryption key.

That's powerful because:

```text
key ownership
```

and

```text
data ownership
```

can be separated.

Vault can become a **cryptographic service**, not merely a secret database.

---

## 25. PKI works similarly

Vault/OpenBao can also become your certificate authority.

Rather than storing a static TLS certificate:

```text
cert.pem
key.pem

valid 3 years
```

an application can request:

```text
give me a certificate for:

api.internal.example.com

TTL: 24h
```

Vault/OpenBao signs one:

```text
Vault PKI
   │
   ├── certificate
   ├── private key
   └── expiration
```

Now you get short-lived certificates instead of manually distributed long-lived ones.

Again, the philosophy appears:

```text
identity
+
policy
+
short lifetime
+
revocability
```

---

## 26. Namespaces

Think of a namespace as something close to:

```text
Vault inside Vault
```

For example:

```text
root
│
├── tenant-a
│   ├── auth/
│   ├── secret/
│   ├── database/
│   ├── policies
│   └── identities
│
├── tenant-b
│   ├── auth/
│   ├── secret/
│   └── policies
│
└── internal
```

Each namespace gives you an administrative boundary around Vault constructs.

That's stronger and cleaner than merely doing:

```text
secret/tenant-a/*
secret/tenant-b/*
```

inside one flat administrative space.

---

## 27. The request lifecycle is the concept to memorize

If you remember only one diagram, make it this one:

```text
APPLICATION / USER
        │
        │ authenticate
        ▼
┌──────────────────────────┐
│      AUTH METHOD         │
│ OIDC/K8s/AppRole/LDAP... │
└────────────┬─────────────┘
             │
             ▼
           TOKEN
             │
             ▼
┌──────────────────────────┐
│        POLICIES          │
│                         │
│ Is operation allowed?   │
└────────────┬─────────────┘
             │
            YES
             │
             ▼
┌──────────────────────────┐
│      SECRETS ENGINE      │
│                         │
│ KV / DB / PKI / Transit │
└────────────┬─────────────┘
             │
             ▼
       secret/result
             │
             ├──── lease
             │
             └──── audit event
```

Underneath all of it:

```text
════════ ENCRYPTION BARRIER ════════
                 │
                 ▼
          encrypted storage
```

And the barrier only operates while the system is:

```text
UNSEALED
```

That is Vault/OpenBao in one picture.

---

## 28. The deeper philosophy

Almost everything in Vault follows five ideas:

```text
1. Authenticate everything.

2. Deny by default.

3. Give the minimum capability necessary.

4. Prefer temporary credentials over permanent credentials.

5. Make credentials revocable and actions auditable.
```

So the evolution is:

```text
OLD WORLD

Application
    │
    ▼
config.yml

DB_PASSWORD=supersecret

             ↓

NEW WORLD

Application
     │
     │ prove identity
     ▼
Vault/OpenBao
     │
     │ policy allows?
     ▼
generate temporary credential
     │
     ▼
Database

TTL = 1 hour
```

That is much closer to the true reason Vault exists than simply “encrypted storage.”

---

## A useful mental hierarchy

When you're troubleshooting or designing Vault/OpenBao, think through these layers in this order:

```text
┌─────────────────────────────────────────┐
│  1. Seal                               │
│  Can OpenBao decrypt its own state?    │
├─────────────────────────────────────────┤
│  2. Storage / cluster                  │
│  Is persistent state available?        │
├─────────────────────────────────────────┤
│  3. Authentication                     │
│  Who is the client?                    │
├─────────────────────────────────────────┤
│  4. Token                              │
│  What credential did auth produce?     │
├─────────────────────────────────────────┤
│  5. Policy                             │
│  What may that token do?               │
├─────────────────────────────────────────┤
│  6. Mount / routing                    │
│  Which backend handles the path?       │
├─────────────────────────────────────────┤
│  7. Secrets engine                     │
│  What operation is actually performed? │
├─────────────────────────────────────────┤
│  8. Lease                              │
│  How long does the result live?        │
├─────────────────────────────────────────┤
│  9. Audit                              │
│  What record is produced?              │
└─────────────────────────────────────────┘
```

When someone says **“Vault isn't working,”** this model lets you ask a better question:

> Is this a **seal problem, authentication problem, token problem, policy problem, path/mount problem, secrets-engine problem, lease problem, or storage/HA problem?**

Once those layers are clear, Vault stops looking like a collection of obscure commands and starts looking like a coherent security architecture.
