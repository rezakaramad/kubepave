# Allows tenant-provisioner (Config Connector) to attach tenant projects as
# Shared VPC service projects. Must be granted at org level.
resource "google_folder_iam_member" "tenant_provisioner_xpn_admin" {
  folder = "folders/20321694990"
  role   = "roles/compute.xpnAdmin"
  member = "serviceAccount:tenant-provisioner@kara-mgmt.iam.gserviceaccount.com"
}

# Allows tenant-provisioner to enable Shared VPC on tenant projects
# (compute.organizations.enableXpnResource) in the Tenant Environments folder.
resource "google_folder_iam_member" "tenant_provisioner_xpn_admin_tenant_envs" {
  folder = "folders/377346212838"
  role   = "roles/compute.xpnAdmin"
  member = "serviceAccount:tenant-provisioner@kara-mgmt.iam.gserviceaccount.com"
}
