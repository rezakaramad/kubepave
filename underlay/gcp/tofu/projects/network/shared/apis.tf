#----------------------------------------------------------------
# Project Service APIs
#----------------------------------------------------------------

# Enables Compute Engine API (required for VPCs, subnets, and static IPs)
resource "google_project_service" "compute" {
  project = google_project.kara_shared.id
  service = "compute.googleapis.com"

  disable_on_destroy = false
}
