#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------
# Input
# ----------------------------------------
TF_DIR="${1:-.}"
BASE="private/azure/entra-id/apps"

echo "→ Reading Terraform outputs from: $TF_DIR"

OUTPUTS=$(tofu -chdir="$TF_DIR" output -json)

# ----------------------------------------
# Helper
# ----------------------------------------
store() {
  local app=$1
  local tf_key=$2
  local pass_path=$3

  new_value=$(echo "$OUTPUTS" | jq -r ".${tf_key}.value // empty")

  # Check if the value is empty or null
  if [[ -z "$new_value" || "$new_value" == "null" ]]; then
    echo "⚠️  Skipping ${app}/${tf_key} (empty)"
    return
  fi

  full_path="${BASE}/${app}/${pass_path}"

  # Try to read existing value
  if pass show "$full_path" >/dev/null 2>&1; then
    current_value=$(pass show "$full_path")

    if [[ "$current_value" == "$new_value" ]]; then
      echo "✔ No change for ${app}/${tf_key}"
      return
    fi
  fi

  echo "→ Updating ${app}/${tf_key}"
  echo "$new_value" | pass insert -m -f "$full_path"
}

# -------------------------------
# Argo CD
# -------------------------------
store argocd argocd_client_id "client-id"
store argocd argocd_client_secret "client-secrets/argocd/value"
store argocd argocd_client_secret_id "client-secrets/argocd/secret-id"
store argocd tenant_id "tenant-id"

# -------------------------------
# Crossplane
# -------------------------------
store crossplane crossplane_client_id "client-id"
store crossplane crossplane_client_secret "client-secrets/crossplane/value"
store crossplane crossplane_client_secret_id "client-secrets/crossplane/secret-id"
store crossplane tenant_id "tenant-id"

# -------------------------------
# Keycloak
# -------------------------------
store keycloak keycloak_client_id "client-id"
store keycloak keycloak_client_secret "client-secrets/keycloak/value"
store keycloak keycloak_client_secret_id "client-secrets/keycloak/secret-id"
store keycloak tenant_id "tenant-id"

echo "✅ Secrets stored in pass"
