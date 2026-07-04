#----------------------------------------------------------------
# Organization-level IAM bindings
#----------------------------------------------------------------

# Grant owner access to all projects under the org
resource "google_organization_iam_member" "owner" {
  org_id = local.organization_id
  role   = "roles/owner"
  member = "user:r.karamad@gmail.com"
}

#----------------------------------------------------------------
# Organization-level custom IAM roles
#----------------------------------------------------------------

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
