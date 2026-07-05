# Allows tenant-provisioner (Config Connector) to attach tenant projects as
# Shared VPC service projects. Must be granted at org level.
resource "google_folder_iam_member" "tenant_provisioner_xpn_admin" {
  folder = "folders/20321694990"
  role   = "roles/compute.xpnAdmin"
  member = "serviceAccount:tenant-provisioner@kara-mgmt.iam.gserviceaccount.com"
}
