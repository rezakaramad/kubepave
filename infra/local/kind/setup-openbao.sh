#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# setup-openbao.sh
# Configures OpenBao JWT/OIDC auth for the namespaced topology (Pattern X).
#
# Namespaced topology:
# Namespaces isolate DATA; auth + policy stay centrally owned by the platform team, never self-administered by tenants):
#
#   root      — admin plane. Holds the crossplane provider-vault admin auth
#               (jwt-management/provider-vault → openbao-admin-policy), the shared
#               tenant JWT backend (jwt-development-tenants) + the identity-
#               templated tenant-policy, and the central human OIDC method.
#   platform  — all platform-component secrets under KV `kv`. Holds the
#               jwt-management + jwt-development backends with the ESO roles.
#   tenants   — parent namespace; each tenant becomes a child namespace
#               `tenants/<tenant>` created by crossplane provider-vault. Tenant
#               secrets live in `tenants/<tenant>/kv`. There is NO per-tenant auth
#               backend: tenant ESO authenticates against the shared root
#               jwt-development-tenants backend (auth.namespace="") and uses the
#               resulting token against its own namespace (data namespace),
#               which ESO supports natively.
#
# Like setup-vault.sh, OpenBao validates pod JWTs by fetching each cluster's
# public signing keys (JWKS) DIRECTLY from that cluster's API server
# (https://<node-ip>:6443/openid/v1/jwks). The namespace + KV bootstrap
# (init/unseal/namespaces/policies) is done by the chart postStart hook; this
# script only adds the parts that need cluster API access (JWKS) plus OIDC.
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


# Returns the API server URL reachable from the OpenBao pod for a given cluster.
# Uses the node's InternalIP:6443 — reachable across the shared kind Docker
# network, exactly like the ArgoCD hub→spoke connection.
cluster_api_url() {
  # Function arguments:
  #   $1: cluster name (management or development)
  local cluster=$1
  local node_ip
  node_ip=$(kubectl --context "$(kind_context "$cluster")" get node \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

  echo "https://${node_ip}:6443"
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


# Copy a cluster's API server CA into the openbao pod under a stable filename so
# OpenBao trusts the API server's TLS cert when fetching the JWKS.
# Echoes the in-pod path of the copied CA file.
copy_cluster_ca() {
  # Function arguments:
  #   $1: cluster name
  #   $2: filename suffix (unique per backend, avoids clobbering)
  local cluster=$1
  local suffix=$2
  local api_ca
  api_ca=$(kubectl --context "$(kind_context "$cluster")" \
    config view --raw --minify \
    -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)

  kubectl --context "$(kind_context management)" \
    -n "$OPENBAO_NAMESPACE" \
    exec -i openbao-0 -- sh -c "cat > /tmp/api-ca-${suffix}.crt" <<< "$api_ca"

  echo "/tmp/api-ca-${suffix}.crt"
}


# -----------------------------------------------------------------------------
# Configure the platform-namespace JWT auth backend for a cluster.
#
# Platform-component ESO SecretStores (management + development clusters) read
# their secrets from the `platform` namespace, so their JWT auth backends live
# there too. One backend per cluster (jwt-management / jwt-development), mounted
# inside the platform namespace.
# -----------------------------------------------------------------------------
configure_platform_cluster_jwt() {
  # Function arguments:
  #   $1: cluster name (management or development)
  local cluster=$1
  local auth_path="jwt-${cluster}"
  local api_url jwks_url ca_path
  api_url="$(cluster_api_url "$cluster")"
  jwks_url="${api_url}/openid/v1/jwks"

  log "Configuring platform JWT auth for $cluster (path: platform/$auth_path, JWKS: $jwks_url)..."

  grant_anonymous_oidc_discovery "$cluster"
  ca_path="$(copy_cluster_ca "$cluster" "platform-${cluster}")"

  bao_exec "bao auth enable -namespace=platform -path=${auth_path} jwt 2>/dev/null || true"

  log "Configuring platform/$auth_path backend..."
  local ok=false
  for i in $(seq 1 20); do
    if bao_exec "bao write -namespace=platform auth/${auth_path}/config \
        jwks_url='${jwks_url}' \
        jwks_ca_pem=@${ca_path} \
        bound_issuer='https://kubernetes.default.svc.cluster.local'" >/dev/null 2>&1; then
      ok=true
      break
    fi
    sleep 3
  done
  if [ "$ok" != "true" ]; then
    err "Failed to configure platform/$auth_path — API server not reachable at $jwks_url"
    exit 1
  fi

  bao_exec "bao write -namespace=platform auth/${auth_path}/role/eso-shared \
    role_type=jwt \
    bound_audiences='https://kubernetes.default.svc.cluster.local' \
    user_claim=sub \
    bound_subject='system:serviceaccount:platform-system:external-secrets' \
    policies=eso-shared-policy \
    ttl=1h"

  bao_exec "bao write -namespace=platform auth/${auth_path}/role/eso-platform-system \
    role_type=jwt \
    bound_audiences='https://kubernetes.default.svc.cluster.local' \
    user_claim=sub \
    bound_subject='system:serviceaccount:platform-system:external-secrets' \
    policies=eso-platform-system-policy \
    ttl=1h"

  bao_exec "bao write -namespace=platform auth/${auth_path}/role/crossplane \
    role_type=jwt \
    bound_audiences='https://kubernetes.default.svc.cluster.local' \
    user_claim=sub \
    bound_subject='system:serviceaccount:crossplane-system:crossplane' \
    policies=crossplane-policy \
    ttl=1h"

  bao_exec "bao write -namespace=platform auth/${auth_path}/role/eso-argocd \
    role_type=jwt \
    bound_audiences='https://kubernetes.default.svc.cluster.local' \
    user_claim=sub \
    bound_subject='system:serviceaccount:argocd:argocd-server' \
    policies=eso-argocd-policy \
    ttl=1h"

  # keycloak and backstage only run on the management cluster.
  if [ "$cluster" = "management" ]; then
    bao_exec "bao write -namespace=platform auth/${auth_path}/role/keycloak \
      role_type=jwt \
      bound_audiences='https://kubernetes.default.svc.cluster.local' \
      user_claim=sub \
      bound_subject='system:serviceaccount:keycloak:keycloak' \
      policies=keycloak-policy \
      ttl=1h"

    bao_exec "bao write -namespace=platform auth/${auth_path}/role/backstage \
      role_type=jwt \
      bound_audiences='https://kubernetes.default.svc.cluster.local' \
      user_claim=sub \
      bound_subject='system:serviceaccount:backstage:backstage' \
      policies=backstage-policy \
      ttl=1h"
  fi

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
  local api_url jwks_url ca_path
  api_url="$(cluster_api_url "$cluster")"
  jwks_url="${api_url}/openid/v1/jwks"

  log "Configuring ROOT provider-vault admin auth (path: $auth_path, JWKS: $jwks_url)..."

  grant_anonymous_oidc_discovery "$cluster"
  ca_path="$(copy_cluster_ca "$cluster" "root-${auth_path}")"

  bao_exec "bao auth enable -path=${auth_path} jwt 2>/dev/null || true"

  local ok=false
  for i in $(seq 1 20); do
    if bao_exec "bao write auth/${auth_path}/config \
        jwks_url='${jwks_url}' \
        jwks_ca_pem=@${ca_path} \
        bound_issuer='https://kubernetes.default.svc.cluster.local'" >/dev/null 2>&1; then
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
# Configure the shared tenant JWT auth backend + tenant-policy (ROOT namespace).
#
# A single backend (jwt-development-tenants) at the root namespace validates
# tenant ServiceAccount tokens minted on the development cluster. There is one
# per-tenant role (added later by crossplane provider-vault) that attaches the
# shared, identity-templated tenant-policy.
#
# user_claim is the namespace JSON pointer so the entity alias == the tenant's
# namespace name (== tenant name). tenant-policy then expands
# {{identity.entity.aliases[<accessor>].name}} to that name, scoping the tenant
# to its own child namespace's KV mount: tenants/<tenant>/kv/*. Tenant ESO
# authenticates here (auth.namespace="") and uses the token against its data
# namespace tenants/<tenant>.
# -----------------------------------------------------------------------------
configure_tenant_jwt() {
  local cluster="development"
  local auth_path="jwt-development-tenants"
  local api_url jwks_url ca_path
  api_url="$(cluster_api_url "$cluster")"
  jwks_url="${api_url}/openid/v1/jwks"

  log "Configuring ROOT $auth_path backend (namespace-scoped user_claim)..."

  ca_path="$(copy_cluster_ca "$cluster" "root-${auth_path}")"

  bao_exec "bao auth enable -path=${auth_path} jwt 2>/dev/null || true"

  log "Configuring $auth_path JWKS (${jwks_url})..."
  local ok=false
  for i in $(seq 1 20); do
    if bao_exec "bao write auth/${auth_path}/config \
        jwks_url='${jwks_url}' \
        jwks_ca_pem=@${ca_path} \
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

  # Accessor for this backend, embedded in the identity-templated policy.
  local accessor
  accessor=$(bao_exec "bao auth list -format=json" \
    | jq -r ".\"${auth_path}/\".accessor")

  log "Writing tenant-policy (accessor: $accessor)..."

  # Paths reach into each tenant's child namespace KV mount. A token minted for
  # tenant <t> can only ever resolve the template to its own namespace, so it
  # can access tenants/<t>/kv/* and nothing else.
  bao_exec "bao policy write tenant-policy - <<EOF
path \"tenants/{{identity.entity.aliases[${accessor}].name}}/kv/data/*\" {
  capabilities = [\"read\", \"list\", \"create\", \"update\", \"delete\"]
}

path \"tenants/{{identity.entity.aliases[${accessor}].name}}/kv/metadata/*\" {
  capabilities = [\"read\", \"list\", \"delete\"]
}
EOF"

  bao_exec "rm -f ${ca_path}"

  ok "$auth_path configured and tenant-policy written"
}


# -----------------------------------------------------------------------------
# Enable + configure the central OIDC auth method for HUMAN tenant operators.
#
# One OIDC method at the ROOT namespace (one Entra ID app registration + redirect
# URI). A human logs in once; their Entra `roles` claim (== tenant name) maps
# them to a per-tenant external Identity Group whose policy grants access into
# that tenant's child namespace. The per-tenant Group/GroupAlias + policy are
# provisioned by the tenant-management chart; here we only stand up the method
# and a single `default` role.
# -----------------------------------------------------------------------------
configure_oidc() {
  log "Configuring OpenBao OIDC auth (Entra ID) for human tenant operators..."

  local client_id tenant_id client_secret
  client_id=$(pass show private/azure/entraid/apps/vault/client-id | head -n1)
  tenant_id=$(pass show private/azure/entraid/apps/tenant-id | head -n1)
  client_secret=$(pass show private/azure/entraid/apps/vault/client-secrets/vault/value | head -n1)

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

  ok "OpenBao OIDC auth configured (accessor: $accessor)"
}


# Wait for the OpenBao postStart bootstrap to complete (platform KV mount 'kv').
# postStart runs init/unseal, creates the namespaces + platform KV engine, and
# writes the ACL policies. Everything below depends on that being done.
wait_for_openbao_bootstrap() {
  log "Waiting for OpenBao postStart bootstrap to complete (platform KV mount 'kv')..."
  for i in $(seq 1 60); do
    if bao_exec "bao secrets list -namespace=platform" 2>/dev/null | grep -q '^kv/'; then
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

  # Shared tenant JWT backend + identity-templated tenant-policy (root).
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
