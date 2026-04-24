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

  web {
    redirect_uris = [
      "https://argocd.example.com/auth/callback"
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
  display_name   = "argocd"

  depends_on = [
    azuread_application.argocd
  ]
}

output "argocd_client_id" {
  value = azuread_application.argocd.client_id
}

output "argocd_tenant_id" {
  value = data.azuread_client_config.current.tenant_id
}

output "argocd_client_secret_id" {
  value = azuread_application_password.argocd.key_id
}

output "argocd_client_secret" {
  value     = azuread_application_password.argocd.value
  sensitive = true
}

# ---------------------------------------------------------------
# Crossplane
# ---------------------------------------------------------------
resource "azuread_application" "crossplane" {
  display_name     = "Crossplane"
  sign_in_audience = "AzureADMyOrg"

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
