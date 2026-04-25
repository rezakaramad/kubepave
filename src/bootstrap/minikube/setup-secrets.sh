#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=libs/common.sh
source "$DIR/libs/common.sh"
# shellcheck source=libs/utils.sh
source "$DIR/libs/utils.sh"


# ----------------------------------------------------------------------------
# GitHub App secret for Argo CD
# Two separate GitHub Apps are used in the current setup:
# - One for 'rezakaramad' GitHub account to connect Argo CD to GitHub and deploy from repos in that account
#   - This is due to the fact that the platform repository 'kubepave' is in the 'rezakaramad' account and we want to deploy from it.
# - Another for 'fluxdojo' GitHub organization and deploy from repos in that org.
#   - This is where Argo CD ApplicationSets are defined to deploy tenant clusters, and we want to deploy from that repo as well.
# ----------------------------------------------------------------------------
create_github_app_secret_argocd() {
  echo "🔐 Writing Argo CD GitHub App secret..."

  # Access to https://github.com/rezakaramad
  echo "🔐 Copying 'rezakaramad-argocd' GitHub App credentials from 'pass' local password store..."
  APP_ID=$(pass show private/github/apps/rezakaramad-argocd/app-id | head -n1)
  INSTALLATION_ID=$(pass show private/github/apps/rezakaramad-argocd/installation-id | head -n1)
  PRIVATE_KEY=$(pass show private/github/apps/rezakaramad-argocd/private-key)

  echo "🔐 Storing 'rezakaramad-argocd' GitHub App credentials in Vault..."
  vault kv put local/management/github/apps/argocd/rezakaramad \
    app-id="$APP_ID" \
    installation-id="$INSTALLATION_ID" \
    private-key="$PRIVATE_KEY"

  echo "✅ Argo CD GitHub App secret for 'https://github.com/rezakaramad' written to Vault"

  # Access to https://github.com/fluxdojo
  echo "🔐 Copying 'fluxdojo-argocd' GitHub App credentials from 'pass' local password store..."
  APP_ID=$(pass show private/github/apps/fluxdojo-argocd/app-id | head -n1)
  INSTALLATION_ID=$(pass show private/github/apps/fluxdojo-argocd/installation-id | head -n1)
  PRIVATE_KEY=$(pass show private/github/apps/fluxdojo-argocd/private-key)

  echo "🔐 Storing 'fluxdojo-argocd' GitHub App credentials in Vault..."
  vault kv put local/management/github/apps/argocd/fluxdojo \
    app-id="$APP_ID" \
    installation-id="$INSTALLATION_ID" \
    private-key="$PRIVATE_KEY"

  echo "✅ Argo CD GitHub App secret for 'https://github.com/fluxdojo' written to Vault"

  echo "🎉 All Argo CD GitHub App secrets successfully stored in Vault so Argo CD can access GitHub repositories securely."
}


# ----------------------------------------------------------------------------
# Argo CD cluster credentials
# ----------------------------------------------------------------------------
register_clusters_argocd() {
  echo "🔐 Writing Argo CD clusters credentials..."

  get_minikube_tenant_profiles | while IFS= read -r profile; do
    IP=$(minikube ip -p "$profile")
    SERVER="https://${IP}:8443"

    echo "🚀 Registering cluster $profile → $SERVER"

    # Create ServiceAccount for Argo CD cluster access
    kubectl --context "$profile" create serviceaccount argocd-manager -n kube-system 2>/dev/null || true

    # Grant cluster-admin privileges to the ServiceAccount
    kubectl --context "$profile" create clusterrolebinding argocd-manager \
      --clusterrole=cluster-admin \
      --serviceaccount=kube-system:argocd-manager 2>/dev/null || true

    # The command below creates a short-lived ServiceAccount token.
    # This becomes problematic because the token expires and must be
    # manually renewed and reconfigured in Argo CD.
    # TOKEN=$(kubectl --context "$profile" -n kube-system create token argocd-manager)

    # Create a legacy ServiceAccount token secret for a long-lived token
    kubectl --context "$profile" -n kube-system apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF

    # Wait until Kubernetes populates the token in the secret
    until kubectl --context "$profile" -n kube-system get secret argocd-manager-token \
      -o jsonpath='{.data.token}' 2>/dev/null | grep -q .; do
      sleep 1
    done

    # Read the legacy long-lived ServiceAccount token from the secret instead of using
    # TokenRequest-generated tokens. This prevents expiration issues with Argo CD in
    # this local environment. Static SA tokens are not recommended for production use.
    TOKEN=$(kubectl --context "$profile" -n kube-system get secret argocd-manager-token \
      -o jsonpath='{.data.token}' | base64 -d)

    echo "🔑 Storing credentials for $profile in Vault"
    vault kv put local/management/argocd/clusters/"$profile" \
      server="$SERVER" \
      token="$TOKEN"

    echo "✅ Credentials for $profile written to Vault"

  done

  echo "🎉 All Argo CD cluster credentials stored in Vault"
}


# ----------------------------------------------------------------------------
# Argo CD App registration credential in Azure
# ----------------------------------------------------------------------------
create_argocd_app_registration_azure() {
  echo "🔐 Writing Argo CD Entra ID App secret..."

  VAULT_PATH="local/management/argocd/azure/apps/argocd"

  CLIENT_SECRET=$(pass show private/azure/entraid/apps/argocd/client-secrets/argocd/value | head -n1)
  CLIENT_ID=$(pass show private/azure/entraid/apps/argocd/client-id | head -n1)
  TENANT_ID=$(pass show private/azure/entraid/apps/argocd/tenant-id | head -n1)

  if [[ -z "$CLIENT_SECRET" ]]; then
    echo "❌ Failed to read Argo CD client secret from pass."
    return 1
  fi

  vault kv put "$VAULT_PATH" \
    client_id="$CLIENT_ID" \
    tenant_id="$TENANT_ID" \
    client_secret="$CLIENT_SECRET"

  echo "✅ Argo CD Entra ID client secret stored in Vault"
}

# ----------------------------------------------------------------------------
# Keycloak credentials
# ----------------------------------------------------------------------------
create_keycloak_app_registration_azure() {
  echo "🔐 Writing Entra ID App secret..."

  VAULT_PATH="local/management/keycloak/azure/apps/keycloak"

  CLIENT_SECRET=$(pass show private/azure/entraid/apps/keycloak/client-secrets/keycloak/value | head -n1)
  CLIENT_ID=$(pass show private/azure/entraid/apps/keycloak/client-id | head -n1)
  TENANT_ID=$(pass show private/azure/entraid/apps/keycloak/tenant-id | head -n1)

  if [[ -z "$CLIENT_SECRET" ]]; then
    echo "❌ Failed to read Keycloak client secret from pass."
    return 1
  fi

  vault kv put "$VAULT_PATH" \
    client_id="$CLIENT_ID" \
    tenant_id="$TENANT_ID" \
    client_secret="$CLIENT_SECRET"

  echo "✅ Keycloak Entra ID client secret stored in Vault"
}


create_keycloak_bootstrap_secret() {
  BOOTSTRAP_USERNAME="admin"
  echo "🔐 Generating Keycloak $BOOTSTRAP_USERNAME credentials..."

  VAULT_PATH="local/management/keycloak/bootstrap"

  if vault kv get "$VAULT_PATH" >/dev/null 2>&1; then
    echo "⚠️  Bootstrap user already exists. Skipping."
    return
  fi

  BOOTSTRAP_PASSWORD="$(openssl rand -hex 16)"

  vault kv put "$VAULT_PATH" \
    username="$BOOTSTRAP_USERNAME" \
    password="$BOOTSTRAP_PASSWORD" \
    disabled=0 > /dev/null

  echo "✅ Keycloak bootstrap credentials stored in Vault"
}


create_keycloak_administrator_secret() {
  ADMINISTRATOR_USERNAME="administrator"
  echo "🔐 Generating Keycloak $ADMINISTRATOR_USERNAME credentials..."

  VAULT_PATH="local/management/keycloak/administrator"

  if vault kv get "$VAULT_PATH" >/dev/null 2>&1; then
    echo "⚠️  Administrator user already exists. Skipping."
    return
  fi

  ADMINISTRATOR_PASSWORD="$(openssl rand -hex 16)"

  vault kv put "$VAULT_PATH" \
    username="$ADMINISTRATOR_USERNAME" \
    password="$ADMINISTRATOR_PASSWORD" > /dev/null

  echo "✅ Keycloak administrator credentials stored in Vault"
}


# ----------------------------------------------------------------------------
# Crossplane App registration credential in Azure
# ----------------------------------------------------------------------------
create_crossplane_app_registration_azure() {
  echo "🔐 Writing Crossplane Entra ID App secret..."

  VAULT_PATH="local/management/crossplane/azure/apps/crossplane"

  CLIENT_SECRET=$(pass show private/azure/entraid/apps/crossplane/client-secrets/crossplane/value | head -n1)
  CLIENT_ID=$(pass show private/azure/entraid/apps/crossplane/client-id | head -n1)
  TENANT_ID=$(pass show private/azure/entraid/apps/crossplane/tenant-id | head -n1)

  if [[ -z "$CLIENT_SECRET" ]]; then
    echo "❌ Failed to read Crossplane client secret from pass."
    return 1
  fi

  vault kv put "$VAULT_PATH" \
    client_id="$CLIENT_ID" \
    tenant_id="$TENANT_ID" \
    client_secret="$CLIENT_SECRET"

  echo "✅ Crossplane Entra ID client secret stored in Vault"
}


# ----------------------------------------------------------------------------
# Crossplane credential in GitHub
# ----------------------------------------------------------------------------
create_github_app_secret_crossplane() {
  echo "🔐 Writing Crossplane GitHub App secret..."

  # Access to https://github.com/rezakaramad
  echo "🔐 Copying 'rezakaramad-crossplane' GitHub App credentials from 'pass' local password store..."
  APP_ID=$(pass show private/github/apps/rezakaramad-crossplane/app-id | head -n1)
  INSTALLATION_ID=$(pass show private/github/apps/rezakaramad-crossplane/installation-id | head -n1)
  PRIVATE_KEY=$(pass show private/github/apps/rezakaramad-crossplane/private-key)

  echo "🔐 Storing 'rezakaramad-crossplane' GitHub App credentials in Vault..."
  vault kv put local/management/github/apps/crossplane/rezakaramad \
    app-id="$APP_ID" \
    installation-id="$INSTALLATION_ID" \
    private-key="$PRIVATE_KEY"

  echo "✅ Crossplane GitHub App secret for 'https://github.com/rezakaramad' written to Vault"

  # Access to https://github.com/fluxdojo
  echo "🔐 Copying 'fluxdojo-crossplane' GitHub App credentials from 'pass' local password store..."
  APP_ID=$(pass show private/github/apps/fluxdojo-crossplane/app-id | head -n1)
  INSTALLATION_ID=$(pass show private/github/apps/fluxdojo-crossplane/installation-id | head -n1)
  PRIVATE_KEY=$(pass show private/github/apps/fluxdojo-crossplane/private-key)

  echo "🔐 Storing 'fluxdojo-crossplane' GitHub App credentials in Vault..."
  vault kv put local/management/github/apps/crossplane/fluxdojo \
    app-id="$APP_ID" \
    installation-id="$INSTALLATION_ID" \
    private-key="$PRIVATE_KEY"

  echo "✅ Crossplane GitHub App secret for 'https://github.com/fluxdojo' written to Vault"

  echo "🎉 All Crossplane GitHub App secrets successfully stored in Vault so Argo CD can access GitHub repositories securely."
}


# ----------------------------------------------------------------------------
# PowerDNS secret for external-dns
# ----------------------------------------------------------------------------
create_powerdns_secrets() {
  VAULT_BASE_PATH="local/powerdns"
  VAULT_DB_PATH="$VAULT_BASE_PATH/db"
  VAULT_API_PATH="$VAULT_BASE_PATH/api"

  POSTGRES_USER="pdns"

  echo "🔐 Generating and storing PowerDNS secret for external-dns operator..."

  POSTGRES_PASSWORD="$(openssl rand -hex 32)"
  POWERDNS_API_KEY="$(openssl rand -hex 32)"
  POWERDNS_ADMIN_PASSWORD="$(openssl rand -hex 32)"

  vault kv put "$VAULT_DB_PATH" \
      user="$POSTGRES_USER" \
      password="$POSTGRES_PASSWORD" > /dev/null

  vault kv put "$VAULT_API_PATH" \
      key="$POWERDNS_API_KEY" > /dev/null

  echo "✅ Secrets stored in Vault"
}


# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  # Updating /etc/hosts is necessary for bootstrapping because the management cluster's Traefik LoadBalancer IP is dynamic 
  # and must be resolved to access Argo CD, Vault, and Keycloak during setup. 
  # Also it's needed to ensure that the self-signed certificate issued for *.mgmt.rezakara.demo is trusted and matches the hostname used to access the services.
  # After bootstrapping, it will be cleaned up and DNS requestes will be responded by the local PowerDNS instance.
  update_hosts
  vault_login
  create_github_app_secret_argocd
  register_clusters_argocd
  create_argocd_app_registration_azure
  create_keycloak_app_registration_azure
  create_keycloak_bootstrap_secret
  create_keycloak_administrator_secret
  create_crossplane_app_registration_azure
  create_github_app_secret_crossplane
  create_powerdns_secrets

  echo "✅ Bootstrap complete"
}

main "$@"
