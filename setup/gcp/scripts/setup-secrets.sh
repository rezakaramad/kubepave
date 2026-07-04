#!/usr/bin/env bash
set -euo pipefail

# Copies secrets from the local 'pass' password store to Google Cloud Secret Manager.
# Requires: pass, gcloud (authenticated)
#
# Usage:
#   ./setup-secrets.sh

GCP_PROJECT="kara-mgmt"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# Create or update a secret in Cloud Secret Manager.
# If the secret doesn't exist it is created first, then a new version is added.
# Usage: put_secret <secret-name> <value>
put_secret() {
  local name="$1"
  local value="$2"

  if ! gcloud secrets describe "$name" --project="$GCP_PROJECT" &>/dev/null; then
    echo "  📦 Creating secret '$name'..."
    gcloud secrets create "$name" \
      --project="$GCP_PROJECT" \
      --replication-policy="automatic"
  fi

  echo "  🔑 Writing secret version for '$name'..."
  printf '%s' "$value" | gcloud secrets versions add "$name" \
    --project="$GCP_PROJECT" \
    --data-file=-

  echo "  ✅ '$name' stored in Cloud Secret Manager"
}

# ----------------------------------------------------------------------------
# GitHub App secret for Argo CD
# Two separate GitHub Apps are used:
# - rezakaramad: for deploying from repos in the personal 'rezakaramad' GitHub account (e.g. kubepave)
# - fluxdojo: for deploying from repos in the 'fluxdojo' GitHub organization (ApplicationSets for tenant clusters)
# ----------------------------------------------------------------------------
create_github_app_secret_argocd() {
  echo "🔐 Writing Argo CD GitHub App secrets to Cloud Secret Manager..."

  # Access to https://github.com/rezakaramad
  echo "📖 Reading 'rezakaramad-argocd' credentials from pass..."
  local app_id installation_id private_key
  app_id=$(pass show private/github/apps/rezakaramad-argocd/app-id | head -n1)
  installation_id=$(pass show private/github/apps/rezakaramad-argocd/installation-id | head -n1)
  private_key=$(pass show private/github/apps/rezakaramad-argocd/private-key)

  put_secret "argocd-github-rezakaramad-app-id"          "$app_id"
  put_secret "argocd-github-rezakaramad-installation-id" "$installation_id"
  put_secret "argocd-github-rezakaramad-private-key"     "$private_key"

  echo "✅ Argo CD GitHub App secrets for 'rezakaramad' written"

  # Access to https://github.com/fluxdojo
  echo "📖 Reading 'fluxdojo-argocd' credentials from pass..."
  app_id=$(pass show private/github/apps/fluxdojo-argocd/app-id | head -n1)
  installation_id=$(pass show private/github/apps/fluxdojo-argocd/installation-id | head -n1)
  private_key=$(pass show private/github/apps/fluxdojo-argocd/private-key)

  put_secret "argocd-github-fluxdojo-app-id"          "$app_id"
  put_secret "argocd-github-fluxdojo-installation-id" "$installation_id"
  put_secret "argocd-github-fluxdojo-private-key"     "$private_key"

  echo "✅ Argo CD GitHub App secrets for 'fluxdojo' written"
}

# ----------------------------------------------------------------------------
# Argo CD Entra ID (Azure AD) App registration secret
# Used by Argo CD for OIDC SSO authentication via Azure AD.
# ----------------------------------------------------------------------------
create_argocd_app_registration_azure() {
  echo "🔐 Writing Argo CD Entra ID App secrets to Cloud Secret Manager..."

  local client_id tenant_id client_secret
  client_id=$(pass show private/azure/entraid/apps/argocd/client-id | head -n1)
  tenant_id=$(pass show private/azure/entraid/apps/tenant-id | head -n1)
  client_secret=$(pass show private/azure/entraid/apps/argocd/client-secrets/argocd/value | head -n1)

  if [[ -z "$client_secret" ]]; then
    echo "❌ Failed to read Argo CD client secret from pass."
    return 1
  fi

  put_secret "argocd-azure-client-id"     "$client_id"
  put_secret "argocd-azure-tenant-id"     "$tenant_id"
  put_secret "argocd-azure-client-secret" "$client_secret"

  echo "✅ Argo CD Entra ID secrets written"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  echo "🚀 Setting up secrets in Cloud Secret Manager (project: $GCP_PROJECT)..."
  echo ""

  create_github_app_secret_argocd
  echo ""
  create_argocd_app_registration_azure

  echo ""
  echo "🎉 All secrets written to Cloud Secret Manager"
}

main "$@"
