# ---------------------------------------------------------------
# Data Sources
# ---------------------------------------------------------------
# Returns the current Terraform identiy (user or service principal) information
data "azuread_client_config" "current" {}

data "azuread_user" "reza" {
  user_principal_name = "r.karamad_gmail.com#EXT#@rkaramadgmail.onmicrosoft.com"
}

# Microsoft Graph API service principal
data "azuread_service_principal" "msgraph" {
  client_id = "00000003-0000-0000-c000-000000000000"
}

# ---------------------------------------------------------------
# Argo CD
# ---------------------------------------------------------------
resource "azuread_application" "argocd" {
  display_name = "Argo CD"
  sign_in_audience = "AzureADMyOrg"
  owners = [ data.azuread_client_config.current.object_id ]

  web {
    redirect_uris = [
      "https://argocd.mgmt.rezakara.demo/auth/callback"
    ]
  }

  # We want to manage app roles with Terraform, but we don't want Terraform to delete and recreate the app 
  # every time we change the app roles. So we use lifecycle.ignore_changes to tell Terraform to ignore changes 
  # to the app_role_ids and app_role properties, which are the properties that define the app roles.
  lifecycle {
    ignore_changes = [
      app_role
    ]
  }
}

resource "azuread_service_principal" "argocd" {
  # Links the service principal to the application
  client_id = azuread_application.argocd.client_id
  app_role_assignment_required = true
  owners = [ data.azuread_client_config.current.object_id ]
}

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
# Argo CD:
# g, admin, role:admin
#         ↓
# ✅ Access granted

# Your group gives you a role, the role goes into your login token, and Argo CD uses that to decide what you’re allowed to do.

# Argo CD admin role: can do everything in Argo CD
resource "azuread_application_app_role" "argocd_admin" {
  application_id = azuread_application.argocd.id
  role_id        = "c9e9bd06-4b17-4559-85b0-f2a17bd8cb8f" # This is a fixed UUID that we can hardcode since it won't change

  allowed_member_types = ["User"]
  description          = "Argo CD Administers can perform all operations in Argo CD, including managing applications, repositories, and settings."
  display_name         = "Argo CD Admin"
  value                = "admin"
}

# Argo CD viewer role: can view everything in Argo CD, but cannot make any changes
resource "random_uuid" "argocd_viewer" {}

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
    resource_app_id = "00000003-0000-0000-c000-000000000000"

    # User.ReadWrite.All
    resource_access {
      id   = "741f803b-c850-494e-b5df-cde7c675a1ca" # User.ReadWrite.All
      type = "Role"
    }

    # Group.ReadWrite.All
    resource_access {
      id   = "62a82d76-70ea-41e2-9197-370581804d09"
      type = "Role"
    }

    # Application.ReadWrite.All
    resource_access {
      id   = "18a4783c-866b-4cc7-a460-3d5e5662c884"
      type = "Role"
    }

    # AppRoleAssignment.ReadWrite.All
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

  group_membership_claims = [
    "SecurityGroup",
    "ApplicationGroup"
  ]

  web {
    redirect_uris = [
      "https://oidc.mgmt.rezakara.demo/realms/management/broker/azure/endpoint"
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
# General outputs
# ---------------------------------------------------------------
output "tenant_id" {
  value = data.azuread_client_config.current.tenant_id
}
