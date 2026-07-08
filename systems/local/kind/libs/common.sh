#!/usr/bin/env bash
set -euo pipefail

# Returns absolute path to script location, in my case it's '/home/kara/github/r-karamad/kubepave/src/bootstrap/minikube/libs'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Go four folders up from where the script lives, and give me that absolute path.
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# Absolute path to 'charts/'' directory
CHARTS_DIR="$REPO_ROOT/charts/local"

# Cluster names (kind automatically prefixes contexts with "kind-",
# so these become contexts "kind-management" and "kind-workload").
MANAGEMENT_CLUSTER="management"
WORKLOAD_CLUSTER="workload"

# Namespace for platform components
PLATFORM_NAMESPACE="platform-system"
VAULT_NAMESPACE="vault"
ARGOCD_NAMESPACE="argocd"
COREDNS_NS="kube-system"

# Traefik service in management cluster
TRAEFIK_SVC="traefik-mgmt"
TRAEFIK_NS="platform-system"

# DNS
DNS_DOMAIN="rezakara.demo"

# metallb IP pools — carved from the upper end of the kind Docker bridge subnet.
# The exact IPs are computed at runtime from the actual CIDR via get_metallb_pool()
# so this works regardless of whether Docker picks a /16, /24, /27, etc.
#   management pool: last 10 IPs of the subnet (PowerDNS gets the first of these)
#   workload pool:   10 IPs immediately before the management pool
METALLB_MGMT_POOL_SIZE=10
METALLB_WL_POOL_SIZE=10


log()  { echo "➡️  $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
err()  { echo "❌ $*"; }
