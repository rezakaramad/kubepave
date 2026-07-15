#!/usr/bin/env bash
set -euo pipefail

# Configures Vault JWT auth for the clusters using each cluster's JWKS endpoint
# (served by the oidc-proxy chart via Traefik). Vault validates pod JWTs
# cryptographically — no long-lived reviewer token needed.
#
# Usage:
#   setup-vault.sh [management]   Configure jwt-management (default).
#   setup-vault.sh workload       Configure jwt-<tenant> for each workload cluster.
#
# The two are split because the management platform (Traefik/oidc-proxy) is up
# right after install-charts.sh, but each WORKLOAD platform only comes up once
# ArgoCD syncs it — which happens after setup-secrets.sh registers the cluster.
# So the workload JWT config must run at the very end of the bring-up.
#
# JWT auth is configured here (not in the Vault postStart hook) because it depends
# on oidc-proxy being reachable. Doing network waits in postStart would block the
# vault-0 pod from ever becoming Ready. postStart only handles init/unseal/policies.

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


# Returns the JWKS URL for a given cluster's oidc-proxy.
#
# We use jwks_url (not oidc_discovery_url) because Vault's discovery path requires
# the OIDC document's "issuer" to equal the discovery URL. The Kubernetes issuer is
# https://kubernetes.default.svc.cluster.local, but we fetch through the proxy host
# (oidc.<cluster>.<domain>), so those never match. jwks_url skips that check and
# fetches the signing keys directly; bound_issuer still pins the expected issuer.
cluster_jwks_url() {
  local cluster=$1
  case "$cluster" in
    management) echo "https://oidc.mgmt.${DNS_DOMAIN}/openid/v1/jwks" ;;
    workload)   echo "https://oidc.wl.${DNS_DOMAIN}/openid/v1/jwks" ;;
    *) err "No JWKS URL configured for cluster: $cluster"; exit 1 ;;
  esac
}


# -----------------------------------------------------
# Configure JWT auth backend for a cluster
# -----------------------------------------------------
configure_cluster_jwt() {
  local cluster=$1
  local max_retries="${2:-30}"
  local auth_path="jwt-${cluster}"
  local jwks_url
  jwks_url="$(cluster_jwks_url "$cluster")"

  log "Configuring JWT auth for $cluster (path: $auth_path, JWKS: $jwks_url)..."

  # Fetch the root CA from the management cluster so Vault trusts the oidc-proxy TLS cert.
  local root_ca
  root_ca=$(kubectl --context "$(kind_context management)" \
    -n platform-system \
    get secret root-ca \
    -o jsonpath='{.data.tls\.crt}' | base64 -d)

  # Copy CA into the vault pod to pass it to the vault write command.
  kubectl --context "$(kind_context management)" \
    -n "$VAULT_NAMESPACE" \
    exec -i vault-0 -- sh -c "cat > /tmp/root-ca-${cluster}.crt" <<< "$root_ca"

  vault_exec "vault auth enable -path=${auth_path} jwt 2>/dev/null || true"

  # Retry the config write until oidc-proxy is reachable — Vault fetches the JWKS
  # at config time to validate it. Workload platforms are synced by ArgoCD after
  # cluster registration, so this can take a few minutes to come up.
  log "Configuring $auth_path backend (waiting for oidc-proxy, up to $((max_retries * 3))s)..."
  local ok=false
  for i in $(seq 1 "$max_retries"); do
    if vault_exec "vault write auth/${auth_path}/config \
        jwks_url='${jwks_url}' \
        jwks_ca_pem=@/tmp/root-ca-${cluster}.crt \
        bound_issuer='https://kubernetes.default.svc.cluster.local'" >/dev/null 2>&1; then
      ok=true
      break
    fi
    sleep 3
  done
  if [ "$ok" != "true" ]; then
    err "Failed to configure $auth_path — oidc-proxy not reachable at $jwks_url"
    exit 1
  fi

  vault_exec "vault write auth/${auth_path}/role/eso-shared \
    role_type=jwt \
    bound_audiences='https://kubernetes.default.svc.cluster.local' \
    user_claim=sub \
    bound_subject='system:serviceaccount:platform-system:external-secrets' \
    policies=eso-shared-policy \
    ttl=1h"

  vault_exec "vault write auth/${auth_path}/role/eso-platform-system \
    role_type=jwt \
    bound_audiences='https://kubernetes.default.svc.cluster.local' \
    user_claim=sub \
    bound_subject='system:serviceaccount:platform-system:external-secrets' \
    policies=eso-platform-system-policy \
    ttl=1h"

  vault_exec "vault write auth/${auth_path}/role/crossplane \
    role_type=jwt \
    bound_audiences='https://kubernetes.default.svc.cluster.local' \
    user_claim=sub \
    bound_subject='system:serviceaccount:crossplane-system:crossplane' \
    policies=crossplane-policy \
    ttl=1h"

  vault_exec "vault write auth/${auth_path}/role/eso-argocd \
    role_type=jwt \
    bound_audiences='https://kubernetes.default.svc.cluster.local' \
    user_claim=sub \
    bound_subject='system:serviceaccount:argocd:argocd-server' \
    policies=eso-argocd-policy \
    ttl=1h"

  # keycloak only runs on the management cluster.
  if [ "$cluster" = "management" ]; then
    vault_exec "vault write auth/${auth_path}/role/keycloak \
      role_type=jwt \
      bound_audiences='https://kubernetes.default.svc.cluster.local' \
      user_claim=sub \
      bound_subject='system:serviceaccount:keycloak:keycloak' \
      policies=keycloak-policy \
      ttl=1h"
  fi

  vault_exec "rm -f /tmp/root-ca-${cluster}.crt"

  ok "JWT auth configured for $cluster"
}


wait_for_vault_bootstrap() {
  log "Waiting for Vault postStart bootstrap to complete (KV mount 'local')..."
  for i in $(seq 1 60); do
    if vault_exec "vault secrets list" 2>/dev/null | grep -q '^local/'; then
      ok "Vault bootstrap complete"
      return 0
    fi
    sleep 3
  done
  err "Vault bootstrap did not complete within 3 minutes"
  exit 1
}


save_credentials() {
  local vault_token
  vault_token="$(kubectl --context "$(kind_context management)" \
    -n "$VAULT_NAMESPACE" \
    exec vault-0 -- \
    sh -c "grep 'Initial Root Token:' /vault/data/init.txt | awk '{print \$4}'")"

  local creds_file="$REPO_ROOT/.platform.env"

  # Preserve existing entries (e.g. ARGOCD_ADMIN_PASSWORD written by setup-argocd.sh)
  # and add/update VAULT_ROOT_TOKEN
  if grep -q 'VAULT_ROOT_TOKEN' "$creds_file" 2>/dev/null; then
    sed -i "s|^export VAULT_ROOT_TOKEN=.*|export VAULT_ROOT_TOKEN=\"${vault_token}\"|" "$creds_file"
  else
    echo "export VAULT_ROOT_TOKEN=\"${vault_token}\"" >> "$creds_file"
  fi

  chmod 600 "$creds_file"
  ok "VAULT_ROOT_TOKEN saved to $creds_file"
}


main() {
  local target="${1:-management}"

  case "$target" in
    management)
      log "Waiting for Vault pod to be ready..."
      kubectl --context "$(kind_context management)" \
        -n "$VAULT_NAMESPACE" \
        wait pod vault-0 \
        --for=condition=Ready \
        --timeout=120s

      wait_for_vault_bootstrap

      configure_cluster_jwt management 30
      save_credentials

      echo ""
      ok "Vault JWT auth configured for management"
      echo ""
      echo "Workload JWT auth is configured later (after ArgoCD syncs each"
      echo "workload platform) via: setup-vault.sh workload"
      ;;

    workload|workloads)
      # Vault + management are already up. Each workload platform (Traefik,
      # oidc-proxy, external-dns) is synced by ArgoCD after the cluster is
      # registered in setup-secrets.sh, so the oidc-proxy endpoint can take a
      # few minutes to become reachable — use a generous retry budget.
      get_kind_tenant_clusters | while read -r cluster; do
        configure_cluster_jwt "$cluster" 120
        echo "--------------------------------"
      done

      echo ""
      ok "Vault JWT auth configured for workload clusters"
      ;;

    *)
      err "Unknown target: $target (expected 'management' or 'workload')"
      exit 1
      ;;
  esac
}

main "$@"
