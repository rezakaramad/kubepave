#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=libs/common.sh
source "$DIR/libs/common.sh"
# shellcheck source=libs/utils.sh
source "$DIR/libs/utils.sh"

GATEWAY_API_VERSION="v1.4.1"
GATEWAY_API_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"


# -----------------------------------------------------------------------------
# Install Gateway API CRDs into a cluster.
# Required before: setup-dns.sh (powerdns HTTPRoute), install-charts.sh (Traefik)
# -----------------------------------------------------------------------------
install_gateway_api() {
  local cluster=$1
  local context
  context="$(kind_context "$cluster")"

  log "Installing Gateway API ${GATEWAY_API_VERSION} in $cluster..."

  if kubectl --context "$context" get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
    ok "Gateway API already installed in $cluster"
    return
  fi

  kubectl --context "$context" apply -f "$GATEWAY_API_URL"

  kubectl --context "$context" wait \
    --for=condition=Established \
    crd/gateways.gateway.networking.k8s.io \
    --timeout=60s

  ok "Gateway API installed in $cluster"
}


install() {
  for cluster in management workload; do
    install_gateway_api "$cluster"
  done
}


case "${1:-install}" in
  install) install ;;
  *)
    echo "Usage: $0 [install]"
    exit 1
    ;;
esac
