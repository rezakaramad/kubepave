# Local kind environment

A reproducible, multi-cluster local platform running on [kind](https://kind.sigs.k8s.io/).
It mirrors the cloud setup: 

- a **management** cluster running the platform control plane (ArgoCD, Vault, PowerDNS, cert-manager, external-secrets, Traefik)
- and a **development** cluster whose platform components are installed by ArgoCD via
GitOps.

> For the design rationale (why kind, why PowerDNS in-cluster, the TLS chain, the
> GitOps model, and why the development cluster needs no identity seed) see
> [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Prerequisites

Install and have on `PATH`:

| Tool | Purpose |
|------|---------|
| `docker` | container runtime for kind nodes |
| `kind` | cluster runtime |
| `kubectl` | cluster access |
| `helm` | chart installs |
| `argocd` CLI | ArgoCD interaction |
| `openssl`, `keytool`, `certutil` | trust store management |
| `dig` | DNS verification |
| `python3` | LB pool / JSON helpers |
| `pass` | source of GitHub App + Azure AD secrets |
| `sudo` | systemd-resolved drop-in + system trust store |

You also need the `pass` password store populated with the GitHub App and Azure AD
credentials referenced by `setup-secrets.sh`.

---

## Bootstrap order

Run from `systems/local/kind/`. Each step is idempotent.

```bash
./setup-clusters.sh start     # 1. create kind clusters, patch CoreDNS stub
./setup-cilium.sh install     # 2. Cilium CNI + LoadBalancer pools (both clusters)
./install-gateway-api.sh      # 3. Gateway API CRDs (both clusters) — required by setup-dns.sh
./setup-dns.sh start          # 4. PowerDNS (hostNetwork) + systemd-resolved drop-in
./install-charts.sh           # 5. management stack + ArgoCD + development seed
./setup-vault.sh              # 6. configure Vault JWT auth for all clusters
./setup-secrets.sh            # 7. push secrets to Vault + register development with ArgoCD
./setup-trust.sh              # 8. distribute root CA to development + local trust stores
```

### What each step does

1. **`setup-clusters.sh start`** — creates the `management` and `development` kind
   clusters, enables promiscuous mode, and patches CoreDNS in both to forward
   `rezakara.demo` to PowerDNS. `destroy` tears them down; `status` shows state.
2. **`setup-cilium.sh install`** — installs Cilium (CNI + L2 load-balancer) and
   configures a `CiliumLoadBalancerIPPool` + `CiliumL2AnnouncementPolicy` per
   cluster, carved from the upper end of the kind Docker bridge CIDR.
3. **`install-gateway-api.sh`** — installs Gateway API CRDs (`v1.4.1`) on both
   clusters. Idempotent. Required before `setup-dns.sh` (PowerDNS HTTPRoute) and
   `install-charts.sh` (Traefik Gateway).
4. **`setup-dns.sh start`** — adds PowerDNS credentials to `.platform.env` (gitignored), deploys the
   PowerDNS chart with `hostNetwork: true` in the management cluster, and writes a
   systemd-resolved drop-in so the host resolves `*.rezakara.demo` via PowerDNS.
   `reset` reverts the host DNS change.
5. **`install-charts.sh`** — the main bootstrap. Installs cert-manager,
   external-secrets, Vault, Traefik (TLS), external-dns (management), and ArgoCD
   (OIDC + App-of-Apps).
6. **`setup-vault.sh`** — configures a Vault JWT auth backend per cluster,
   fetching each cluster's JWKS directly from its API server, so external-secrets
   can authenticate to Vault.
7. **`setup-secrets.sh`** — reads secrets from `pass` and writes them to Vault
   (GitHub Apps, Azure AD, PowerDNS, Next Insight) and registers the development
   cluster with ArgoCD (pull model) by storing its API server + token in Vault.
8. **`setup-trust.sh`** — copies the root CA Secret from the management cluster
   to the development cluster, verifies it, and installs it into the Java / browser
   (NSS) / system trust stores.

After step 6, ArgoCD materialises the development cluster Secret and the App-of-Apps
begins syncing `argocd-applications/local/development/` — installing cert-manager,
external-secrets, Traefik, and external-dns on the development cluster.

> **Note:** ArgoCD pulls charts and Application manifests from Git
> (`github.com/rezakaramad/kubepave` at `HEAD`). Any local chart changes must be
> committed and pushed before ArgoCD can see them.

---

## Endpoints

Once bootstrapped, these resolve via PowerDNS and terminate TLS at Traefik using
the local root CA (trusted after `setup-trust.sh`):

| Service | URL |
|---------|-----|
| ArgoCD | `https://argocd.mgmt.rezakara.demo` |
| Vault | `https://openbao.mgmt.rezakara.demo` |
| PowerDNS API | `https://powerdns.mgmt.rezakara.demo` |

ArgoCD supports both Azure AD SSO and the local `admin` account. Retrieve the
admin password with:

```bash
kubectl --context kind-management -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

---

## IP address planning

All ranges are in RFC 1918 Class C space (`192.168.x.x`), chosen to avoid
conflicts with typical office (`10.x.x.x`) and home (`192.168.0–1.x`) LANs.

### Docker bridge network — `192.168.211.64/27`

kind creates a single Docker bridge shared by both clusters. The subnet is
**pre-created with a pinned CIDR** by `setup-clusters.sh` so that the LoadBalancer
IP ranges remain stable across every `kind:down && kind:up` cycle.

```
192.168.211.64/27  (30 usable hosts: .65 – .94)
  .65      gateway (Docker bridge)
  .66      management control-plane node
  .67      development control-plane node
  .68–.74  unallocated
  .75–.84  development LoadBalancer pool   (10 IPs)
  .85–.94  management LoadBalancer pool (10 IPs)
```

Pool sizes are controlled by `LB_MGMT_POOL_SIZE` / `LB_WL_POOL_SIZE` in
`libs/common.sh`. The ranges are committed in
`charts/cilium/values-local-{management,development}.yaml` so ArgoCD can reconcile
them without any runtime injection.

### Pod and service CIDRs

Internal-only — never routed outside the cluster. Pods and services in these
ranges can only be reached through Cilium's eBPF datapath or via a LoadBalancer
VIP from the pool above.

| Cluster | Pod CIDR | Service (ClusterIP) CIDR |
|---------|----------|--------------------------|
| management | `192.168.100.0/24` | `192.168.101.0/24` |
| development   | `192.168.102.0/24` | `192.168.103.0/24` |

### Summary — what's reachable from where

| Address type | Range | Reachable from |
|---|---|---|
| Pod IP | `192.168.100–102.x` | inside the same cluster only |
| ClusterIP | `192.168.101/103.x` | inside the same cluster only |
| LoadBalancer VIP | `192.168.211.75–.94` | host + pods in both clusters (Docker bridge) |
| Node IP | `192.168.211.66–.67` | host + pods in both clusters (Docker bridge) |

---



```bash
# DNS resolves from the host
dig +short vault.mgmt.rezakara.demo

# Management platform pods
kubectl --context kind-management -n platform-system get pods

# ArgoCD Applications
kubectl --context kind-management -n argocd get applications

# Workload platform pods (installed by ArgoCD)
kubectl --context kind-development -n platform-system get pods

# HTTPS endpoints
curl -s -o /dev/null -w '%{http_code}\n' https://argocd.mgmt.rezakara.demo/
curl -s -o /dev/null -w '%{http_code}\n' https://vault.mgmt.rezakara.demo/v1/sys/health
```

`dns-test.yaml` is a sample HTTPRoute for testing the external-dns → PowerDNS flow:

```bash
kubectl --context kind-management apply -f dns-test.yaml
dig +short test.mgmt.rezakara.demo
```

---

## Teardown

```bash
./setup-dns.sh reset          # remove the systemd-resolved drop-in
./setup-clusters.sh destroy   # delete both kind clusters
```

The system trust store entry installed by `setup-trust.sh` can be removed with:

```bash
sudo rm /usr/local/share/ca-certificates/rezakara-demo.crt
sudo update-ca-certificates --fresh
```

---

## Directory layout

```
systems/local/kind/
├── README.md              # this file
├── ARCHITECTURE.md        # design decisions
├── libs/
│   ├── common.sh          # shared constants + log helpers
│   └── utils.sh           # kind/LB-pool/context helpers
├── kind-configs/
│   ├── management.yaml    # kind config for the management cluster
│   └── development.yaml      # kind config for the development cluster
├── setup-clusters.sh      # create/destroy clusters, patch CoreDNS
├── setup-cilium.sh         # Cilium CNI + LoadBalancer pools
├── setup-dns.sh           # PowerDNS + systemd-resolved
├── install-charts.sh      # management stack + ArgoCD + gitops-platform
├── setup-vault.sh         # Vault JWT auth (all clusters)
├── setup-secrets.sh       # secrets to Vault + development registration
├── setup-trust.sh         # root CA trust distribution
└── dns-test.yaml          # sample HTTPRoute for DNS testing
```
