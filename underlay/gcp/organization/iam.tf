#----------------------------------------------------------------
# Organization-level IAM bindings
#----------------------------------------------------------------

# Grant owner access to all projects under the org
resource "google_organization_iam_member" "owner" {
  org_id = local.organization_id
  role   = "roles/owner"
  member = "user:r.karamad@gmail.com"
}

# Required to enable Shared VPC host projects (compute.organizations.enableXpnHost permission).
# roles/owner does not include this — it must be granted explicitly at org or folder level.
resource "google_organization_iam_member" "xpn_admin" {
  org_id = local.organization_id
  role   = "roles/compute.xpnAdmin"
  member = "user:r.karamad@gmail.com"
}

#----------------------------------------------------------------
# Billing account IAM bindings
#----------------------------------------------------------------

# Allows tenant-provisioner to associate the billing account with new tenant GCP projects.
resource "google_billing_account_iam_member" "tenant_provisioner_billing_user" {
  billing_account_id = local.billing_account_id
  role               = "roles/billing.user"
  member             = "serviceAccount:tenant-provisioner@kara-mgmt.iam.gserviceaccount.com"
}

# Allows reading the IAM policy of a folder (resourcemanager.folders.getIamPolicy)
resource "google_organization_iam_custom_role" "folder_iam_viewer" {
  org_id      = local.organization_id
  role_id     = "folderIamViewer"
  title       = "Folder IAM Viewer"
  description = "Permission to view the IAM policy for a specific folder"
  stage       = "GA"

  permissions = [
    "resourcemanager.folders.getIamPolicy",
  ]
}
