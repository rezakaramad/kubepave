# ---------------------------------------------------------------
# Data Sources
# ---------------------------------------------------------------
# Returns the current Terraform identiy (user or service principal) information
data "azuread_client_config" "current" {}

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

}

resource "azuread_service_principal" "argocd" {
  # Links the service principal to the application
  client_id = azuread_application.argocd.client_id
  app_role_assignment_required = true
  owners = [ data.azuread_client_config.current.object_id ]
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
resource "random_uuid" "argocd_admin" {}

resource "azuread_application_app_role" "argocd_admin" {
  application_id = azuread_application.argocd.id
  role_id        = random_uuid.argocd_admin.id

  allowed_member_types = ["User"]
  description          = "Argo CD Administers can perform all operations in Argo CD, including managing applications, repositories, and settings."
  display_name         = "Argo CD Admin"
  value                = "admin"
}

# Argo CD viewer role: can view everything in Argo CD, but cannot make any changes
resource "random_uuid" "argocd_viewer" {}

resource "azuread_application_app_role" "argocd_viewer" {
  application_id = azuread_application.argocd.id
  role_id        = random_uuid.argocd_viewer.id

  allowed_member_types = ["User"]
  description          = "Argo CD Viewers can view all resources in Argo CD, but cannot make any changes."
  display_name         = "Argo CD Viewer"
  value                = "viewer"
}

# Role assignments
resource "azuread_app_role_assignment" "platform_admin_group" {
  app_role_id         = azuread_application_app_role.argocd_admin.role_id
  principal_object_id = azuread_group.platform_admins.object_id
  resource_object_id  = azuread_service_principal.argocd.object_id
}

resource "azuread_app_role_assignment" "platform_viewer_group" {
  app_role_id         = azuread_application_app_role.argocd_viewer.role_id
  principal_object_id = azuread_group.platform_viewers.object_id
  resource_object_id  = azuread_service_principal.argocd.object_id
}

output "argocd_client_id" {
  value = azuread_application.argocd.client_id
}

output "argocd_tenant_id" {
  value = data.azuread_client_config.current.tenant_id
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

    resource_access {
      id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"
      type = "Scope"
    }

    resource_access {
      id   = "19dbc75e-c2e2-444c-a770-ec69d8559fc7"
      type = "Role"
    }

    resource_access {
      id   = "62a82d76-70ea-41e2-9197-370581804d09"
      type = "Role"
    }
  }
}

resource "azuread_service_principal" "crossplane" {
  client_id = azuread_application.crossplane.client_id
}

resource "azuread_application_password" "crossplane" {
  application_id = azuread_application.crossplane.id
  display_name   = "crossplane"

  depends_on = [
    azuread_application.crossplane
  ]
}

output "crossplane_client_id" {
  value = azuread_application.crossplane.client_id
}

output "crossplane_tenant_id" {
  value = data.azuread_client_config.current.tenant_id
}

output "crossplane_client_secret_id" {
  value = azuread_application_password.crossplane.key_id
}

output "crossplane_client_secret" {
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
  display_name   = "keycloak"

  depends_on = [
    azuread_application.keycloak
  ]
}

output "keycloak_client_id" {
  value = azuread_application.keycloak.client_id
}

output "keycloak_tenant_id" {
  value = data.azuread_client_config.current.tenant_id
}

output "keycloak_client_secret_id" {
  value = azuread_application_password.keycloak.key_id
}

output "keycloak_client_secret" {
  value     = azuread_application_password.keycloak.value
  sensitive = true
}
