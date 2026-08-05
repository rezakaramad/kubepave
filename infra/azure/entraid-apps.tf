# ---------------------------------------------------------------
# Data Sources
# ---------------------------------------------------------------
# Returns the current Terraform identiy (user or service principal) information
data "azuread_client_config" "current" {}

# Return the information for the user "reza" in the tenant. This is used to assign app roles to the user.
data "azuread_user" "reza" {
  user_principal_name = "reza@yourtenant.onmicrosoft.com"
}

# Microsoft Graph is just another app in Azure, owned by Microsoft.
# It is the “thing” your apps ask permission from (to read users, groups, etc.).
# Client ID is the app’s public ID number. Global, same everywhere.
# Object ID is the ID of the service principal inside your tenant. Local.
# To grant your app permission on Graph, Azure needs Graph’s object ID inside your tenant.
# Later, when your app asks Graph for data, we'll use Graph's object ID to tell Graph which tenant to read from.
# Microsoft Graph API service principal client ID
data "azuread_service_principal" "msgraph" {
  client_id = "00000003-0000-0000-c000-000000000000"
}

# ---------------------------------------------------------------
# Argo CD
# ---------------------------------------------------------------
# Create the Argo CD profile in Entra ID
resource "azuread_application" "argocd" {
  display_name = "Argo CD"

  # The audience for the application. "AzureADMyOrg" means only users in this tenant can sign in.
  # Other options are "AzureADMultipleOrgs" (any Azure AD tenant) 
  # and "AzureADandPersonalMicrosoftAccount" (any Azure AD tenant or personal Microsoft account).
  sign_in_audience = "AzureADMyOrg"

  # Whoever run the tofu apply will be the owner of the application, and can manage it in the Azure portal.
  # Plus, the Crossplane service principal needs to modify the app roles, so we add it as an owner too.
  owners = [ 
    data.azuread_client_config.current.object_id,
    azuread_service_principal.crossplane.object_id
  ]

  # The redirect URI is where Entra ID will send the user after they sign in.
  # These two URIs are used in local and GCP setups respectively.
  web {
    redirect_uris = [
      "https://argocd.mgmt.rezakara.demo/auth/callback",
      "https://argocd.gcp.talktorubberduck.dev/auth/callback"
    ]
  }

  # We want to manage app roles with Terraform, but we don't want Terraform to delete and recreate the app 
  # every time we change the app roles. So we use lifecycle.ignore_changes to tell Terraform to ignore changes 
  # to the app_role_ids and app_role properties, which are the properties that define the app roles.
  # Crossplane functions creates per-tenant app roles at runtime.
  lifecycle {
    ignore_changes = [
      app_role
    ]
  }
}

# Create a physical thing in Entra ID, the actual identity that represents the Argo CD application.
# Permissions are granted to this identity which is called a service principal.
resource "azuread_service_principal" "argocd" {
  # Links the service principal to the application
  client_id = azuread_application.argocd.client_id

  # By default, any user in your tenant can sign in to the app.
  # We want only users who are explicitly assigned to an app role to be able to sign in, so we set this to true.
  app_role_assignment_required = true

  # Whoever run the tofu apply will be the owner of the service principal, and can manage it in the Azure portal.
  owners = [ data.azuread_client_config.current.object_id ]
}

# Create a client secret for the Argo CD application
resource "azuread_application_password" "argocd" {
  application_id = azuread_application.argocd.id
  display_name   = "Argo CD"

  lifecycle {
    ignore_changes = all
  }
}

# Define app roles for Argo CD

# Login flow:
# User → member of platform-admins
#         ↓
# Group assigned to App Role "admin"
#         ↓
# Token contains:
# "roles": ["admin"]
#         ↓
# Argo CD AppProject:
# g, admin, role:admin
#         ↓
# ✅ Access granted

# Your group gives you a role, the role goes into your login token, and Argo CD uses that to decide what you’re allowed to do.

# Add default app roles for Argo CD.
# Argo CD admin role: can do everything in Argo CD
resource "azuread_application_app_role" "argocd_admin" {
  application_id = azuread_application.argocd.id
  
  # This is a fixed UUID that we can hardcode since it won't change
  role_id        = "c9e9bd06-4b17-4559-85b0-f2a17bd8cb8f"

  allowed_member_types = ["User"]
  description          = "Argo CD Administers can perform all operations in Argo CD, including managing applications, repositories, and settings."
  display_name         = "Argo CD Admin"
  value                = "admin"
}

resource "azuread_application_app_role" "argocd_viewer" {
  application_id = azuread_application.argocd.id
  role_id        = "89f1dec8-7153-4bbc-a2ee-82e16ce9ffac"

  allowed_member_types = ["User"]
  description          = "Argo CD Viewers can view all resources in Argo CD, but cannot make any changes."
  display_name         = "Argo CD Viewer"
  value                = "viewer"
}

# Role assignments
# Free tier of Azure AD doesn't support group-based app role assignments,
# so we have to assign the app roles directly to the user. 
# In a production environment, you would typically assign the app roles to groups, and then add users to those groups.
resource "azuread_app_role_assignment" "argocd_platform_admin" {
  app_role_id         = azuread_application_app_role.argocd_admin.role_id
  principal_object_id = data.azuread_user.reza.object_id
  resource_object_id  = azuread_service_principal.argocd.object_id
}

resource "azuread_app_role_assignment" "argocd_platform_viewer" {
  app_role_id         = azuread_application_app_role.argocd_viewer.role_id
  principal_object_id = data.azuread_user.reza.object_id
  resource_object_id  = azuread_service_principal.argocd.object_id
}

# Tenant-wide admin consent for the OIDC sign-in scopes.
#
# Argo CD requests openid/profile/email dynamically at login and does not
# declare them in required_resource_access. Historically this grant was created
# by clicking "Grant admin consent" once; capturing it here means a fresh apply
# (or SP recreation) reproduces it automatically instead of breaking login with
# "needs permission that only an admin can grant".
resource "azuread_service_principal_delegated_permission_grant" "argocd_oidc" {
  service_principal_object_id          = azuread_service_principal.argocd.object_id
  resource_service_principal_object_id = data.azuread_service_principal.msgraph.object_id
  claim_values                         = ["openid", "profile", "email"]
}

# Argo CD outputs
output "argocd_client_id" {
  value = azuread_application.argocd.client_id
}

output "argocd_client_secret_id" {
  value = azuread_application_password.argocd.key_id
}

output "argocd_client_secret_value" {
  value     = azuread_application_password.argocd.value
  sensitive = true
}

# ---------------------------------------------------------------
# Crossplane
# ---------------------------------------------------------------
resource "azuread_application" "crossplane" {
  display_name     = "Crossplane"
  sign_in_audience = "AzureADMyOrg"
  owners = [ data.azuread_client_config.current.object_id ]

  required_resource_access {
    resource_app_id = data.azuread_service_principal.msgraph.client_id

    # User.ReadWrite.All role
    resource_access {
      id   = "741f803b-c850-494e-b5df-cde7c675a1ca"
      type = "Role"
    }

    # Group.ReadWrite.All role
    resource_access {
      id   = "62a82d76-70ea-41e2-9197-370581804d09"
      type = "Role"
    }

    # Application.ReadWrite.All role
    resource_access {
      id   = "18a4783c-866b-4cc7-a460-3d5e5662c884"
      type = "Role"
    }

    # AppRoleAssignment.ReadWrite.All role
    resource_access {
      id   = "06b708a9-e830-4db3-a914-8e69da51d44f"
      type = "Role"
    }
  }
}

resource "azuread_service_principal" "crossplane" {
  client_id = azuread_application.crossplane.client_id
}

resource "azuread_application_password" "crossplane" {
  application_id = azuread_application.crossplane.id
  display_name   = "Crossplane"

  lifecycle {
    ignore_changes = all
  }
}

# Role assignments
# User.ReadWrite.All
resource "azuread_app_role_assignment" "crossplane_users" {
  principal_object_id = azuread_service_principal.crossplane.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
  app_role_id         = "741f803b-c850-494e-b5df-cde7c675a1ca"
}

# Group.ReadWrite.All
resource "azuread_app_role_assignment" "crossplane_groups" {
  principal_object_id = azuread_service_principal.crossplane.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
  app_role_id         = "62a82d76-70ea-41e2-9197-370581804d09"
}

# Application.ReadWrite.All
resource "azuread_app_role_assignment" "crossplane_apps" {
  principal_object_id = azuread_service_principal.crossplane.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
  app_role_id         = "18a4783c-866b-4cc7-a460-3d5e5662c884"
}

# AppRoleAssignment.ReadWrite.All
resource "azuread_app_role_assignment" "crossplane_approles" {
  principal_object_id = azuread_service_principal.crossplane.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
  app_role_id         = "06b708a9-e830-4db3-a914-8e69da51d44f"
}

# Crossplane outputs
output "crossplane_client_id" {
  value = azuread_application.crossplane.client_id
}

output "crossplane_client_secret_id" {
  value = azuread_application_password.crossplane.key_id
}

output "crossplane_client_secret_value" {
  value     = azuread_application_password.crossplane.value
  sensitive = true
}

# ---------------------------------------------------------------
# Keycloak
# ---------------------------------------------------------------
resource "azuread_application" "keycloak" {
  display_name     = "Keycloak"
  sign_in_audience = "AzureADMyOrg"
  owners = [ data.azuread_client_config.current.object_id ]

  # When this user logs in, put their group memberships into the token 
  # so Keycloak can resolve which groups the signed-in user belongs to (e.g. platform-admins).
  # Entra only accepts a fixed set of values for group_membership_claims:
  #   None — no groups in the token
  #   SecurityGroup — include security groups
  #   ApplicationGroup — include only groups assigned to this application
  #   DirectoryRole — include Entra directory roles (like Global Administrator)
  #   All — include every group the user is in
  group_membership_claims = [
    "SecurityGroup",
    "ApplicationGroup"
  ]

  web {
    redirect_uris = [
      "https://oidc.mgmt.rezakara.demo/realms/management/broker/azure/endpoint"
    ]
  }

  // Include the groups claim in both the ID token and access token so Keycloak can read it.
  // In 'group_membership_claims' we told Entra which groups to include,
  // and here we tell Entra to actually include the claim in the tokens.
  optional_claims {
    id_token {
      name = "groups"
    }
    access_token {
      name = "groups"
    }
  }
}

resource "azuread_service_principal" "keycloak" {
  client_id = azuread_application.keycloak.client_id
}

resource "azuread_application_password" "keycloak" {
  application_id = azuread_application.keycloak.id
  display_name   = "Keycloak"

  lifecycle {
    ignore_changes = all
  }
}

# Keycloak outputs
output "keycloak_client_id" {
  value = azuread_application.keycloak.client_id
}

output "keycloak_client_secret_id" {
  value = azuread_application_password.keycloak.key_id
}

output "keycloak_client_secret_value" {
  value     = azuread_application_password.keycloak.value
  sensitive = true
}

# ---------------------------------------------------------------
# Backstage
# ---------------------------------------------------------------
resource "azuread_application" "backstage" {
  display_name     = "Backstage"
  sign_in_audience = "AzureADMyOrg"
  owners = [
    data.azuread_client_config.current.object_id,
    azuread_service_principal.crossplane.object_id
  ]

  # Include group memberships in the token so Backstage can resolve
  # which groups the signed-in user belongs to (e.g. platform-admins).
  group_membership_claims = [
    "SecurityGroup",
    "ApplicationGroup"
  ]

  web {
    redirect_uris = [
      # oauth2-proxy callback — the proxy handles the full OIDC flow,
      # Backstage no longer talks to Microsoft directly.
      "https://backstage.mgmt.rezakara.demo/oauth2/callback",
    ]
  }

  optional_claims {
    id_token {
      name = "groups"
    }
    access_token {
      name = "groups"
    }
  }

  required_resource_access {
    resource_app_id = data.azuread_service_principal.msgraph.client_id

    # openid — required for OIDC sign-in
    resource_access {
      id   = "37f7f235-527c-4136-accd-4a02d197296e"
      // Two values are possible: "Scope" or "Role". 
      // Scope is for delegated permissions (user context), Role is for application permissions (app context).
      // The app borrows the user's permissions for the duration of that user's session.
      // Say you (reza) sign into Backstage, and Backstage has the User.Read delegated scope.
      // You log in with your Entra account.
      // Entra gives Backstage a token that says "this is acting for reza."
      // Backstage calls Microsoft Graph: "give me the profile of the current user."
      // Graph returns YOUR profile, because the token represents you.
      // Backstage cannot read someone else's profile with this, because it is limited to what you can see.
      type = "Scope"
    }

    # email — include email in token
    resource_access {
      id   = "64a6cdd6-aab1-4aad-94b8-3cc8405e90d0"
      type = "Scope"
    }

    # profile — include basic profile info in token
    resource_access {
      id   = "14dad69e-099b-42c9-810b-d002981feec1"
      type = "Scope"
    }

    # offline_access — allow token refresh
    resource_access {
      id   = "7427e0e9-2fba-42fe-b0c0-848c9e6a8182"
      type = "Scope"
    }

    # User.Read — read signed-in user profile
    resource_access {
      id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"
      type = "Scope"
    }
  }

  lifecycle {
    ignore_changes = [ app_role ]
  }
}

resource "azuread_service_principal" "backstage" {
  client_id                    = azuread_application.backstage.client_id
  app_role_assignment_required = true
  owners                       = [data.azuread_client_config.current.object_id]
}

resource "azuread_application_password" "backstage" {
  application_id = azuread_application.backstage.id
  display_name   = "Backstage"

  lifecycle {
    ignore_changes = all
  }
}

# Create a role called 'platform-admin' on the Backstage app
resource "azuread_application_app_role" "backstage_platform_admin" {
  application_id = azuread_application.backstage.id
  role_id        = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

  # This role can only be assigned to users, not groups or service principals. 
  # TODO: Replace this with Group assignment
  # In Azure free tier, you can only use CLI to assign app roles to groups, not the portal.
  allowed_member_types = ["User"]
  description          = "Platform admins have full access to Backstage."
  display_name         = "Backstage Platform Admin"
  value                = "platform-admin"
}

# Assign platform-admin role directly to reza (free-tier Azure AD workaround —
# in production assign to the platform-admins group instead)
resource "azuread_app_role_assignment" "backstage_platform_admin" {
  app_role_id         = azuread_application_app_role.backstage_platform_admin.role_id
  principal_object_id = data.azuread_user.reza.object_id
  resource_object_id  = azuread_service_principal.backstage.object_id
}

# Backstage outputs
output "backstage_client_id" {
  value = azuread_application.backstage.client_id
}

output "backstage_client_secret_id" {
  value = azuread_application_password.backstage.key_id
}

output "backstage_client_secret_value" {
  value     = azuread_application_password.backstage.value
  sensitive = true
}

# ---------------------------------------------------------------
# Backstage Catalog Sync
# Reads users and groups from Entra ID into the Backstage catalog
# via the MSGraph API. 
# We create another application for this purpose, separate from the SSO app, 
# because those are two different use cases: 
# one is for user login, the other is for reading data from Entra ID.
# Backstage SSO handles user login, uses delegated permissions (on behalf of the user), and acts as a user. 
# The catalog sync app uses application permissions (no user context), and acts as the app itself.
# It runs in the background to import users/groups into Backstage

# ---------------------------------------------------------------
resource "azuread_application" "backstage_catalog_sync" {
  display_name     = "Backstage Catalog Sync"
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]

  required_resource_access {
    # Microsoft Graph
    resource_app_id = data.azuread_service_principal.msgraph.client_id

    # User.Read.All role — read all users' profiles
    resource_access {
      id   = "df021288-bdef-4463-88db-98f22de89214"
      type = "Role"
    }

    # Group.Read.All role — read all groups and memberships
    resource_access {
      id   = "5b567255-7703-4780-807c-7be8301ae99b"
      type = "Role"
    }

    # GroupMember.Read.All role — read group memberships
    resource_access {
      id   = "98830695-27a2-44f7-8c18-0c3ebc9698f6"
      type = "Role"
    }
  }
}

resource "azuread_service_principal" "backstage_catalog_sync" {
  client_id = azuread_application.backstage_catalog_sync.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azuread_application_password" "backstage_catalog_sync" {
  application_id = azuread_application.backstage_catalog_sync.id
  display_name   = "Backstage Catalog Sync"

  lifecycle {
    ignore_changes = all
  }
}

# Grant admin consent for the application permissions
resource "azuread_app_role_assignment" "backstage_catalog_sync_users" {
  principal_object_id = azuread_service_principal.backstage_catalog_sync.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
  app_role_id         = "df021288-bdef-4463-88db-98f22de89214" # User.Read.All
}

resource "azuread_app_role_assignment" "backstage_catalog_sync_groups" {
  principal_object_id = azuread_service_principal.backstage_catalog_sync.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
  app_role_id         = "5b567255-7703-4780-807c-7be8301ae99b" # Group.Read.All
}

resource "azuread_app_role_assignment" "backstage_catalog_sync_group_members" {
  principal_object_id = azuread_service_principal.backstage_catalog_sync.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
  app_role_id         = "98830695-27a2-44f7-8c18-0c3ebc9698f6" # GroupMember.Read.All
}

# Backstage Catalog Sync outputs
output "backstage_catalog_sync_client_id" {
  value = azuread_application.backstage_catalog_sync.client_id
}

output "backstage_catalog_sync_client_secret_id" {
  value = azuread_application_password.backstage_catalog_sync.key_id
}

output "backstage_catalog_sync_client_secret_value" {
  value     = azuread_application_password.backstage_catalog_sync.value
  sensitive = true
}

# ---------------------------------------------------------------
# Vault
# ---------------------------------------------------------------
# SSO login for human tenant operators. 
# Mirrors the Argo CD pattern:
# per-tenant app roles (one per tenant) are created by the
# xtenantentra Crossplane function, assigned to a per-tenant Entra group, and
# surfaced to Vault in the "roles" claim of the ID token. Vault's OIDC auth
# method maps that claim (groups_claim = roles) to a per-tenant policy so each
# operator can read/write only tenants/<tenant>/* in Vault.
resource "azuread_application" "vault" {
  display_name     = "Vault"
  sign_in_audience = "AzureADMyOrg"
  owners = [
    data.azuread_client_config.current.object_id,

    # Crossplane SP is a co-owner so the xtenantentra function can add/remove
    # per-tenant app roles on this application at runtime.
    azuread_service_principal.crossplane.object_id
  ]

  # The redirect URIs are where Entra ID will send the user after they sign in.
  web {
    redirect_uris = [
      # Vault UI OIDC callback (mount path "oidc", role "oidc").
      "https://vault.mgmt.rezakara.demo/ui/vault/auth/oidc/oidc/callback",

      # Vault CLI OIDC callback (`vault login -method=oidc`).
      # To remind, localhost is not the Vault server. It is the operator's laptop where they ran the command.
      # Read './vault-oidc-login-flow.md' for details on how the CLI login works.
      "http://localhost:8250/oidc/callback"
    ]
  }

  # Per-tenant app roles are managed by the xtenantentra function, not Terraform.
  # Ignore app_role so Terraform doesn't delete/recreate roles the function owns.
  lifecycle {
    ignore_changes = [
      app_role
    ]
  }
}

resource "azuread_service_principal" "vault" {
  client_id                    = azuread_application.vault.client_id
  app_role_assignment_required = true
  owners                       = [data.azuread_client_config.current.object_id]
}

resource "azuread_application_password" "vault" {
  application_id = azuread_application.vault.id
  display_name   = "Vault"

  lifecycle {
    ignore_changes = all
  }
}

# Tenant-wide (AllPrincipals) admin consent for the OIDC sign-in scopes.
#
# The Vault app requests openid/profile/email dynamically at login time and does
# not declare them in required_resource_access (same as the Argo CD app).
# When the tenant disallows user self-consent, a login otherwise fails with
# "needs permission that only an admin can grant". This grant is the Terraform
# equivalent of clicking "Grant admin consent" once, so a fresh apply (or app
# recreation) reproduces it automatically instead of requiring a manual step.
resource "azuread_service_principal_delegated_permission_grant" "vault_oidc" {
  service_principal_object_id          = azuread_service_principal.vault.object_id
  resource_service_principal_object_id = data.azuread_service_principal.msgraph.object_id
  claim_values                         = ["openid", "profile", "email"]
}

# Vault outputs
output "vault_client_id" {
  value = azuread_application.vault.client_id
}

output "vault_client_secret_id" {
  value = azuread_application_password.vault.key_id
}

output "vault_client_secret_value" {
  value     = azuread_application_password.vault.value
  sensitive = true
}

# ---------------------------------------------------------------
# General outputs
# ---------------------------------------------------------------
output "tenant_id" {
  value = data.azuread_client_config.current.tenant_id
}
