#----------------------------------------------------------------
# Management cluster VPC
#----------------------------------------------------------------

resource "google_compute_network" "management" {
  name                    = "management-default"
  auto_create_subnetworks = false

  depends_on = [google_project_service.compute]
}

resource "google_compute_subnetwork" "management_default" {
  name          = "management-default"
  ip_cidr_range = "10.233.48.0/20"
  region        = local.region
  network       = google_compute_network.management.id
}

#---------------------------------------------------------------
# Workload cluster VPC
#----------------------------------------------------------------

resource "google_compute_network" "workload" {
  name                    = "workload-cluster"
  auto_create_subnetworks = false

  depends_on = [google_project_service.compute]
}

resource "google_compute_subnetwork" "workload_default" {
  name          = "workload-default"
  ip_cidr_range = "10.233.0.0/20"
  region        = local.region
  network       = google_compute_network.workload.id
}
