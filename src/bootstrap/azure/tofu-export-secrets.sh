#!/usr/bin/env bash
set -euo pipefail

DIR="."
BASE="private/azure/entra-id/apps"

echo "→ Reading Terraform outputs..."
OUTPUTS=$(tofu -chdir="$DIR" output -json)

store() {
  local app=$1
  local tf_key=$2
  local pass_path=$3

  value=$(echo "$OUTPUTS" | jq -r ".${tf_key}.value // empty")

  if [[ -z "$value" ]]; then
    echo "⚠️  Skipping ${app}/${tf_key} (empty)"
    return
  fi

  echo "→ Storing ${app}/${tf_key}"
  echo "$value" | pass insert -m -f "${BASE}/${app}/${pass_path}"
}

# -------------------------------
# Argo CD
# -------------------------------
store argocd argocd_client_id "client-id"
store argocd argocd_client_secret "client-secrets/argocd/value"
store argocd argocd_client_secret_id "client-secrets/argocd/secret-id"
store argocd argocd_tenant_id "tenant-id"

# -------------------------------
# Crossplane
# -------------------------------
store crossplane crossplane_client_id "client-id"
store crossplane crossplane_client_secret "client-secrets/crossplane/value"
store crossplane crossplane_client_secret_id "client-secrets/crossplane/secret-id"
store crossplane crossplane_tenant_id "tenant-id"

# -------------------------------
# Keycloak
# -------------------------------
store keycloak keycloak_client_id "client-id"
store keycloak keycloak_client_secret "client-secrets/keycloak/value"
store keycloak keycloak_client_secret_id "client-secrets/keycloak/secret-id"
store keycloak keycloak_tenant_id "tenant-id"

echo "✅ Secrets stored in pass"
