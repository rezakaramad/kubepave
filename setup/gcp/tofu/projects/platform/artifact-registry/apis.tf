#----------------------------------------------------------------
# Project Service APIs
#----------------------------------------------------------------

# Enable Artifact Registry
resource "google_project_service" "artifactregistry" {
  project            = local.project_id
  service            = "artifactregistry.googleapis.com"
}
