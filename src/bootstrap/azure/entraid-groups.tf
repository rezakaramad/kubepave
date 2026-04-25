# ---------------------------------------------------------------
# Entra Groups
# ---------------------------------------------------------------
resource "azuread_group" "platform_admins" {
  display_name     = "platform-admins"
  security_enabled = true
  description = "Platform administrators with full access to all resources and permissions in the platform."
}

resource "azuread_group" "platform_viewers" {
  display_name     = "platform-viewers"
  security_enabled = true
  description = "Platform viewers with read-only access to all resources in the platform."
}

output "platform_admins_group_id" {
  value = azuread_group.platform_admins.object_id
}

output "platform_viewers_group_id" {
  value = azuread_group.platform_viewers.object_id
}
