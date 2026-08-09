#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# install-gateway-api.sh
#
# Install the Gateway API CRDs into the local kind clusters.
# It runs before Traefik and PowerDNS so HTTPRoute resources are available 
# when those charts deploy.
# The install is idempotent and skips clusters where the Gateway API CRDs
# already exist.
# -----------------------------------------------------------------------------

# Set the script directory to the current file's directory
DIR="$(cd "$(dirname "$0")" && pwd)"

# Import common functions and variables
source "$DIR/libs/common.sh"
source "$DIR/libs/utils.sh"

# Specify the version of Gateway API to install and the URL to fetch the CRDs from
GATEWAY_API_VERSION="v1.4.1"
GATEWAY_API_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"


# -----------------------------------------------------------------------------
# Install Gateway API CRDs into a cluster.
# Required before: 
# - setup-dns.sh (to set up PowerDNS)
# - install-charts.sh (to set up Traefik)
# -----------------------------------------------------------------------------
install_gateway_api() {
  # Function arguments:
  #   $1: cluster name (management or development)
  # Local variables:
  #   context: kube context derived from cluster name
  local cluster=$1
  local context

  # Set the kube context
  context="$(kind_context "$cluster")"

  log "Installing Gateway API ${GATEWAY_API_VERSION} in $cluster..."

  # Skip installation if the Gateway API CRDs already exist in the cluster
  if kubectl --context "$context" get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
    ok "Gateway API already installed in $cluster"
    return
  fi

  # Apply the Gateway API CRDs to the cluster
  kubectl --context "$context" apply -f "$GATEWAY_API_URL"

  # Wait for the CRDs to be established before proceeding
  kubectl --context "$context" wait \
    --for=condition=Established \
    crd/gateways.gateway.networking.k8s.io \
    --timeout=60s

  ok "Gateway API installed in $cluster"
}


# Install Gateway API in both management and development clusters
install() {
  for cluster in management development; do
    install_gateway_api "$cluster"
  done
}

# Handle command-line arguments and execute the appropriate function
case "${1:-install}" in
  install) install ;;
  *)
    echo "Usage: $0 [install]"
    exit 1
    ;;
esac
