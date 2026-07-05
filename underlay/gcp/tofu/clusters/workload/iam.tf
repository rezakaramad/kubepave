#---------------------------------------------------------------
# Node pool service account + policy bindings
#---------------------------------------------------------------

# Why not use the default Compute service account?
# The default <project-number>-compute@developer.gserviceaccount.com has Editor on the project which is way too broad.
# A custom service account with specific roles follows least-privilege.
# List of permissions granted:
# roles/container.defaultNodeServiceAccount (includes logging, monitoring, metadata writer)
# roles/artifactregistry.reader

# Creates a dedicated GCP service account for the GKE node pool,
# grants it the necessary permissions it needs to run nodes as a service account.
resource "google_service_account" "compute" {
  account_id   = local.cluster_name
  display_name = "Compute Engine Service Account for ${local.cluster_name}"
}

# Grants the GKE node pool service account the permission to read container images in Artifact Registry.
resource "google_project_iam_member" "artifact_registry_reader" {
  project = local.project_ids.platform_management
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.compute.email}"
}

# Required by GKE for logging, monitoring, and HPA to function properly on custom node SAs.
resource "google_project_iam_member" "default_node_service_account" {
  project = local.project_ids.platform_management
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.compute.email}"
}
