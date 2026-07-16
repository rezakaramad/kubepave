#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=libs/common.sh
source "$DIR/libs/common.sh"
# shellcheck source=libs/utils.sh
source "$DIR/libs/utils.sh"

CILIUM_CHART="$REPO_ROOT/charts/cilium"
CILIUM_NAMESPACE="kube-system"
LB_POOL_CRD="ciliumloadbalancerippools.cilium.io"


# -----------------------------------------------------------------------------
# Install Cilium (CNI + L2 load-balancer) and configure the LoadBalancer IP pool.
#
# Two passes are required because Cilium registers the CiliumLoadBalancerIPPool /
# CiliumL2AnnouncementPolicy CRDs at runtime (they are not shipped as static CRDs):
#   1. install the CNI so nodes become Ready and the operator registers the CRDs
#   2. once the CRDs exist, apply the IP pool + L2 announcement policy
#
# The pool range is computed at runtime from the kind Docker network CIDR — it
# changes every time clusters are recreated, so it cannot be committed to Git and
# is injected via --set. On real on-prem clusters the networking team provides a
# static range that lives in a committed values file instead.
# -----------------------------------------------------------------------------
install_cilium() {
  local cluster=$1
  local context pool start stop api_ip

  context="$(kind_context "$cluster")"
  pool="$(get_lb_pool "$cluster")"
  start="${pool%-*}"
  stop="${pool#*-}"

  # kube-proxy is disabled (kubeProxyMode: none); Cilium needs a direct address
  # for the API server since it can't resolve the in-cluster kubernetes Service yet.
  api_ip="$(get_control_plane_ip "$cluster")"

  # Pass 1 — CNI only (no pool; its CRDs don't exist yet).
  log "Installing Cilium in $cluster (CNI)..."
  helm upgrade --install cilium "$CILIUM_CHART" \
    --kube-context "$context" \
    --namespace "$CILIUM_NAMESPACE" \
    --set "cilium.k8sServiceHost=${api_ip}" \
    --set "cilium.k8sServicePort=6443" \
    --wait \
    --timeout 5m

  log "Waiting for nodes to become Ready in $cluster..."
  kubectl --context "$context" wait --for=condition=Ready nodes --all --timeout=120s

  # Pass 2 — apply the LoadBalancer IP pool now that its CRDs are registered.
  log "Waiting for Cilium LB-IPPool CRD in $cluster..."
  for _ in $(seq 1 30); do
    kubectl --context "$context" get crd "$LB_POOL_CRD" >/dev/null 2>&1 && break
    sleep 2
  done
  kubectl --context "$context" wait --for=condition=Established \
    "crd/$LB_POOL_CRD" --timeout=60s

  log "Configuring Cilium LB pool in $cluster ($pool)..."
  helm upgrade cilium "$CILIUM_CHART" \
    --kube-context "$context" \
    --namespace "$CILIUM_NAMESPACE" \
    --reuse-values \
    --set "lbPool.blocks[0].start=${start}" \
    --set "lbPool.blocks[0].stop=${stop}"

  ok "Cilium ready in $cluster"
}


install() {
  for cluster in management workload; do
    install_cilium "$cluster"
    echo "--------------------------------"
  done

  ok "Cilium ready in all clusters"
}

case "${1:-install}" in
  install) install ;;
  *)
    echo "Usage: $0 [install]"
    exit 1
    ;;
esac
