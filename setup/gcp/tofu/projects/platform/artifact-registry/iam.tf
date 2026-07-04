# This policy binding gives the 'tenant-provisioner' service account 
# the 'artifactregistry.repoAdmin' role on the Artifact Registry project. 
# That service account is used to provision tenant GCP resources
# including tenant repo in Artifact Registry.
resource "google_project_iam_member" "kara_artifacts_admin" {
  project = local.project_id
  role    = "roles/artifactregistry.admin"
  member  = "serviceAccount:tenant-provisioner@kara-mgmt.iam.gserviceaccount.com"
}

# This gives the 'tenant-provisioner' permission to set roles on kara-artifacts project
resource "google_project_iam_member" "kara_artifacts_iam_admin" {
  project = local.project_id
  role    = "roles/resourcemanager.projectIamAdmin"
  member  = "serviceAccount:tenant-provisioner@kara-mgmt.iam.gserviceaccount.com"
}
