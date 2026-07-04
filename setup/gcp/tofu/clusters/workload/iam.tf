#---------------------------------------------------------------
# Node pool service account + policy bindings
#---------------------------------------------------------------

# Why not use the default Compute service account?
# The default <project-number>-compute@developer.gserviceaccount.com has Editor on the project which is way too broad.
# A custom service account with specific roles follows least-privilege.
# List of permissions granted:
# roles/logging.logWriter
# roles/monitoring.metricWriter
# roles/monitoring.viewer
# roles/stackdriver.resourceMetadata.writer
# roles/artifactregistry.reader

# Creates a dedicated GCP service account for the GKE node pool,
# grants it the necessary permissions it needs to run nodes as a service account.
resource "google_service_account" "compute" {
  account_id   = local.cluster_name
  display_name = "Compute Engine Service Account for ${local.cluster_name}"
}

# Grants the GKE node pool service account the permission to write logs to Cloud Logging.
resource "google_project_iam_member" "log_writer" {
  project = local.project_ids.platform_management
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.compute.email}"
}

# Grants the GKE node pool service account the permission to write metrics to Cloud Monitoring.
resource "google_project_iam_member" "metric_writer" {
  project = local.project_ids.platform_management
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.compute.email}"
}

# Grants the GKE node pool service account the permission to view monitoring data.
resource "google_project_iam_member" "monitoring_viewer" {
  project = local.project_ids.platform_management
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.compute.email}"
}

# Grants the GKE node pool service account the permission to write resource metadata to Stackdriver/Cloud Monitoring.
resource "google_project_iam_member" "metadata_writer" {
  project = local.project_ids.platform_management
  role    = "roles/stackdriver.resourceMetadata.writer"
  member  = "serviceAccount:${google_service_account.compute.email}"
}

# Grants the GKE node pool service account the permission to read container images in Artifact Registry.
resource "google_project_iam_member" "artifact_registry_reader" {
  project = local.project_ids.platform_management
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.compute.email}"
}
