#!/usr/bin/env bash
set -euo pipefail

# Configures Vault JWT auth for ALL clusters (management + workloads).
#
# Vault validates pod JWTs cryptographically by fetching each cluster's public
# signing keys (JWKS) DIRECTLY from that cluster's API server:
#
#   https://<cluster-api-server>/openid/v1/jwks
#
# This is the standard hub-and-spoke pattern: a central Vault reaches each
# cluster's API server directly (the same way ArgoCD reaches spoke clusters at
# https://<node-ip>:6443). It deliberately does NOT route through the cluster's
# own Traefik ingress, doing so creates a bootstrap cycle on workload clusters
# (Gateway needs a cert → cert needs ESO SecretStore → SecretStore needs Vault
# JWT auth → JWT auth needs the ingress that isn't up yet).
#
# Because the fetch only needs the API server (up as soon as the kind cluster
# exists), both management and workload auth are configured in a single run —
# no dependency on ArgoCD, Traefik, cert-manager or DNS.
#
# JWT auth is configured here (not in the Vault postStart hook) so the vault-0
# pod never blocks on network waits. postStart only handles init/unseal/policies.

DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=libs/common.sh
source "$DIR/libs/common.sh"
# shellcheck source=libs/utils.sh
source "$DIR/libs/utils.sh"

# ClusterRole (built into every cluster) that grants GET on the two OIDC
# discovery paths and nothing else.
OIDC_DISCOVERY_CLUSTERROLE="system:service-account-issuer-discovery"
# ClusterRoleBinding we create to allow anonymous callers to read those paths.
OIDC_DISCOVERY_CRB="vault-anonymous-oidc-discovery"


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


# Returns the API server URL reachable from the Vault pod for a given cluster.
# Uses the node's InternalIP:6443 — reachable across the shared kind Docker
# network, exactly like the ArgoCD hub→spoke connection.
cluster_api_url() {
  local cluster=$1
  local node_ip
  node_ip=$(kubectl --context "$(kind_context "$cluster")" get node \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  echo "https://${node_ip}:6443"
}


# Allow anonymous callers to read the OIDC discovery endpoints on a cluster.
# Vault fetches the JWKS without credentials, so without this the API server
# returns 403. The binding is idempotent.
grant_anonymous_oidc_discovery() {
  local cluster=$1
  kubectl --context "$(kind_context "$cluster")" \
    create clusterrolebinding "$OIDC_DISCOVERY_CRB" \
    --clusterrole="$OIDC_DISCOVERY_CLUSTERROLE" \
    --group=system:unauthenticated \
    --dry-run=client -o yaml \
    | kubectl --context "$(kind_context "$cluster")" apply -f - >/dev/null
}


# -----------------------------------------------------
# Configure JWT auth backend for a cluster
# -----------------------------------------------------
configure_cluster_jwt() {
  local cluster=$1
  local auth_path="jwt-${cluster}"
  local api_url jwks_url
  api_url="$(cluster_api_url "$cluster")"
  jwks_url="${api_url}/openid/v1/jwks"

  log "Configuring JWT auth for $cluster (path: $auth_path, JWKS: $jwks_url)..."

  # Let Vault read the discovery endpoints anonymously.
  grant_anonymous_oidc_discovery "$cluster"

  # Copy the target cluster's API server CA into the vault pod so Vault trusts
  # the API server's TLS cert when fetching the JWKS.
  local api_ca
  api_ca=$(kubectl --context "$(kind_context "$cluster")" \
    config view --raw --minify \
    -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)

  kubectl --context "$(kind_context management)" \
    -n "$VAULT_NAMESPACE" \
    exec -i vault-0 -- sh -c "cat > /tmp/api-ca-${cluster}.crt" <<< "$api_ca"

  vault_exec "vault auth enable -path=${auth_path} jwt 2>/dev/null || true"

  # Retry briefly to absorb transient API server unreadiness. No long wait is
  # needed — the API server is up as soon as the kind cluster exists.
  log "Configuring $auth_path backend..."
  local ok=false
  for i in $(seq 1 20); do
    if vault_exec "vault write auth/${auth_path}/config \
        jwks_url='${jwks_url}' \
        jwks_ca_pem=@/tmp/api-ca-${cluster}.crt \
        bound_issuer='https://kubernetes.default.svc.cluster.local'" >/dev/null 2>&1; then
      ok=true
      break
    fi
    sleep 3
  done
  if [ "$ok" != "true" ]; then
    err "Failed to configure $auth_path — API server not reachable at $jwks_url"
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

  # keycloak and backstage only run on the management cluster.
  if [ "$cluster" = "management" ]; then
    vault_exec "vault write auth/${auth_path}/role/keycloak \
      role_type=jwt \
      bound_audiences='https://kubernetes.default.svc.cluster.local' \
      user_claim=sub \
      bound_subject='system:serviceaccount:keycloak:keycloak' \
      policies=keycloak-policy \
      ttl=1h"

    vault_exec "vault write auth/${auth_path}/role/backstage \
      role_type=jwt \
      bound_audiences='https://kubernetes.default.svc.cluster.local' \
      user_claim=sub \
      bound_subject='system:serviceaccount:backstage:backstage' \
      policies=backstage-policy \
      ttl=1h"

    # crossplane provider-vault runs on the management cluster. Its pod runs a
    # Vault Agent sidecar (see the DeploymentRuntimeConfig) that logs in here
    # with the provider-vault ServiceAccount JWT and maintains a short-lived
    # token for the provider — same JWT auth model as ESO, no static secret.
    vault_exec "vault write auth/${auth_path}/role/provider-vault \
      role_type=jwt \
      bound_audiences='https://kubernetes.default.svc.cluster.local' \
      user_claim=sub \
      bound_subject='system:serviceaccount:crossplane-system:provider-vault' \
      policies=provider-vault-policy \
      ttl=1h"
  fi

  vault_exec "rm -f /tmp/api-ca-${cluster}.crt"

  ok "JWT auth configured for $cluster"
}


# -----------------------------------------------------------------------------
# Configure a shared JWT auth backend for tenant service accounts.
#
# Uses a separate backend (jwt-workload-tenants) so existing roles on jwt-workload are not disrupted.
#
# user_claim is set to the namespace JSON pointer so Vault entity aliases become
# the bare namespace name (e.g. "foo") rather than the full sub string
# ("system:serviceaccount:foo:external-secrets"). This is what makes the
# identity-templated tenant-policy resolve to the correct per-tenant path.
# -----------------------------------------------------------------------------
configure_tenant_jwt() {
  local cluster="workload"
  local auth_path="jwt-workload-tenants"
  local api_url jwks_url api_ca

  api_url="$(cluster_api_url "$cluster")"
  jwks_url="${api_url}/openid/v1/jwks"

  log "Configuring $auth_path backend (namespace-scoped user_claim)..."

  # Reuse the API server CA that configure_cluster_jwt already copied.
  # Copy it again under a stable name for this backend.
  api_ca=$(kubectl --context "$(kind_context "$cluster")" \
    config view --raw --minify \
    -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)

  kubectl --context "$(kind_context management)" \
    -n "$VAULT_NAMESPACE" \
    exec -i vault-0 -- sh -c "cat > /tmp/api-ca-${auth_path}.crt" <<< "$api_ca"

  vault_exec "vault auth enable -path=${auth_path} jwt 2>/dev/null || true"

  log "Configuring $auth_path JWKS (${jwks_url})..."
  local ok=false
  for i in $(seq 1 20); do
    if vault_exec "vault write auth/${auth_path}/config \
        jwks_url='${jwks_url}' \
        jwks_ca_pem=@/tmp/api-ca-${auth_path}.crt \
        bound_issuer='https://kubernetes.default.svc.cluster.local'" >/dev/null 2>&1; then
      ok=true
      break
    fi
    sleep 3
  done
  if [ "$ok" != "true" ]; then
    err "Failed to configure $auth_path — API server not reachable at $jwks_url"
    exit 1
  fi

  # Retrieve the accessor for this backend so we can embed it in the
  # identity-templated policy. The accessor is stable for the lifetime of the
  # auth backend (it changes only if the backend is disabled and re-enabled).
  local accessor
  accessor=$(vault_exec "vault auth list -format=json" \
    | jq -r ".\"${auth_path}/\".accessor")

  log "Writing tenant-policy (accessor: $accessor)..."

  vault_exec "vault policy write tenant-policy - <<EOF
path \"tenants/data/{{identity.entity.aliases[${accessor}].name}}/*\" {
  capabilities = [\"read\", \"list\", \"create\", \"update\", \"delete\"]
}

path \"tenants/metadata/{{identity.entity.aliases[${accessor}].name}}/*\" {
  capabilities = [\"read\", \"list\", \"delete\"]
}
EOF"

  vault_exec "rm -f /tmp/api-ca-${auth_path}.crt"

  ok "$auth_path configured and tenant-policy written"
}


# -----------------------------------------------------------------------------
# Enable + configure the OIDC auth method for HUMAN tenant operators.
#
# Machine auth (JWT backends above) isolates pods by namespace. This method is
# different: it lets a human log into the Vault UI/CLI with Azure Entra ID and
# receive ONLY their own tenant's Vault policy.
#
# Isolation is keyed on the `roles` claim (Entra ID app-role value = tenant
# name), mirroring the ArgoCD SSO pattern. The per-tenant AppRole/Group/
# RoleAssignment on the Entra side are composed by the xtenantentra Crossplane
# function; the matching per-tenant Vault Policy + external Identity Group +
# GroupAlias are provisioned by the tenant-management chart (Phase 4). Here we
# only stand up the method itself and a single `default` role.
#
# Credentials come from `pass` (populated by tofu-to-pass.sh) — the OIDC config
# is a one-time Vault bootstrap, so there is no need to round-trip it through
# Vault KV like the workload app secrets.
# -----------------------------------------------------------------------------
configure_oidc() {
  log "Configuring Vault OIDC auth (Entra ID) for human tenant operators..."

  local client_id tenant_id client_secret
  client_id=$(pass show private/azure/entraid/apps/vault/client-id | head -n1)
  tenant_id=$(pass show private/azure/entraid/apps/tenant-id | head -n1)
  client_secret=$(pass show private/azure/entraid/apps/vault/client-secrets/vault/value | head -n1)

  if [ -z "$client_id" ] || [ -z "$tenant_id" ] || [ -z "$client_secret" ]; then
    err "Missing Vault Entra ID credentials in pass (vault client-id / tenant-id / client-secret)"
    exit 1
  fi

  local discovery_url="https://login.microsoftonline.com/${tenant_id}/v2.0"

  # Enable the method at path 'oidc' (idempotent).
  vault_exec "vault auth enable -path=oidc oidc 2>/dev/null || true"

  # Configure the method. The client secret is piped over stdin so it never
  # appears in kubectl argv / process listings on the host.
  log "Writing auth/oidc/config (discovery: $discovery_url)..."
  printf '%s' "$client_secret" | \
    kubectl --context "$(kind_context management)" \
      -n "$VAULT_NAMESPACE" \
      exec -i vault-0 -- sh -c "
        export VAULT_ADDR=http://127.0.0.1:8200
        export VAULT_TOKEN=\$(grep 'Initial Root Token:' /vault/data/init.txt | awk '{print \$4}')
        secret=\$(cat)
        vault write auth/oidc/config \
          oidc_discovery_url='${discovery_url}' \
          oidc_client_id='${client_id}' \
          oidc_client_secret=\"\$secret\" \
          default_role=default
      "

  # Default role: users land here on login. `groups_claim=roles` maps each
  # Entra ID app-role value (= tenant name) to a Vault external Identity Group.
  # Only the built-in `default` policy is granted at login; per-tenant access
  # comes solely from group membership (Phase 4), so a user with no tenant
  # app-role assignment gets no tenant path at all.
  vault_exec "vault write auth/oidc/role/default \
    role_type=oidc \
    user_claim=sub \
    groups_claim=roles \
    oidc_scopes='openid,profile,email' \
    token_policies=default \
    token_ttl=1h \
    allowed_redirect_uris='https://vault.mgmt.rezakara.demo/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback'"

  # The mount accessor is stable for the lifetime of the backend and is needed
  # by the per-tenant GroupAlias in Phase 4. Persist it for the chart wiring.
  local accessor
  accessor=$(vault_exec "vault auth list -format=json" | jq -r '."oidc/".accessor')

  save_oidc_accessor "$accessor"

  ok "Vault OIDC auth configured (accessor: $accessor)"
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

  # Preserve existing entries and add/update VAULT_ROOT_TOKEN
  if grep -q 'VAULT_ROOT_TOKEN' "$creds_file" 2>/dev/null; then
    sed -i "s|^export VAULT_ROOT_TOKEN=.*|export VAULT_ROOT_TOKEN=\"${vault_token}\"|" "$creds_file"
  else
    echo "export VAULT_ROOT_TOKEN=\"${vault_token}\"" >> "$creds_file"
  fi

  chmod 600 "$creds_file"
  ok "VAULT_ROOT_TOKEN saved to $creds_file"
}


# Persist the OIDC mount accessor so the tenant-management chart (Phase 4) can
# reference it for the per-tenant Identity GroupAlias mount_accessor.
save_oidc_accessor() {
  local accessor="$1"
  local creds_file="$REPO_ROOT/.platform.env"

  if grep -q 'VAULT_OIDC_ACCESSOR' "$creds_file" 2>/dev/null; then
    sed -i "s|^export VAULT_OIDC_ACCESSOR=.*|export VAULT_OIDC_ACCESSOR=\"${accessor}\"|" "$creds_file"
  else
    echo "export VAULT_OIDC_ACCESSOR=\"${accessor}\"" >> "$creds_file"
  fi

  chmod 600 "$creds_file"
  ok "VAULT_OIDC_ACCESSOR saved to $creds_file"
}


main() {
  log "Waiting for Vault pod to be ready..."
  kubectl --context "$(kind_context management)" \
    -n "$VAULT_NAMESPACE" \
    wait pod vault-0 \
    --for=condition=Ready \
    --timeout=120s

  wait_for_vault_bootstrap

  # Configure the management cluster first, then each workload cluster. Both are
  # reachable directly at their API server, so no ordering dependency on ArgoCD.
  configure_cluster_jwt management
  echo "--------------------------------"

  get_kind_tenant_clusters | while read -r cluster; do
    configure_cluster_jwt "$cluster"
    echo "--------------------------------"
  done

  # Configure the shared tenant JWT backend (jwt-workload-tenants) and write
  # the identity-templated tenant-policy. Must run after configure_cluster_jwt
  # workload so the workload API server CA is available.
  configure_tenant_jwt
  echo "--------------------------------"

  # Configure the OIDC method for human tenant operators (Entra ID SSO).
  configure_oidc
  echo "--------------------------------"

  save_credentials

  echo ""
  ok "Vault JWT auth configured for all clusters"
}

main "$@"
