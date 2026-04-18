#!/usr/bin/env bash
set -euo pipefail

# Returns absolute path to script location, in my case it's '/home/kara/github/r-karamad/kubepave/src/bootstrap/minikube/libs'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Go four folders up from where the script lives, and give me that absolute path.
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# Absolute path to 'charts/'' directory
CHARTS_DIR="$REPO_ROOT/charts"

# Where kubectl plugins are placed
KUBECTL_PLUGIN_DIR="$REPO_ROOT/src/kubectl-plugins"

# Management cluster is where Vault, ArgoCD, Crossplane management components and Keycloak live
MANAGEMENT_PROFILE="minikube-management"

# Keycloak admin credentials
KEYCLOAK_ADMIN_USER="admin"
KEYCLOAK_ADMIN_PASSWORD=""

# Namespace for platform components
PLATFORM_NAMESPACE="platform-system"

# kubepave Minikube cluster name prefix
PROFILE_PREFIX="minikube-"

# Specify platform components namespaces
PLATFORM_NAMESPACE="platform-system"
VAULT_NAMESPACE="vault"
ARGOCD_NAMESPACE="argocd"

# CoreDNS Adjustment
COREDNS_NS="kube-system"
TRAEFIK_SVC="traefik-mgmt"
TRAEFIK_NS="platform-system"
DNS_DOMAIN="mgmt.rezakara.demo"
DNS_HOSTS=(
  vault
)

