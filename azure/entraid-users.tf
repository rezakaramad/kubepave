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

  lifecycle {
    # The Terraform identity IS this guest user — attempting to delete/recreate
    # the invitation fails with "cannot delete itself". Ignore all changes after
    # the initial creation.
    ignore_changes = all
  }
}

# The r.karamad@gmail.com guest is a platform admin via group membership: it
# inherits every app's admin role from the platform-admins group assignment
# (entraid-apps.tf), so no direct per-app assignment is needed.
resource "azuread_group_member" "reza_personal_platform_admin" {
  group_object_id  = azuread_group.platform_admins.object_id
  member_object_id = azuread_invitation.reza_personal.user_id
}
