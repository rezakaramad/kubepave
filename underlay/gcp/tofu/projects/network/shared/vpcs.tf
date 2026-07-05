
#---------------------------------------------------------------
# Shared VPC host project
#----------------------------------------------------------------

# Enables this project as a Shared VPC host project.
# Service projects (management, workload clusters) will be attached to it.
resource "google_compute_shared_vpc_host_project" "host" {
  project    = google_project.kara_shared.project_id
  depends_on = [google_project_service.compute]
}

#---------------------------------------------------------------
# Workload cluster VPC
#----------------------------------------------------------------

resource "google_compute_network" "workload" {
  name                    = "workload-cluster"
  auto_create_subnetworks = false

  depends_on = [google_compute_shared_vpc_host_project.host]
}

resource "google_compute_subnetwork" "workload_default" {
  name          = "workload-default"
  ip_cidr_range = "10.133.0.0/20"
  region        = local.region
  network       = google_compute_network.workload.id
}
