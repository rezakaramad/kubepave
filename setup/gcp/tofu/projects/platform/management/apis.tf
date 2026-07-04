#----------------------------------------------------------------
# Project Service APIs
#----------------------------------------------------------------

# Enable GKE
resource "google_project_service" "kara_mgmt_gke" {
  project = google_project.kara_mgmt.id
  service = "container.googleapis.com"

  disable_on_destroy = false
}

# Enable Secret Manager
resource "google_project_service" "secretmanager" {
  project = google_project.kara_mgmt.id
  service = "secretmanager.googleapis.com"

  disable_on_destroy = false
}

# Enable Billing API
resource "google_project_service" "billing" {
  project = google_project.kara_mgmt.id
  service = "cloudbilling.googleapis.com"

  disable_on_destroy = false
}

# Enables the SQL Admin API
resource "google_project_service" "sqladmin" {
  project = google_project.kara_mgmt.id
  service = "sqladmin.googleapis.com"

  disable_on_destroy = false
}

# Enables Network Connectivity API
resource "google_project_service" "networkconnectivity" {
  project = google_project.kara_mgmt.id
  service = "networkconnectivity.googleapis.com"

  disable_on_destroy = false
}

# Enables Compute Engine API (required for VPCs, subnets, and static IPs)
resource "google_project_service" "compute" {
  project = google_project.kara_mgmt.id
  service = "compute.googleapis.com"

  disable_on_destroy = false
}
