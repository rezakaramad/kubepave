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
    echo "→ No existing state found (fresh run)"
  fi
fi

# ----------------------------------------
# Tofu operations
# ----------------------------------------
echo "→ Initializing OpenTofu"
tofu -chdir="$TF_DIR" init

echo "→ Applying infrastructure"
tofu -chdir="$TF_DIR" apply -auto-approve

# ----------------------------------------
# Export secrets
# ----------------------------------------
echo "→ Exporting secrets to pass"
"$TF_DIR/tofu-to-pass.sh" "$TF_DIR"

# ----------------------------------------
# Re-encrypt state
# ----------------------------------------
echo "→ Re-encrypting terraform.tfstate"
gpg --yes --encrypt \
  --recipient "$(pass private/tofu/gpg-recipient)" \
  "$STATE"

echo "→ Done ✅"
