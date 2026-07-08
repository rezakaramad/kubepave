#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------
# Input
# ----------------------------------------
TF_DIR="${1:-.}"
BASE="private/azure/entraid/apps"

echo "→ Reading Terraform outputs from: $TF_DIR"

OUTPUTS=$(tofu -chdir="$TF_DIR" output -json)

# ----------------------------------------
# Helper
# ----------------------------------------
store() {
  local path=$1
  local tf_key=$2

  new_value=$(echo "$OUTPUTS" | jq -r ".${tf_key}.value // empty")

  if [[ -z "$new_value" || "$new_value" == "null" ]]; then
    echo "⚠️  Skipping ${tf_key} (empty)"
    return
  fi

  full_path="${BASE}/${path}"

  if pass show "$full_path" >/dev/null 2>&1; then
    current_value=$(pass show "$full_path")

    if [[ "$current_value" == "$new_value" ]]; then
      echo "✔ No change for ${path}"
      return
    fi
  fi

  echo "→ Updating ${path}"
  echo "$new_value" | pass insert -m -f "$full_path"
}

# ----------------------------------------
# Global (shared)
# ----------------------------------------
store "tenant-id" "tenant_id"

# -------------------------------
# Argo CD
# -------------------------------
store "argocd/client-id" "argocd_client_id"
store "argocd/client-secrets/argocd/value" "argocd_client_secret_value"
store "argocd/client-secrets/argocd/id" "argocd_client_secret_id"

# -------------------------------
# Crossplane
# -------------------------------
store "crossplane/client-id" "crossplane_client_id"
store "crossplane/client-secrets/crossplane/value" "crossplane_client_secret_value"
store "crossplane/client-secrets/crossplane/id" "crossplane_client_secret_id"

# -------------------------------
# Keycloak
# -------------------------------
store "keycloak/client-id" "keycloak_client_id"
store "keycloak/client-secrets/keycloak/value" "keycloak_client_secret_value"
store "keycloak/client-secrets/keycloak/id" "keycloak_client_secret_id"

echo "✅ Secrets stored in pass"
