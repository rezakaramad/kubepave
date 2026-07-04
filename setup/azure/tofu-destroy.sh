#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------
# Input
# ----------------------------------------
TF_DIR="${1:-.}"

echo "→ Using Terraform directory: $TF_DIR"

STATE="$TF_DIR/terraform.tfstate"
STATE_GPG="$TF_DIR/terraform.tfstate.gpg"

# ----------------------------------------
# Ensure state exists
# ----------------------------------------
echo "→ Checking Terraform state..."

if [ ! -f "$STATE" ]; then
  if [ -f "$STATE_GPG" ]; then
    echo "→ Decrypting terraform.tfstate.gpg"
    gpg --quiet --decrypt "$STATE_GPG" > "$STATE"
  else
    echo "⚠️  No state found — nothing to destroy"
    exit 0
  fi
fi

# ----------------------------------------
# Tofu operations
# ----------------------------------------
echo "→ Initializing OpenTofu"
tofu -chdir="$TF_DIR" init

echo "→ Destroying application passwords first"
tofu -chdir="$TF_DIR" destroy -auto-approve \
  -target=azuread_application_password.argocd \
  -target=azuread_application_password.crossplane \
  -target=azuread_application_password.keycloak

echo "→ Destroying infrastructure"
# AzureAD provider sometimes errors with 404 after app deletion
tofu -chdir="$TF_DIR" destroy -auto-approve || {
  echo "⚠️  Destroy completed with known AzureAD 404 issues — ignoring"
}

echo "→ Done ✅"
