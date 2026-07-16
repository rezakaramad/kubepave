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
L2_POLICY_CRD="ciliuml2announcementpolicies.cilium.io"


install_cilium() {
  local cluster=$1
  local context api_ip values_file

  context="$(kind_context "$cluster")"
  values_file="$CILIUM_CHART/values-local-${cluster}.yaml"

  # kube-proxy is disabled (kubeProxyMode: none); Cilium needs a direct address
  # for the API server since it can't resolve the in-cluster kubernetes Service yet.
  api_ip="$(get_control_plane_ip "$cluster")"

  # Install Cilium via Helm without the LB pool (CRDs don't exist yet).
  # The lbPool.blocks override disables lb-pool.yaml template rendering so
  # Helm doesn't try to create CiliumLoadBalancerIPPool / CiliumL2AnnouncementPolicy
  # before the CRDs are established.
  log "Installing Cilium in $cluster (CNI)..."
  helm upgrade --install cilium "$CILIUM_CHART" \
    --kube-context "$context" \
    --namespace "$CILIUM_NAMESPACE" \
    --values "$CILIUM_CHART/values.yaml" \
    --values "$values_file" \
    --set "cilium.k8sServiceHost=${api_ip}" \
    --set "cilium.k8sServicePort=6443" \
    --set "lbPool.blocks=" \
    --wait \
    --timeout 5m

  log "Waiting for nodes to become Ready in $cluster..."
  kubectl --context "$context" wait --for=condition=Ready nodes --all --timeout=120s

  log "Waiting for Cilium LB CRDs in $cluster..."
  for crd in "$LB_POOL_CRD" "$L2_POLICY_CRD"; do
    for _ in $(seq 1 30); do
      kubectl --context "$context" get crd "$crd" >/dev/null 2>&1 && break
      sleep 2
    done
    kubectl --context "$context" wait --for=condition=Established \
      "crd/$crd" --timeout=60s
  done

  # Install the LB pool and L2 announcement policy for this cluster. The pool
  # range is computed at runtime from the kind Docker network CIDR and injected
  # via the values file, so it is always correct even if the kind network changes.
  log "Configuring Cilium LB pool in $cluster..."
  helm upgrade cilium "$CILIUM_CHART" \
    --kube-context "$context" \
    --namespace "$CILIUM_NAMESPACE" \
    --reuse-values \
    --values "$values_file"

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
