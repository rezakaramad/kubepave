#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# install-charts.sh
#
# Bootstrap the local kind environment by installing shared platform charts.
# It prepares namespaces, bootstrap secrets, and core services for 
# management/development clusters.
# Argo CD finishes the development-side platform components after the cluster 
# is registered.
# -----------------------------------------------------------------------------

# Set the script directory to the current file's directory
DIR="$(cd "$(dirname "$0")" && pwd)"

# Import common functions and variables
source "$DIR/libs/common.sh"
source "$DIR/libs/utils.sh"

# Local secrets file containing sensitive information like API keys
SECRETS_FILE="$REPO_ROOT/.powerdns.env"


# -----------------------------------------------------------------------------
# Small wrapper around `helm upgrade --install`
# Usage: helm_install <release> <chart> <namespace> <context> [-f file ...] [--set ...]
# -----------------------------------------------------------------------------
helm_install() {
  # Function arguments:
  #   $1: release name
  #   $2: chart path
  #   $3: namespace
  #   $4: kube context
  #   $@: additional helm arguments
  local release=$1
  local chart=$2
  local namespace=$3
  local context=$4
  shift 4

  log "Installing $release → $namespace ($context)..."

  # Namespace handling for this repo's charts:
  #   - Each chart templates its OWN namespace (with helm.sh/resource-policy: keep)
  #     and installs into it, so Helm needs the namespace to exist to store the
  #     release secret, yet must also be able to import the chart's Namespace object.
  #   - We therefore pre-create the namespace ONLY when it does not already exist,
  #     stamping this release's Helm ownership metadata so the chart's own
  #     Namespace resource is adopted cleanly instead of triggering an
  #     "invalid ownership metadata" error.
  #   - Namespaces that already exist (e.g. the shared platform-system namespace
  #     created earlier by the platform-system chart) are left untouched, so their
  #     original owner is preserved and no ownership drift occurs.
  if [[ "$namespace" != "default" ]] \
    && ! kubectl --context "$context" get namespace "$namespace" >/dev/null 2>&1; then
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
    --timeout 5m \
    --wait \
    "$@" 2>&1; then
    ok "$release installed"
  else
    # If for whatever reason the upgrade fails, attempt to recover by uninstalling and reinstalling.
    warn "$release upgrade failed — attempting recovery..."
    helm uninstall "$release" \
      --kube-context "$context" \
      --namespace "$namespace" 2>/dev/null || true
    helm install "$release" "$chart" \
      --kube-context "$context" \
      --namespace "$namespace" \
      --timeout 5m \
      --wait \
      "$@"
    ok "$release installed (after recovery)"
  fi
}


# -----------------------------------------------------------------------------
# Install 'platform-system' chart: creates 'platform-system' namespace on all clusters. 
# 'platform-system' is a shared namespace for platform core components
# like cert-manager, external-secrets, etc. that are installed on all clusters.
# -----------------------------------------------------------------------------
install_platform_namespaces() {
  for cluster in management development; do
    helm_install platform-system "$CHARTS_DIR/platform-system" \
      "default" "$(kind_context "$cluster")"
  done
}


# -----------------------------------------------------------------------------
# Create the 'powerdns-api-key' secret in 'platform-system' on all clusters
# directly from the local secrets file.
# It takes the '.powerdns.env' file and creates a Kubernetes secret with the key-value pair.
# -----------------------------------------------------------------------------
create_powerdns_bootstrap_secret() {
  log "Creating bootstrap secrets..."

  # shellcheck source=/dev/null
  source "$SECRETS_FILE"

  for cluster in management development; do
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
# Install Traefik and wait for its LoadBalancer IP to be assigned by Cilium
# -----------------------------------------------------------------------------
install_traefik() {
  # Function arguments:
  #   $1: cluster name (management or development)
  # Local variables:
  #   context: kube context derived from cluster name
  local cluster=$1
  local context
  context="$(kind_context "$cluster")"

  # Install Traefik with Helm
  helm_install traefik "$CHARTS_DIR/traefik" \
    "$PLATFORM_NAMESPACE" "$context" \
    -f "$CHARTS_DIR/traefik/values.yaml" \
    -f "$CHARTS_DIR/traefik/values-local.yaml" \
    -f "$CHARTS_DIR/traefik/values-local-management.yaml"

  log "Waiting for Traefik LoadBalancer IP in $cluster..."

  local ip=""

  # Wait for the Traefik service to have an external IP assigned by Cilium.
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
  echo "$ip"
}


# -----------------------------------------------------------------------------
# Install external-dns (on 'management' cluster only).
# The 'development' external-dns is installed by ArgoCD once the development cluster is registered.
# and points at the management cluster's PowerDNS API via its stable Traefik hostname
# (see external-dns/values-local-development.yaml).
# -----------------------------------------------------------------------------
install_external_dns() {
  # Function arguments:
  #   $1: cluster name (management or development)
  # Local variables:
  #   context: kube context derived from cluster name
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
  # Function arguments:
  #   $1: cluster name (management or development)
  # Local variables:
  #   context: kube context derived from cluster name
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
  # Function arguments:
  #   $1: cluster name (management or development)
  local cluster=$1
  helm_install cert-manager "$CHARTS_DIR/cert-manager" \
    "$PLATFORM_NAMESPACE" "$(kind_context "$cluster")" \
    -f "$CHARTS_DIR/cert-manager/values.yaml" \
    -f "$CHARTS_DIR/cert-manager/values-local.yaml" \
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
  # Function arguments:
  #   $1: cluster name (management or development)
  local cluster=$1
  helm_install external-secrets "$CHARTS_DIR/external-secrets" \
    "$PLATFORM_NAMESPACE" "$(kind_context "$cluster")" \
    -f "$CHARTS_DIR/external-secrets/values.yaml" \
    -f "$CHARTS_DIR/external-secrets/values-local.yaml" \
    -f "$CHARTS_DIR/external-secrets/values-local-management.yaml"

  # Wait for webhook to be ready before anything tries to create external-secrets resources
  kubectl --context "$(kind_context "$cluster")" \
    -n "$PLATFORM_NAMESPACE" \
    wait deployment external-secrets-webhook \
    --for=condition=Available \
    --timeout=120s
}


# -----------------------------------------------------------------------------
# Install ArgoCD in the management cluster
# -----------------------------------------------------------------------------
install_argocd() {
  # Local variables:
  #   context: kube context derived from cluster name
  local context
  context="$(kind_context "$1")"

  helm_install argocd "$CHARTS_DIR/argocd" \
    "$ARGOCD_NAMESPACE" "$context" \
    -f "$CHARTS_DIR/argocd/values.yaml" \
    -f "$CHARTS_DIR/argocd/values-local.yaml"

  # Copy 'root-ca' into argocd namespace immediately after the namespace is created
  # so the 'vault-local' SecretStore finds it on its first reconcile and becomes Ready.
  log "Copying root-ca secret into $ARGOCD_NAMESPACE..."
  kubectl --context "$context" \
    get secret root-ca -n "$PLATFORM_NAMESPACE" -o json \
    | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.ownerReferences,.metadata.annotations,.metadata.managedFields) | .metadata.namespace = "'"$ARGOCD_NAMESPACE"'"' \
    | kubectl --context "$context" apply -f -

  # Wait for argocd-server so its CRDs (AppProject, Application) are registered,
  # then upgrade again to apply the gitops resources (AppProjects, App-of-Apps)
  # that were skipped on first install due to missing CRDs.
  log "Waiting for ArgoCD server to be ready..."
  kubectl --context "$context" \
    -n "$ARGOCD_NAMESPACE" \
    wait deployment argocd-server \
    --for=condition=Available \
    --timeout=120s

  log "Re-applying ArgoCD gitops resources (AppProjects, App-of-Apps)..."
  helm_install argocd "$CHARTS_DIR/argocd" \
    "$ARGOCD_NAMESPACE" "$context" \
    -f "$CHARTS_DIR/argocd/values.yaml" \
    -f "$CHARTS_DIR/argocd/values-local.yaml"
}


# -----------------------------------------------------------------------------
# Main bootstrap sequence
# -----------------------------------------------------------------------------
main() {
  # Check for the presence of the secrets file before proceeding.
  # Bootstrap local DNS by generating/loading PowerDNS secrets, creating K8s secrets, 
  # and deploying PowerDNS in the management kind cluster.
  # Then it wires your host resolver (systemd-resolved) so *.rezakara.demo queries
  # go to that PowerDNS instance, with reset removing that config and uninstalling PowerDNS
  if [[ ! -f "$SECRETS_FILE" ]]; then
    err "Secrets file not found: $SECRETS_FILE"
    err "Run ./setup-dns.sh start first"
    exit 1
  fi

  # Install external-dns and cert-manager CRDs first
  # so Helm doesn't manage them (avoids CRD upgrade conflicts)
  echo "-------- CRDs --------------------"
  for cluster in management development; do
    install_crds "$cluster"
  done

  # Install 'platform-system' namespace on all clusters where platform core components will be installed
  echo "-------- platform-system ---------"
  install_platform_namespaces

  # Install PowerDNS bootstrap secrets in 'platform-system' on all clusters
  echo "-------- bootstrap secrets -------"
  create_powerdns_bootstrap_secret

  # Install cert-manager on management cluster first so it can issue TLS certs for PowerDNS and Traefik
  echo "-------- cert-manager ------------"
  install_cert_manager management

  # Install external-secrets on management cluster first so it can read PowerDNS API key from the bootstrap secret
  echo "-------- external-secrets --------"
  install_external_secrets management

  # Install Traefik on management cluster first so it can expose PowerDNS and external-dns to the host network
  echo "-------- Traefik (management) ----"
  install_traefik management

  # Install Vault on management cluster so it can be used by ArgoCD and other components
  echo "-------- Vault -------------------"
  helm_install vault "$CHARTS_DIR/vault" \
    "$VAULT_NAMESPACE" "$(kind_context management)" \
    -f "$CHARTS_DIR/vault/values.yaml"

  # Install external-dns on management cluster so it can manage DNS records in PowerDNS
  echo "-------- external-dns (mgmt) -----"
  install_external_dns management

  # Install Argo CD on management cluster
  echo "-------- ArgoCD ------------------"
  install_argocd management

  echo ""
  ok "Bootstrap complete — management stack and ArgoCD installed"
  echo ""
  echo "Workload platform components (cert-manager, external-secrets, traefik,"
  echo "external-dns) are installed by ArgoCD once the development cluster is"
  echo "registered. Run in order:"
  echo "  ./setup-secrets.sh      # push secrets + register development with ArgoCD"
  echo "  ./setup-trust.sh        # distribute root CA to development + local trust"
  echo ""
  echo "Verify:"
  echo "  kubectl --context kind-management -n $ARGOCD_NAMESPACE get applications"
  echo "  kubectl --context kind-development   -n $PLATFORM_NAMESPACE get pods"
}

main "$@"
