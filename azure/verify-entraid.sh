#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${1:-Argo CD}"

echo "→ Verifying Entra ID setup for: $APP_NAME"
echo ""

# ----------------------------------------
# Get App
# ----------------------------------------
APP_ID=$(az ad app list \
  --display-name "$APP_NAME" \
  --query "[0].appId" -o tsv)

if [[ -z "$APP_ID" ]]; then
  echo "❌ App registration not found"
  exit 1
fi

echo "✔ App found: $APP_ID"

# ----------------------------------------
# Get Service Principal
# ----------------------------------------
SP_ID=$(az ad sp show \
  --id "$APP_ID" \
  --query id -o tsv)

echo "✔ Service Principal: $SP_ID"

# ----------------------------------------
# App Roles
# ----------------------------------------
echo ""
echo "→ App Roles"

az ad app show --id "$APP_ID" \
  --query "appRoles[].{value:value,id:id}" -o table

# ----------------------------------------
# Role Assignments
# ----------------------------------------
echo ""
echo "→ Role Assignments"

ASSIGNMENTS=$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/appRoleAssignedTo")

echo "$ASSIGNMENTS" | jq -r '
.value[] | 
"principal: \(.principalDisplayName) | roleId: \(.appRoleId)"
'

# ----------------------------------------
# Check current user
# ----------------------------------------
echo ""
echo "→ Checking current user"

USER_ID=$(az ad signed-in-user show --query id -o tsv)

MATCH=$(echo "$ASSIGNMENTS" | jq -r --arg UID "$USER_ID" '
.value[] | select(.principalId == $UID)
')

if [[ -z "$MATCH" ]]; then
  echo "❌ Current user has NO role assignment"
  exit 1
else
  echo "✔ Current user has role assignment"
fi

echo ""
echo "✅ Verification complete"
