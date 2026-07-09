#----------------------------------------------------------------
# Static IP for GKE load balancers
#----------------------------------------------------------------

# resource "google_compute_address" "management_cluster" {
#   name   = "management-cluster"
#   region = "europe-west3"

#   depends_on = [google_project_service.compute]
# }

# resource "google_compute_address" "workload_cluster" {
#   name   = "workload-cluster"
#   region = "europe-west3"

#   depends_on = [google_project_service.compute]
# }

# output "management_cluster_ip" {
#   description = "Static IP for the management cluster load balancer"
#   value       = google_compute_address.management_cluster.address
# }

# output "workload_cluster_ip" {
#   description = "Static IP for the workload cluster load balancer"
#   value       = google_compute_address.workload_cluster.address
# }
