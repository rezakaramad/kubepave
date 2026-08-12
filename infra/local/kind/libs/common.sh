#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# common.sh
#
# Common functions and variables for the local kind cluster setup scripts.
# -----------------------------------------------------------------------------

# Returns absolute path to script location, in my case it's '/home/kara/github/r-karamad/kubepave/src/bootstrap/minikube/libs'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Go four folders up from where the script lives, and give me that absolute path.
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# Absolute path to 'charts/'' directory
CHARTS_DIR="$REPO_ROOT/charts"

# Cluster names (kind automatically prefixes contexts with "kind-",
# so these become contexts "kind-management" and "kind-development").
MANAGEMENT_CLUSTER="management"
WORKLOAD_CLUSTER="development"

# Namespace for platform components
PLATFORM_NAMESPACE="platform-system"
# It's dead variable, but I keep it around for reference in case I need to switch back to Vault.
VAULT_NAMESPACE="vault"
OPENBAO_NAMESPACE="openbao"
ARGOCD_NAMESPACE="argocd"
COREDNS_NS="kube-system"

# Traefik service in management cluster
TRAEFIK_SVC="traefik-mgmt"
TRAEFIK_NS="platform-system"

# DNS
DNS_DOMAIN="rezakara.demo"

# LoadBalancer IP pools — carved from the upper end of the kind Docker bridge subnet.
# The exact IPs are computed at runtime from the actual CIDR via get_lb_pool()
# so this works regardless of whether Docker picks a /16, /24, /27, etc.
#   management pool: last 10 IPs of the subnet (PowerDNS gets the first of these)
#   development pool:   10 IPs immediately before the management pool
LB_MGMT_POOL_SIZE=10
LB_WL_POOL_SIZE=10


log()  { echo "➡️  $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
err()  { echo "❌ $*"; }
