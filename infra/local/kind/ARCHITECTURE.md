# Architecture & Design Decisions

This document captures the *why* behind the local kind environment. For setup and
usage see [README.md](README.md).

---

## Overview

Two kind clusters model a real platform:

- **management** — runs the platform control plane (ArgoCD, Vault, PowerDNS,
  cert-manager, external-secrets, Traefik).
- **development** — a tenant cluster whose platform components are installed by
  ArgoCD via GitOps.

```mermaid
flowchart TB
    host["Host laptop<br/>systemd-resolved drop-in<br/>~rezakara.demo → PowerDNS"]

    subgraph mgmt["management cluster (kind)"]
        pdns["PowerDNS<br/>hostNetwork :53<br/>API behind Traefik"]
        coredns_m["CoreDNS stub"]
        traefik_m["Traefik Gateway<br/>TLS :8443 (root-ca)"]
        argocd["ArgoCD<br/>OIDC + App-of-Apps"]
        vault["Vault"]
        eso_m["external-secrets"]
        edns_m["external-dns"]
        cm_m["cert-manager<br/>selfsigned → root-ca"]
    end

    subgraph dev["development cluster (kind)"]
        coredns_w["CoreDNS stub"]
        traefik_w["Traefik Gateway<br/>TLS (shared root-ca)"]
        eso_w["external-secrets"]
        edns_w["external-dns"]
        cm_w["cert-manager"]
        api_w["API server<br/>OIDC / JWKS"]
    end

    host -->|DNS| pdns
    coredns_m -->|forward| pdns
    coredns_w -->|forward| pdns
    argocd -->|GitOps sync| dev
    edns_w -->|"API @ powerdns.mgmt.rezakara.demo"| traefik_m --> pdns
    eso_w -->|JWT auth| vault
    vault -->|"fetch JWKS @ :6443"| api_w
    eso_m --> vault
    cm_m --> traefik_m
```

---

## kind over minikube

kind is lighter and faster to tear down and recreate than minikube with a VM
driver. Both clusters run as Docker containers on a single `kind` bridge network,
so pods in one cluster can reach nodes in the other directly — no tunnels.

Cluster names are `management` and `development`; kube contexts are therefore
`kind-management` and `kind-development`.

---

## DNS without a laptop daemon

**Goal:** avoid installing a DNS daemon (dnsmasq) that reshapes the host's global
resolver config.

**Solution:** PowerDNS runs *inside* the management cluster with `hostNetwork:
true`, binding `:53` on the management node's Docker-bridge IP. Three consumers
reach it:

- **Host** — a two-line systemd-resolved drop-in
  (`/etc/systemd/resolved.conf.d/rezakara.demo.conf`) routes only `~rezakara.demo` to
  PowerDNS. Nothing else about the host resolver changes.
- **Management pods** — CoreDNS is patched with a stub zone forwarding
  `rezakara.demo` to the PowerDNS node IP.
- **Workload pods** — same CoreDNS stub, reaching PowerDNS across the kind bridge.

`hostNetwork` (rather than a Cilium LoadBalancer IP) is used because the node IP
is routable from pods in *both* clusters and from the host, whereas a Cilium LB IP
in the management cluster is not reachable from the development pod network.

### Why keep external-dns + PowerDNS

This mirrors the real cloud model: applications create Gateway API `HTTPRoute`s,
external-dns observes them and writes records into a DNS provider's API (PowerDNS
here, Cloud DNS in production). Keeping this loop locally exercises the same code
paths as production instead of a simplified hosts-file hack.

---

## TLS chain

cert-manager builds a local PKI:

```
selfsigned (ClusterIssuer)
  └── root-ca (Certificate, CA)
        └── root-ca (ClusterIssuer)
              └── *.mgmt.rezakara.demo (wildcard, issued to Traefik)
```

`baseline-management` provisions the `selfsigned` → `root-ca` chain. Traefik's
Gateway is annotated with `cert-manager.io/cluster-issuer: root-ca`, so
cert-manager mints the wildcard cert and Traefik terminates HTTPS on `:8443`.

The root CA is pushed to Vault (`management/pki`) via an external-secrets
`PushSecret`. `setup-trust.sh` pulls it back out and installs it into the host's
Java, browser (NSS), and system trust stores, and seeds the `root-ca` secret into
the development cluster — so the **same** CA is trusted across host and both clusters.

---

## Secrets: Vault + external-secrets

Vault (KV v2 at mount `local`) is the source of truth for all secrets. Bootstrap
scripts write secrets from `pass`; external-secrets materialises them into
Kubernetes as needed.

- The **management** cluster uses a `ClusterSecretStore` (`vault-local`) that
  reaches Vault over its HTTPS route and authenticates via JWT auth.
- The **development** cluster uses a `SecretStore` and its own Vault JWT auth backend
  (`jwt-development`) configured by `setup-vault.sh`.

Vault validates each pod's ServiceAccount token cryptographically: it fetches the
cluster's public signing keys (JWKS) directly from that cluster's API server
(`https://<node-ip>:6443/openid/v1/jwks`) — the same hub→spoke path ArgoCD uses.
No long-lived reviewer token is needed.

> **Operational note:** the local `vault` CLI version may differ from the server.
> All bootstrap scripts run `vault` commands *inside* the `vault-0` pod
> (`kubectl exec`) to avoid client/server version-mismatch errors.

---

## GitOps model for the development cluster

Workload platform components (cert-manager, external-secrets, Traefik,
external-dns) are **not** installed imperatively — ArgoCD installs them by syncing
`argocd-applications/local/development/`.

The flow:

1. `setup-secrets.sh` creates an `argocd-manager` ServiceAccount with a long-lived
   token in the development cluster and stores `server` + `token` in Vault.
2. `gitops-platform`'s `clusters-credential` ExternalSecret materialises the
   ArgoCD **cluster Secret** (pull model — ArgoCD connects out to the development API).
3. `gitops-platform`'s App-of-Apps (`platform-application-folder`) points at
   `argocd-applications/local/development/` with `directory.recurse: true`.
4. ArgoCD reconciles those Applications, installing the development platform stack.

Because ArgoCD reads from **Git**, chart and Application changes must be committed
and pushed before they take effect.

### Why the development cluster needs no identity seed

Vault authenticates development pods with JWT auth, fetching the development cluster's
JWKS **directly from its API server** (`https://<node-ip>:6443`). Because the API
server is up the moment the kind cluster exists, `setup-vault.sh` can configure
`jwt-development` immediately — nothing has to be pre-seeded on the development cluster.

This deliberately avoids the bootstrap cycle that arises if you instead expose the
JWKS through the development's own Traefik ingress:

```
Traefik Gateway needs a TLS cert
  → cert comes from external-secrets (SecretStore)
    → SecretStore needs Vault jwt-development auth
      → jwt-development needs the JWKS endpoint behind Traefik
        → back to the Gateway that isn't up yet
```

Fetching the JWKS from the API server sits *below* that stack, so the whole
development platform can be pure GitOps with no hand-planted identity seed. The only
thing bootstrapped imperatively is `setup-secrets.sh` registering the development
cluster with ArgoCD (storing its API server + token in Vault).

### PowerDNS API at a stable hostname

Workload external-dns must reach the management PowerDNS API. The management node
IP changes when kind clusters are recreated, and ArgoCD applies static YAML from
Git, so it cannot inject a runtime IP.

Instead the PowerDNS API is exposed behind the management Traefik at a stable
hostname (`powerdns.mgmt.rezakara.demo`). Workload external-dns targets that URL
with `--pdns-skip-tls-verify` (local self-signed CA). This keeps the whole development
stack in GitOps and portable across cluster recreation — and mirrors the cloud
model of talking to a DNS API over a stable endpoint.

---

## ArgoCD authentication

ArgoCD runs with Azure AD OIDC enabled (same config as the cloud/minikube setup),
with the local `admin` account retained as a fallback. The Azure client secret is
read from Vault into `argocd-secret` by an external-secrets `ExternalSecret`.
Because OIDC requires a working HTTPS URL, this depends on the TLS chain being up.

---

## Networking summary

| Concern | Mechanism |
|---------|-----------|
| LoadBalancer IPs | Cilium (L2 announcements), pools carved from the kind bridge CIDR |
| Cross-cluster reachability | shared `kind` Docker bridge network |
| DNS (host) | systemd-resolved drop-in → PowerDNS node IP |
| DNS (pods) | CoreDNS stub zone → PowerDNS node IP |
| Ingress | Traefik + Gateway API, TLS via root-ca |
| Record automation | external-dns → PowerDNS API |
