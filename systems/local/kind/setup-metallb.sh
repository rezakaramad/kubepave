#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=libs/common.sh
source "$DIR/libs/common.sh"
# shellcheck source=libs/utils.sh
source "$DIR/libs/utils.sh"

METALLB_VERSION="v0.14.9"
METALLB_MANIFEST="https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"


# -----------------------------------------------------------------------------
# Install metallb into a cluster and wait for it to be ready
# -----------------------------------------------------------------------------
install_metallb() {
  local cluster=$1
  local context

  context="$(kind_context "$cluster")"

  log "Installing metallb ${METALLB_VERSION} in $cluster..."

  kubectl --context "$context" apply -f "$METALLB_MANIFEST"

  kubectl --context "$context" \
    -n metallb-system \
    wait pod \
    --selector app=metallb \
    --for=condition=Ready \
    --timeout=120s

  ok "metallb ready in $cluster"
}


# -----------------------------------------------------------------------------
# Configure metallb IP address pool and L2 advertisement for a cluster
# -----------------------------------------------------------------------------
configure_pool() {
  local cluster=$1
  local context
  local pool

  context="$(kind_context "$cluster")"
  pool="$(get_metallb_pool "$cluster")"

  log "Configuring metallb pool $pool in $cluster..."

  kubectl --context "$context" apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - ${pool}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  ipAddressPools:
    - kind-pool
EOF

  ok "Pool configured in $cluster"
}


install() {
  for cluster in management workload; do
    install_metallb "$cluster"
    configure_pool  "$cluster"
    echo "--------------------------------"
  done

  ok "metallb ready in all clusters"
}

case "${1:-install}" in
  install) install ;;
  *)
    echo "Usage: $0 [install]"
    exit 1
    ;;
esac
