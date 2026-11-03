#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# setup-openbao.sh
# Configures OpenBao JWT/OIDC auth for the path-based tenancy topology.
#
# Path-based topology (single root namespace; tenants isolated by PATH + ACL,
# auth + policy stay centrally owned by the platform team, never self-administered
# by tenants):
#
#   Everything lives in the root namespace. Three root KV v2 mounts:
#     kv/              — platform-component secrets (kv/data/<component>/*).
#     kv-management/   — management-cluster tenant secrets.
#     kv-development/  — development-cluster tenant secrets (kv-development/data/<tenant>/*).
#
#   Auth backends (all root):
#     jwt-management / jwt-development — bootstrap roles only (shared, platform-system,
#         crossplane, argocd, provider-vault). keycloak/backstage/observability
#         roles + policies and the `tenant` role + tenant-policy are managed by
#         Crossplane provider-vault (crossplane chart, vaultProvider).
#     jwt-development-tenants — validates development-cluster tenant ServiceAccount
#         tokens. Only the backend + JWKS config live here.
#     oidc — central human-operator method (Entra ID).
#
# OpenBao validates pod JWTs by fetching each cluster's public signing keys (JWKS) from that
# cluster's issuer URL (<issuer>/openid/v1/jwks, see sa_issuer), the same way every other consumer does.
# The issuer names resolve through CoreDNS and the API server cert is signed by the shared cluster CA.
# The KV bootstrap (init/unseal/mounts/
# policies) is done by the chart postStart hook; this script only adds the parts
# that need cluster API access (JWKS) plus OIDC.
# -----------------------------------------------------------------------------

# Set the script directory to the current file's directory
DIR="$(cd "$(dirname "$0")" && pwd)"

# Import common functions and variables
source "$DIR/libs/common.sh"
source "$DIR/libs/utils.sh"

# ClusterRole (built into every cluster) that grants GET on the two OIDC
# discovery paths and nothing else.
OIDC_DISCOVERY_CLUSTERROLE="system:service-account-issuer-discovery"
# ClusterRoleBinding we create to allow anonymous callers to read those paths.
OIDC_DISCOVERY_CRB="openbao-anonymous-oidc-discovery"


# Run a bao command inside the openbao pod.
# Avoids CLI/server version mismatch — always uses the same binary as the server.
bao_exec() {
  kubectl --context "$(kind_context management)" \
    -n "$OPENBAO_NAMESPACE" \
    exec openbao-0 -- \
    sh -c "
      export BAO_ADDR=http://127.0.0.1:8200
      export BAO_TOKEN=\$(grep 'Initial Root Token:' /openbao/data/init.txt | awk '{print \$4}')
      $*
    "
}


# Allow anonymous callers to read the OIDC discovery endpoints on a cluster.
# OpenBao fetches the JWKS without credentials, so without this the API server
# returns 403. The binding is idempotent.
grant_anonymous_oidc_discovery() {
  # Function arguments:
  #   $1: cluster name (management or development)
  local cluster=$1

  kubectl --context "$(kind_context "$cluster")" \
    create clusterrolebinding "$OIDC_DISCOVERY_CRB" \
    --clusterrole="$OIDC_DISCOVERY_CLUSTERROLE" \
    --group=system:unauthenticated \
    --dry-run=client -o yaml \
    | kubectl --context "$(kind_context "$cluster")" apply -f - >/dev/null
}


# Copy the shared cluster CA into the openbao pod under a stable filename so
# OpenBao trusts the API servers' TLS certs when fetching the JWKS.
# Echoes the in-pod path of the copied CA file.
copy_cluster_ca() {
  # Function arguments:
  #   $1: filename suffix (unique per backend, avoids clobbering)
  local suffix=$1

  kubectl --context "$(kind_context management)" \
    -n "$OPENBAO_NAMESPACE" \
    exec -i openbao-0 -- sh -c "cat > /tmp/api-ca-${suffix}.crt" < "$CLUSTER_CA_DIR/ca.crt"

  echo "/tmp/api-ca-${suffix}.crt"
}


# -----------------------------------------------------------------------------
# Configure the platform JWT auth backend for a cluster (root namespace).
#
# Platform-component ESO SecretStores (management + development clusters) read
# their secrets from the root `kv` mount, so their JWT auth backends live at the
# root namespace too. One backend per cluster (jwt-management / jwt-development).
# Only the roles needed before Crossplane is running are created here.
# -----------------------------------------------------------------------------
configure_platform_cluster_jwt() {
  # Function arguments:
  #   $1: cluster name (management or development)
  local cluster=$1
  local auth_path="jwt-${cluster}"
  local jwks_url ca_path
  jwks_url="$(sa_issuer "$cluster")/openid/v1/jwks"

  log "Configuring platform JWT auth for $cluster (path: $auth_path, JWKS: $jwks_url)..."

  grant_anonymous_oidc_discovery "$cluster"
  ca_path="$(copy_cluster_ca "platform-${cluster}")"

  bao_exec "bao auth enable -path=${auth_path} jwt 2>/dev/null || true"

  log "Configuring $auth_path backend..."
  local ok=false
  for i in $(seq 1 20); do
    if bao_exec "bao write auth/${auth_path}/config \
        jwks_url='${jwks_url}' \
        jwks_ca_pem=@${ca_path} \
        bound_issuer='$(sa_issuer "$cluster")'" >/dev/null 2>&1; then
      ok=true
      break
    fi
    sleep 3
  done
  if [ "$ok" != "true" ]; then
    err "Failed to configure $auth_path — API server not reachable at $jwks_url"
    exit 1
  fi

  bao_exec "bao write auth/${auth_path}/role/shared \
    role_type=jwt \
    bound_audiences='https://kubernetes.default.svc.cluster.local' \
    user_claim=sub \
    bound_subject='system:serviceaccount:platform-system:external-secrets' \
    policies=shared-policy \
    ttl=1h"

  bao_exec "bao write auth/${auth_path}/role/platform-system \
    role_type=jwt \
    bound_audiences='https://kubernetes.default.svc.cluster.local' \
    user_claim=sub \
    bound_subject='system:serviceaccount:platform-system:external-secrets' \
    policies=platform-system-policy \
    ttl=1h"

  bao_exec "bao write auth/${auth_path}/role/crossplane \
    role_type=jwt \
    bound_audiences='https://kubernetes.default.svc.cluster.local' \
    user_claim=sub \
    bound_subject='system:serviceaccount:crossplane-system:crossplane' \
    policies=crossplane-policy \
    ttl=1h"

  bao_exec "bao write auth/${auth_path}/role/argocd \
    role_type=jwt \
    bound_audiences='https://kubernetes.default.svc.cluster.local' \
    user_claim=sub \
    bound_subject='system:serviceaccount:argocd:argocd-server' \
    policies=argocd-policy \
    ttl=1h"

  bao_exec "rm -f ${ca_path}"

  ok "Platform JWT auth configured for $cluster"
}


# -----------------------------------------------------------------------------
# Configure the ROOT admin auth for crossplane provider-vault.
#
# provider-vault runs on the management cluster with a vault-agent sidecar that
# logs in with the provider-vault ServiceAccount JWT. It authenticates at the
# ROOT namespace (it needs sys/namespaces + cross-namespace mount/policy access)
# and receives the openbao-admin-policy written by the chart postStart hook.
# -----------------------------------------------------------------------------
configure_provider_admin_auth() {
  local cluster="management"
  local auth_path="jwt-management"
  local jwks_url ca_path
  jwks_url="$(sa_issuer "$cluster")/openid/v1/jwks"

  log "Configuring ROOT provider-vault admin auth (path: $auth_path, JWKS: $jwks_url)..."

  grant_anonymous_oidc_discovery "$cluster"
  ca_path="$(copy_cluster_ca "root-${auth_path}")"

  bao_exec "bao auth enable -path=${auth_path} jwt 2>/dev/null || true"

  local ok=false
  for i in $(seq 1 20); do
    if bao_exec "bao write auth/${auth_path}/config \
        jwks_url='${jwks_url}' \
        jwks_ca_pem=@${ca_path} \
        bound_issuer='$(sa_issuer "$cluster")'" >/dev/null 2>&1; then
      ok=true
      break
    fi
    sleep 3
  done
  if [ "$ok" != "true" ]; then
    err "Failed to configure root $auth_path — API server not reachable at $jwks_url"
    exit 1
  fi

  bao_exec "bao write auth/${auth_path}/role/provider-vault \
    role_type=jwt \
    bound_audiences='https://kubernetes.default.svc.cluster.local' \
    user_claim=sub \
    bound_subject='system:serviceaccount:crossplane-system:provider-vault' \
    policies=openbao-admin-policy \
    ttl=1h"

  bao_exec "rm -f ${ca_path}"

  ok "ROOT provider-vault admin auth configured"
}


# -----------------------------------------------------------------------------
# Configure the shared tenant JWT auth backend (root namespace).
#
# A single backend (jwt-development-tenants) validates tenant ServiceAccount
# tokens minted on the development cluster. The shared `tenant` role and the
# identity-templated tenant-policy are managed by Crossplane provider-vault
# (crossplane chart, vaultProvider.tenantAccessor); only the backend + JWKS
# config live here because they need cluster API access.
# -----------------------------------------------------------------------------
configure_tenant_jwt() {
  local cluster="development"
  local auth_path="jwt-development-tenants"
  local jwks_url ca_path
  jwks_url="$(sa_issuer "$cluster")/openid/v1/jwks"

  log "Configuring ROOT $auth_path backend (namespace-scoped user_claim)..."

  ca_path="$(copy_cluster_ca "root-${auth_path}")"

  bao_exec "bao auth enable -path=${auth_path} jwt 2>/dev/null || true"

  log "Configuring $auth_path JWKS (${jwks_url})..."
  local ok=false
  for i in $(seq 1 20); do
    if bao_exec "bao write auth/${auth_path}/config \
        jwks_url='${jwks_url}' \
        jwks_ca_pem=@${ca_path} \
        bound_issuer='$(sa_issuer "$cluster")'" >/dev/null 2>&1; then
      ok=true
      break
    fi
    sleep 3
  done
  if [ "$ok" != "true" ]; then
    err "Failed to configure $auth_path — API server not reachable at $jwks_url"
    exit 1
  fi

  # Accessor for this backend. tenant-policy and the `tenant` role are managed by
  # Crossplane provider-vault, which needs this accessor in its values.
  local accessor configured
  accessor=$(bao_exec "bao auth list -format=json" \
    | jq -r ".\"${auth_path}/\".accessor")

  configured=$(sed -n 's/^ *tenantAccessor: *"\(.*\)".*/\1/p' \
    "$CHARTS_DIR/crossplane/values-local-management.yaml")

  if [ "$configured" != "$accessor" ]; then
    warn "vaultProvider.tenantAccessor in crossplane/values-local-management.yaml is '${configured}' but ${auth_path} has '${accessor}'."
    warn "Update it and commit, or tenants cannot read their secrets."
  fi

  bao_exec "rm -f ${ca_path}"

  ok "$auth_path configured (accessor: $accessor)"
}


# -----------------------------------------------------------------------------
# Enable + configure the central OIDC auth method for HUMAN tenant operators.
#
# One OIDC method at the root namespace (one Entra ID app registration + redirect
# URI). A human logs in once; their Entra `roles` claim (== tenant name) maps
# them to a per-tenant external Identity Group whose policy grants access to that
# tenant's path prefix (kv-development/data/<tenant>/*). The per-tenant
# Group/GroupAlias + policy are provisioned by the tenant-management chart; here
# we only stand up the method and a single `default` role.
# -----------------------------------------------------------------------------
configure_oidc() {
  log "Configuring OpenBao OIDC auth (Entra ID) for human tenant operators..."

  local client_id tenant_id client_secret
  client_id=$(pass show private/azure/entraid/apps/openbao/client-id | head -n1)
  tenant_id=$(pass show private/azure/entraid/apps/tenant-id | head -n1)
  client_secret=$(pass show private/azure/entraid/apps/openbao/client-secrets/vault/value | head -n1)

  if [ -z "$client_id" ] || [ -z "$tenant_id" ] || [ -z "$client_secret" ]; then
    err "Missing OpenBao Entra ID credentials in pass (vault client-id / tenant-id / client-secret)"
    exit 1
  fi

  local discovery_url="https://login.microsoftonline.com/${tenant_id}/v2.0"

  bao_exec "bao auth enable -path=oidc oidc 2>/dev/null || true"

  # NOTE: the redirect URI host is the OpenBao UI hostname. The OpenBao UI keeps
  # the /ui/vault/... callback path for Vault compatibility. If a future OpenBao
  # release changes this path, update the Entra app redirect URI to match.
  log "Writing auth/oidc/config (discovery: $discovery_url)..."
  printf '%s' "$client_secret" | \
    kubectl --context "$(kind_context management)" \
      -n "$OPENBAO_NAMESPACE" \
      exec -i openbao-0 -- sh -c "
        export BAO_ADDR=http://127.0.0.1:8200
        export BAO_TOKEN=\$(grep 'Initial Root Token:' /openbao/data/init.txt | awk '{print \$4}')
        secret=\$(cat)
        bao write auth/oidc/config \
          oidc_discovery_url='${discovery_url}' \
          oidc_client_id='${client_id}' \
          oidc_client_secret=\"\$secret\" \
          default_role=default
      "

  bao_exec "bao write auth/oidc/role/default \
    role_type=oidc \
    user_claim=sub \
    groups_claim=roles \
    oidc_scopes='openid,profile,email' \
    token_policies=default \
    token_ttl=1h \
    allowed_redirect_uris='https://openbao.mgmt.rezakara.demo/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback'"

  local accessor
  accessor=$(bao_exec "bao auth list -format=json" | jq -r '."oidc/".accessor')

  save_oidc_accessor "$accessor"

  # Human OpenBao roles map from the Entra `roles` claim (values 'admin' and
  # 'viewer', from the OpenBao app's admin/viewer app roles) to external Identity
  # Groups. Unlike tenants, these are platform-level, so their policy + group +
  # alias live here rather than in the tenant-management chart. The GROUP-ALIAS
  # name MUST equal the roles claim value; policy/group names are descriptive.
  log "Writing platform-admin + platform-viewer policies and identity groups..."

  bao_exec "bao policy write platform-admin - <<EOF
path \"auth/*\"                 { capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\", \"sudo\"] }
path \"sys/auth\"               { capabilities = [\"read\"] }
path \"sys/auth/*\"             { capabilities = [\"create\", \"read\", \"update\", \"delete\", \"sudo\"] }
path \"sys/policies/acl\"       { capabilities = [\"list\"] }
path \"sys/policies/acl/*\"     { capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\"] }
path \"sys/mounts\"             { capabilities = [\"read\"] }
path \"sys/mounts/*\"           { capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\", \"sudo\"] }
path \"sys/remount\"            { capabilities = [\"create\", \"update\"] }
path \"sys/leases/*\"           { capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\", \"sudo\"] }
path \"sys/health\"             { capabilities = [\"read\", \"sudo\"] }
path \"sys/capabilities\"       { capabilities = [\"create\", \"update\"] }
path \"sys/capabilities-self\"  { capabilities = [\"create\", \"update\"] }
path \"sys/tools/*\"            { capabilities = [\"update\"] }
path \"sys/internal/ui/*\"      { capabilities = [\"read\", \"list\"] }
path \"identity/*\"             { capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\"] }
path \"kv/*\"                   { capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\"] }
path \"kv-management/*\"        { capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\"] }
path \"kv-development/*\"       { capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\"] }
EOF"

  bao_exec "bao policy write platform-viewer - <<EOF
path \"sys/mounts\"             { capabilities = [\"read\"] }
path \"sys/mounts/*\"           { capabilities = [\"read\", \"list\"] }
path \"sys/auth\"               { capabilities = [\"read\"] }
path \"sys/auth/*\"             { capabilities = [\"read\", \"list\"] }
path \"sys/policies/acl\"       { capabilities = [\"list\"] }
path \"sys/policies/acl/*\"     { capabilities = [\"read\", \"list\"] }
path \"sys/capabilities-self\"  { capabilities = [\"create\", \"update\"] }
path \"sys/internal/ui/*\"      { capabilities = [\"read\", \"list\"] }
path \"identity/*\"             { capabilities = [\"read\", \"list\"] }
path \"kv/*\"                   { capabilities = [\"read\", \"list\"] }
path \"kv-management/*\"        { capabilities = [\"read\", \"list\"] }
path \"kv-development/*\"       { capabilities = [\"read\", \"list\"] }
EOF"

  # External groups + aliases. Alias name == roles claim value ('admin'/'viewer').
  # Aliases created once; re-runs detect the existing one via the group's alias.
  bao_exec "
    bao write identity/group/name/platform-admin type=external policies=platform-admin >/dev/null
    gid=\$(bao read -field=id identity/group/name/platform-admin)
    if bao read identity/group/name/platform-admin 2>/dev/null | grep -q mount_accessor; then
      echo 'admin group-alias already present'
    else
      bao write identity/group-alias name=admin mount_accessor=${accessor} canonical_id=\$gid >/dev/null
      echo 'created admin group-alias'
    fi
    bao write identity/group/name/platform-viewer type=external policies=platform-viewer >/dev/null
    vid=\$(bao read -field=id identity/group/name/platform-viewer)
    if bao read identity/group/name/platform-viewer 2>/dev/null | grep -q mount_accessor; then
      echo 'viewer group-alias already present'
    else
      bao write identity/group-alias name=viewer mount_accessor=${accessor} canonical_id=\$vid >/dev/null
      echo 'created viewer group-alias'
    fi
  "

  ok "OpenBao OIDC auth configured (accessor: $accessor); admin + viewer groups ready"
}


# Wait for the OpenBao postStart bootstrap to complete (tenant KV mounts).
# postStart runs init/unseal, enables the kv / kv-management / kv-development
# engines, and writes the ACL policies. Everything below depends on that.
wait_for_openbao_bootstrap() {
  log "Waiting for OpenBao postStart bootstrap to complete (KV mount 'kv-development')..."
  for i in $(seq 1 60); do
    if bao_exec "bao secrets list" 2>/dev/null | grep -q '^kv-development/'; then
      ok "OpenBao bootstrap complete"
      return 0
    fi
    sleep 3
  done
  err "OpenBao bootstrap did not complete within 3 minutes"
  exit 1
}


# Save the initial OpenBao root token to the local credentials file.
save_credentials() {
  local bao_token
  bao_token="$(kubectl --context "$(kind_context management)" \
    -n "$OPENBAO_NAMESPACE" \
    exec openbao-0 -- \
    sh -c "grep 'Initial Root Token:' /openbao/data/init.txt | awk '{print \$4}'")"

  local creds_file="$REPO_ROOT/.platform.env"

  if grep -q 'OPENBAO_ROOT_TOKEN' "$creds_file" 2>/dev/null; then
    sed -i "s|^export OPENBAO_ROOT_TOKEN=.*|export OPENBAO_ROOT_TOKEN=\"${bao_token}\"|" "$creds_file"
  else
    echo "export OPENBAO_ROOT_TOKEN=\"${bao_token}\"" >> "$creds_file"
  fi

  chmod 600 "$creds_file"
  ok "OPENBAO_ROOT_TOKEN saved to $creds_file"
}


# Persist the OIDC mount accessor so the tenant-management chart can reference it
# for the per-tenant Identity GroupAlias mount_accessor.
save_oidc_accessor() {
  # Function arguments:
  #   $1: OIDC mount accessor
  local accessor="$1"
  local creds_file="$REPO_ROOT/.platform.env"

  if grep -q 'OPENBAO_OIDC_ACCESSOR' "$creds_file" 2>/dev/null; then
    sed -i "s|^export OPENBAO_OIDC_ACCESSOR=.*|export OPENBAO_OIDC_ACCESSOR=\"${accessor}\"|" "$creds_file"
  else
    echo "export OPENBAO_OIDC_ACCESSOR=\"${accessor}\"" >> "$creds_file"
  fi

  chmod 600 "$creds_file"
  ok "OPENBAO_OIDC_ACCESSOR saved to $creds_file"
}


main() {
  log "Waiting for OpenBao pod to be ready..."
  kubectl --context "$(kind_context management)" \
    -n "$OPENBAO_NAMESPACE" \
    wait pod openbao-0 \
    --for=condition=Ready \
    --timeout=120s

  wait_for_openbao_bootstrap

  # Platform-namespace JWT backends: management first, then each tenant cluster.
  configure_platform_cluster_jwt management
  echo "--------------------------------"

  get_kind_tenant_clusters | while read -r cluster; do
    configure_platform_cluster_jwt "$cluster"
    echo "--------------------------------"
  done

  # Root admin auth for crossplane provider-vault.
  configure_provider_admin_auth
  echo "--------------------------------"

  # Shared tenant JWT backend (root). The `tenant` role + tenant-policy come from Crossplane.
  configure_tenant_jwt
  echo "--------------------------------"

  # Central human OIDC method (root).
  configure_oidc
  echo "--------------------------------"

  save_credentials

  echo ""
  ok "OpenBao JWT/OIDC auth configured"
}

main "$@"
