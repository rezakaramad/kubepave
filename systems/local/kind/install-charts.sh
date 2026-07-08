#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=libs/common.sh
source "$DIR/libs/common.sh"
# shellcheck source=libs/utils.sh
source "$DIR/libs/utils.sh"

SECRETS_FILE="$REPO_ROOT/.powerdns.env"


# -----------------------------------------------------------------------------
# Small wrapper around `helm upgrade --install`
# Usage: helm_install <release> <chart-dir> <namespace> <context> [-f file ...] [--set ...]
# -----------------------------------------------------------------------------
helm_install() {
  local release=$1
  local chart=$2
  local namespace=$3
  local context=$4
  shift 4

  log "Installing $release → $namespace ($context)..."

  # Pre-create the namespace with Helm's required ownership labels/annotations
  # so that --create-namespace finds it already correct on both first runs and
  # re-runs after a failure. This avoids the "invalid ownership metadata" error
  # without any imperative kubectl annotate/label calls.
  if [[ "$namespace" != "default" ]]; then
    kubectl --context "$context" apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${namespace}
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: ${release}
    meta.helm.sh/release-namespace: ${namespace}
EOF
  fi

  if helm upgrade --install "$release" "$chart" \
    --kube-context "$context" \
    --namespace "$namespace" \
    --create-namespace \
    --timeout 5m \
    --wait \
    "$@" 2>&1; then
    ok "$release installed"
  else
    warn "$release upgrade failed — attempting recovery..."
    helm uninstall "$release" \
      --kube-context "$context" \
      --namespace "$namespace" 2>/dev/null || true
    helm install "$release" "$chart" \
      --kube-context "$context" \
      --namespace "$namespace" \
      --create-namespace \
      --timeout 5m \
      --wait \
      "$@"
    ok "$release installed (after recovery)"
  fi
}


# -----------------------------------------------------------------------------
# Install platform-system chart — creates platform-system namespace on
# the management cluster (with helm.sh/resource-policy: keep).
# Each other chart creates its own namespace via its namespace.yaml template.
# -----------------------------------------------------------------------------
install_platform_namespaces() {
  for cluster in management workload; do
    helm_install platform-system "$CHARTS_DIR/platform-system" \
      "default" "$(kind_context "$cluster")"
  done
}


# -----------------------------------------------------------------------------
# Create the powerdns-api-key secret in platform-system on all clusters
# directly from the local secrets file. The secret never rotates in a local
# kind setup so there is no need to run it through Vault/ESO.
# -----------------------------------------------------------------------------
create_mgmt_bootstrap_secrets() {
  log "Creating bootstrap secrets..."

  # shellcheck source=/dev/null
  source "$SECRETS_FILE"

  for cluster in management workload; do
    kubectl --context "$(kind_context "$cluster")" \
      -n "$PLATFORM_NAMESPACE" \
      create secret generic powerdns-api-key \
      --from-literal=key="$POWERDNS_API_KEY" \
      --dry-run=client -o yaml \
      | kubectl --context "$(kind_context "$cluster")" apply -f -
  done

  ok "Bootstrap secrets created on all clusters"
}


# -----------------------------------------------------------------------------
# Install Traefik and wait for its LoadBalancer IP to be assigned by metallb
# -----------------------------------------------------------------------------
install_traefik() {
  local cluster=$1
  local context
  context="$(kind_context "$cluster")"

  helm_install traefik "$CHARTS_DIR/traefik" \
    "$PLATFORM_NAMESPACE" "$context" \
    -f "$CHARTS_DIR/traefik/values.yaml" \
    -f "$CHARTS_DIR/traefik/values-local.yaml" \
    -f "$CHARTS_DIR/traefik/values-local-management.yaml"

  log "Waiting for Traefik LoadBalancer IP in $cluster..."

  local ip=""
  for _ in {1..60}; do
    ip=$(kubectl --context "$context" \
      -n "$PLATFORM_NAMESPACE" \
      get svc traefik \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

    [[ -n "$ip" ]] && break
    sleep 2
  done

  if [[ -z "$ip" ]]; then
    err "Timed out waiting for Traefik LB IP in $cluster"
    exit 1
  fi

  ok "Traefik running in $cluster at $ip"
  echo "$ip"  # return the IP for callers
}


# -----------------------------------------------------------------------------
# Install external-dns (management only).
# The workload external-dns is installed by ArgoCD and points at the management
# PowerDNS API via its stable Traefik hostname (see external-dns/values-local-workload.yaml).
# -----------------------------------------------------------------------------
install_external_dns() {
  local cluster=$1
  local context
  context="$(kind_context "$cluster")"

  helm_install external-dns "$CHARTS_DIR/external-dns" \
    "$PLATFORM_NAMESPACE" "$context" \
    -f "$CHARTS_DIR/external-dns/values.yaml" \
    -f "$CHARTS_DIR/external-dns/values-local.yaml" \
    -f "$CHARTS_DIR/external-dns/values-local-management.yaml"
}


# -----------------------------------------------------------------------------
# Install CRDs for cert-manager and external-secrets.
# CRDs are installed separately (server-side apply) before the controllers
# so Helm doesn't need to manage them (avoids CRD upgrade conflicts).
# -----------------------------------------------------------------------------
install_crds() {
  local cluster=$1
  local context
  context="$(kind_context "$cluster")"

  log "Installing CRDs in $cluster..."

  kubectl --context "$context" apply --server-side \
    -f "$CHARTS_DIR/external-secrets/crds/bundle.yaml"

  kubectl --context "$context" apply --server-side \
    -f "$CHARTS_DIR/cert-manager/crds/bundle.yaml"

  ok "CRDs installed in $cluster"
}


# -----------------------------------------------------------------------------
# Install cert-manager
# -----------------------------------------------------------------------------
install_cert_manager() {
  local cluster=$1
  helm_install cert-manager "$CHARTS_DIR/cert-manager" \
    "$PLATFORM_NAMESPACE" "$(kind_context "$cluster")" \
    -f "$CHARTS_DIR/cert-manager/values.yaml" \
    -f "$CHARTS_DIR/cert-manager/values-local-management.yaml"

  # Wait for webhook to be ready before anything tries to create cert-manager resources
  kubectl --context "$(kind_context "$cluster")" \
    -n "$PLATFORM_NAMESPACE" \
    wait deployment cert-manager-webhook \
    --for=condition=Available \
    --timeout=120s
}


# -----------------------------------------------------------------------------
# Install external-secrets
# -----------------------------------------------------------------------------
install_external_secrets() {
  local cluster=$1
  helm_install external-secrets "$CHARTS_DIR/external-secrets" \
    "$PLATFORM_NAMESPACE" "$(kind_context "$cluster")" \
    -f "$CHARTS_DIR/external-secrets/values.yaml" \
    -f "$CHARTS_DIR/external-secrets/values-local.yaml" \
    -f "$CHARTS_DIR/external-secrets/values-local-management.yaml"

  kubectl --context "$(kind_context "$cluster")" \
    -n "$PLATFORM_NAMESPACE" \
    wait deployment external-secrets-webhook \
    --for=condition=Available \
    --timeout=120s
}


# -----------------------------------------------------------------------------
# Install ArgoCD into the management cluster
# -----------------------------------------------------------------------------
install_argocd() {
  local context
  context="$(kind_context management)"

  helm_install argocd "$CHARTS_DIR/argocd" \
    "$ARGOCD_NAMESPACE" "$context" \
    -f "$CHARTS_DIR/argocd/values.yaml" \
    -f "$CHARTS_DIR/argocd/values-local.yaml"

  # Wait for argocd-server so its CRDs (AppProject, Application) are registered,
  # then upgrade again to apply the gitops resources (AppProjects, App-of-Apps)
  # that were skipped on first install due to missing CRDs.
  log "Waiting for ArgoCD server to be ready..."
  kubectl --context "$context" \
    -n "$ARGOCD_NAMESPACE" \
    wait deployment argocd-server \
    --for=condition=Available \
    --timeout=120s

  log "Applying ArgoCD gitops resources (AppProjects, App-of-Apps)..."
  helm_install argocd "$CHARTS_DIR/argocd" \
    "$ARGOCD_NAMESPACE" "$context" \
    -f "$CHARTS_DIR/argocd/values.yaml" \
    -f "$CHARTS_DIR/argocd/values-local.yaml"
}


# -----------------------------------------------------------------------------
# Main bootstrap sequence
# -----------------------------------------------------------------------------
main() {
  if [[ ! -f "$SECRETS_FILE" ]]; then
    err "Secrets file not found: $SECRETS_FILE"
    err "Run ./setup-dns.sh start first"
    exit 1
  fi

  echo "-------- CRDs --------------------"
  for cluster in management workload; do
    install_crds "$cluster"
  done

  echo "-------- platform-system ---------"
  install_platform_namespaces

  echo "-------- bootstrap secrets -------"
  create_mgmt_bootstrap_secrets

  echo "-------- cert-manager ------------"
  install_cert_manager management

  echo "-------- external-secrets --------"
  install_external_secrets management

  echo "-------- Vault -------------------"
  helm_install vault "$CHARTS_DIR/vault" \
    "$VAULT_NAMESPACE" "$(kind_context management)" \
    -f "$CHARTS_DIR/vault/values.yaml"

  echo "-------- Traefik (management) ----"
  install_traefik management

  echo "-------- external-dns (mgmt) -----"
  install_external_dns management

  echo "-------- workload seed -----------"
  # workload-vault-seed provisions the vault-reviewer ServiceAccount + token-review
  # RBAC on the workload cluster. It MUST exist before setup-vault.sh configures
  # the kubernetes-workload auth backend, so it is installed imperatively here.
  helm_install workload-vault-seed "$CHARTS_DIR/workload-vault-seed" \
    "default" "$(kind_context workload)"

  echo "-------- ArgoCD ------------------"
  install_argocd

  echo ""
  ok "Bootstrap complete — management stack and ArgoCD installed"
  echo ""
  echo "Workload platform components (cert-manager, external-secrets, traefik,"
  echo "external-dns) are installed by ArgoCD once the workload cluster is"
  echo "registered. Run in order:"
  echo "  ./setup-vault.sh      # configure Vault auth for workload"
  echo "  ./setup-secrets.sh    # push secrets + register workload with ArgoCD"
  echo "  ./setup-trust.sh      # distribute root CA to workload + local trust"
  echo ""
  echo "Verify:"
  echo "  kubectl --context kind-management -n $ARGOCD_NAMESPACE get applications"
  echo "  kubectl --context kind-workload   -n $PLATFORM_NAMESPACE get pods"
}

main "$@"
