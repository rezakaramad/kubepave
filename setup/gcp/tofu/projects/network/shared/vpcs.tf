
#---------------------------------------------------------------
# Workload cluster shared VPC
#----------------------------------------------------------------

resource "google_compute_network" "workload" {
  name                    = "workload-cluster"
  auto_create_subnetworks = false

  depends_on = [google_project_service.compute]
}

resource "google_compute_subnetwork" "workload_default" {
  name          = "workload-default"
  ip_cidr_range = "10.133.0.0/20"
  region        = local.region
  network       = google_compute_network.workload.id
}
