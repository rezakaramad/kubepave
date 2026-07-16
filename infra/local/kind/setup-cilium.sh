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


# -----------------------------------------------------------------------------
# Install Cilium (CNI + L2 load-balancer) and configure the LoadBalancer IP pool.
#
# Two passes are required because Cilium registers the CiliumLoadBalancerIPPool /
# CiliumL2AnnouncementPolicy CRDs at runtime (they are not shipped as static CRDs):
#   1. install the CNI so nodes become Ready and the operator registers the CRDs
#   2. once both CRDs exist, apply the IP pool + L2 announcement policy
#
# The pool range is static and committed in values-local-{management,workload}.yaml
# (pinned to the pre-created kind Docker network 192.168.211.64/27).
# On real on-prem clusters the networking team provides a static range in the
# same values files. After bootstrap, ArgoCD adopts the Cilium release.
# -----------------------------------------------------------------------------
install_cilium() {
  local cluster=$1
  local context api_ip values_file

  context="$(kind_context "$cluster")"
  values_file="$CILIUM_CHART/values-local-${cluster}.yaml"

  # kube-proxy is disabled (kubeProxyMode: none); Cilium needs a direct address
  # for the API server since it can't resolve the in-cluster kubernetes Service yet.
  api_ip="$(get_control_plane_ip "$cluster")"

  # Pass 1 — CNI only (no pool; its CRDs don't exist yet).
  log "Installing Cilium in $cluster (CNI)..."
  helm upgrade --install cilium "$CILIUM_CHART" \
    --kube-context "$context" \
    --namespace "$CILIUM_NAMESPACE" \
    --values "$CILIUM_CHART/values.yaml" \
    --values "$values_file" \
    --set "cilium.k8sServiceHost=${api_ip}" \
    --set "cilium.k8sServicePort=6443" \
    --wait \
    --timeout 5m

  log "Waiting for nodes to become Ready in $cluster..."
  kubectl --context "$context" wait --for=condition=Ready nodes --all --timeout=120s

  # Pass 2 — apply the LoadBalancer IP pool now that its CRDs are registered.
  log "Waiting for Cilium LB CRDs in $cluster..."
  for crd in "$LB_POOL_CRD" "$L2_POLICY_CRD"; do
    for _ in $(seq 1 30); do
      kubectl --context "$context" get crd "$crd" >/dev/null 2>&1 && break
      sleep 2
    done
    kubectl --context "$context" wait --for=condition=Established \
      "crd/$crd" --timeout=60s
  done

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
