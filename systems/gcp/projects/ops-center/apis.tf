#----------------------------------------------------------------
# Project Service APIs
#----------------------------------------------------------------

# Required for managing billing account IAM policies via Tofu
resource "google_project_service" "cloudbilling" {
  project            = local.project_id
  service            = "cloudbilling.googleapis.com"
  disable_on_destroy = false
}
