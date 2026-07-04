#----------------------------------------------------------------
# Github - Management Repository 'kubepave'
#----------------------------------------------------------------

# This service account is used by the Github pipeline in 'kubepave' repository
# to authenticate and operate in Google Cloud.
resource "google_service_account" "github_kubepave" {
  account_id   = "github-kubepave"
  display_name = "Github - Kubepave"
  description  = "Used by github.com/r-karamad/kubepave pipeline workflows"
}

#----------------------------------------------------------------
# Workload Identitiy Permissions 
#----------------------------------------------------------------

data "google_iam_policy" "kubepave_workload_identity" {
  binding {
    role = "roles/iam.workloadIdentityUser"

    members = [
      "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/r-karamad/kubepave"
    ]
  }
}

# Only GitHub Actions workflows from the r-karamad/kubepave repository can impersonate github-kubepave.
# This resource is authoritative. This means that roles added from other sources
# eg. manually added in WebUI, will get removed when ever this terraform project is executed
resource "google_service_account_iam_policy" "kubepave_iam" {
  service_account_id = google_service_account.github_kubepave.name
  policy_data        = data.google_iam_policy.kubepave_workload_identity.policy_data
}

#----------------------------------------------------------------
# Folder permissions
#----------------------------------------------------------------

# Grant the github-kubepave SA access to list/view the folder and projects
resource "google_folder_iam_member" "kubepave_folder_viewer" {
  folder = local.parent_folder_id.platform
  role   = "roles/resourcemanager.folderViewer"
  member = "serviceAccount:${google_service_account.github_kubepave.email}"
}

# Grant the github-kubepave SA access to view IAM policies in the 'platform' folder
resource "google_folder_iam_member" "kubepave_folder_iam_viewer" {
  folder = local.parent_folder_id.platform
  role   = "organizations/410359545724/roles/folderIamViewer"
  member = "serviceAccount:${google_service_account.github_kubepave.email}"
}

# Grant the SA access to view resources (GKE, GCS, etc.) in the 'platform' folder
resource "google_folder_iam_member" "kubepave_viewer" {
  folder = local.parent_folder_id.platform
  role   = "roles/viewer"
  member = "serviceAccount:${google_service_account.github_kubepave.email}"
}

#----------------------------------------------------------------
# Tofu state project permissions
#----------------------------------------------------------------
# Grant the github-kubepave SA access to read/write the Terraform state bucket in the 'platform' project
resource "google_project_iam_member" "kubepave_object_user" {
  project = local.tfstate_project_id
  role    = "roles/storage.objectUser"
  member  = "serviceAccount:${google_service_account.github_kubepave.email}"
}

# Grant the github-kubepave SA access to read Secret Manager secrets in the tfstate project (e.g. backend credentials)
resource "google_project_iam_member" "tf_state_secret_accessor" {
  project = local.tfstate_project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.github_kubepave.email}"
}
