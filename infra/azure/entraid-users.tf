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
