#!/usr/bin/env bash
set -euo pipefail

# Configures Vault Kubernetes auth for the workload cluster so that
# external-secrets running there can authenticate to Vault and read secrets.
#
# The management cluster auth backend is already configured by Vault's
# postStart hook in the Helm chart — this script only handles workload clusters.

DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=libs/common.sh
source "$DIR/libs/common.sh"
# shellcheck source=libs/utils.sh
source "$DIR/libs/utils.sh"


# Run a vault command inside the vault pod.
# Avoids CLI/server version mismatch — always uses the same binary as the server.
vault_exec() {
  kubectl --context "$(kind_context management)" \
    -n "$VAULT_NAMESPACE" \
    exec vault-0 -- \
    sh -c "
      export VAULT_ADDR=http://127.0.0.1:8200
      export VAULT_TOKEN=\$(grep 'Initial Root Token:' /vault/data/init.txt | awk '{print \$4}')
      $*
    "
}


# -----------------------------------------------------
# Ensure vault-reviewer ServiceAccount token exists
# -----------------------------------------------------
ensure_reviewer_token() {
  local cluster=$1
  local context
  context="$(kind_context "$cluster")"

  log "Ensuring vault-reviewer token in $cluster..."

  kubectl --context "$context" -n kube-system \
    get sa vault-reviewer >/dev/null 2>&1 || {
    err "vault-reviewer ServiceAccount missing in $cluster"
    err "Install workload-vault-seed first: helm install workload-vault-seed charts/workload-vault-seed ..."
    exit 1
  }

  if ! kubectl --context "$context" -n kube-system \
      get secret vault-reviewer-token >/dev/null 2>&1; then

    log "Creating long-lived reviewer token..."

    kubectl --context "$context" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: vault-reviewer-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: vault-reviewer
type: kubernetes.io/service-account-token
EOF

    for _ in {1..10}; do
      kubectl --context "$context" -n kube-system \
        get secret vault-reviewer-token \
        -o jsonpath='{.data.token}' 2>/dev/null | grep -q . && break
      sleep 1
    done
  fi

  ok "vault-reviewer token ready in $cluster"
}


# -----------------------------------------------------
# Configure Kubernetes auth backend for a cluster
# -----------------------------------------------------
configure_cluster() {
  local cluster=$1
  local context
  context="$(kind_context "$cluster")"
  local auth_path="kubernetes-${cluster}"

  log "Configuring Vault auth for $cluster (path: $auth_path)..."

  ensure_reviewer_token "$cluster"

  local node_ip reviewer_jwt ca_cert
  node_ip=$(kubectl --context "$context" get node \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

  reviewer_jwt=$(kubectl --context "$context" \
    -n kube-system get secret vault-reviewer-token \
    -o jsonpath='{.data.token}' | base64 -d)

  ca_cert=$(kubectl --context "$context" \
    -n kube-system get secret vault-reviewer-token \
    -o jsonpath='{.data.ca\.crt}' | base64 -d)

  log "API server: https://${node_ip}:6443"

  # Copy CA cert into the pod via stdin to avoid heredoc quoting issues
  kubectl --context "$(kind_context management)" \
    -n "$VAULT_NAMESPACE" \
    exec -i vault-0 -- sh -c "cat > /tmp/ca-${cluster}.crt" <<< "$ca_cert"

  vault_exec "vault auth enable -path=${auth_path} kubernetes 2>/dev/null || true"

  vault_exec "vault write auth/${auth_path}/config \
    token_reviewer_jwt='${reviewer_jwt}' \
    kubernetes_host='https://${node_ip}:6443' \
    kubernetes_ca_cert=@/tmp/ca-${cluster}.crt \
    disable_iss_validation=true"

  vault_exec "vault write auth/${auth_path}/role/external-secrets \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=platform-system \
    policies=eso-policy \
    audience=https://kubernetes.default.svc.cluster.local \
    ttl=1h"

  vault_exec "vault write auth/${auth_path}/role/crossplane \
    bound_service_account_names=crossplane \
    bound_service_account_namespaces=crossplane-system \
    policies=crossplane-policy \
    audience=https://kubernetes.default.svc.cluster.local \
    ttl=1h"

  vault_exec "rm -f /tmp/ca-${cluster}.crt"

  ok "Vault auth configured for $cluster"
}


main() {
  log "Waiting for Vault to be ready..."
  kubectl --context "$(kind_context management)" \
    -n "$VAULT_NAMESPACE" \
    wait pod vault-0 \
    --for=condition=Ready \
    --timeout=120s

  get_kind_tenant_clusters | while read -r cluster; do
    configure_cluster "$cluster"
    echo "--------------------------------"
  done

  echo ""
  ok "Vault Kubernetes auth configured for all workload clusters"
}

main "$@"
