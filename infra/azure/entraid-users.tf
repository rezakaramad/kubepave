# ---------------------------------------------------------------
# Entra Users
# ---------------------------------------------------------------
resource "random_password" "reza_initial" {
  length           = 16
  special          = true
  override_special = "!#$%&*-_=+<>?"
}

resource "azuread_user" "reza" {
  user_principal_name   = "reza@rkaramadgmail.onmicrosoft.com"
  display_name          = "Reza Karamad"
  mail_nickname         = "reza"
  password              = random_password.reza_initial.result
  force_password_change = true
}

resource "azuread_group_member" "reza_platform_admin" {
  group_object_id  = azuread_group.platform_admins.object_id
  member_object_id = azuread_user.reza.object_id
}

# ---------------------------------------------------------------
# External / personal identity (r.karamad@gmail.com)
# Invited as a guest so login via personal Google account works.
# ---------------------------------------------------------------
resource "azuread_invitation" "reza_personal" {
  user_email_address = "r.karamad@gmail.com"
  redirect_url       = "https://argocd.gcp.talktorubberduck.dev"

  message {
    additional_recipients = []
  }
}

resource "azuread_app_role_assignment" "argocd_personal_admin" {
  app_role_id         = azuread_application_app_role.argocd_admin.role_id
  principal_object_id = azuread_invitation.reza_personal.user_id
  resource_object_id  = azuread_service_principal.argocd.object_id
}
