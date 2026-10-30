#----------------------------------------------------------------
# Project Service APIs
#----------------------------------------------------------------

# Enables Compute Engine API (required for VPCs, subnets, and static IPs)
resource "google_project_service" "compute" {
  project = google_project.dns.id
  service = "compute.googleapis.com"

  disable_on_destroy = false
}

# Enable Cloud DNS
resource "google_project_service" "dns" {
  project            = google_project.dns.id
  service            = "dns.googleapis.com"
  disable_on_destroy = false
}
