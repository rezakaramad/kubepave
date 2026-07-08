#----------------------------------------------------------------
# Locals
#----------------------------------------------------------------
locals {
  cluster_name        = "gke-workload"
  region              = "europe-west3"

  # Single zone for the cluster and node pool. A zonal cluster has one control-plane
  # replica and places nodes in this zone only.
  zone                = "europe-west3-a"

  network_name        = "workload-cluster"
  network_subnet_name = "workload-default"
  project_ids = {
    "platform_management" = "kara-mgmt",
    "artifact_registry"   = "ops-center-501315"
  }
}

#----------------------------------------------------------------
# Configuration / providers
#----------------------------------------------------------------

terraform {
  backend "gcs" {
    bucket = "gke-workload-tfstate-8h8fzf"
    prefix = "default"

  }
  required_version = ">= v1.10.3"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.12.0"
    }
  }
}

provider "google" {
  project = local.project_ids.platform_management
  region  = local.region
}

#---------------------------------------------------------------
# Workload GKE cluster
#---------------------------------------------------------------

# PubSub for GKE notifications
resource "google_pubsub_topic" "notifications" {
  name = "${local.cluster_name}-notifications"
}

resource "google_container_cluster" "workload" {
  deletion_protection = false
  name                = local.cluster_name
  location            = local.zone
  network             = local.network_name
  subnetwork          = local.network_subnet_name

  release_channel {
    channel = "REGULAR"
  }

  # The below settings enables Dataplane v2 (Cillium)
  datapath_provider = "ADVANCED_DATAPATH"

  # Enable CiliumClusterWideNetworkPolicy
  enable_cilium_clusterwide_network_policy = true

  # Enable FQDN Network Policies
  enable_fqdn_network_policy = true

  # In route-based mode, pods get IPs that aren't routable within the VPC, and GKE creates static routes like
  # "to reach 10.0.1.0/24 go to node X". This is the legacy mode.
  # In VPC-native mode, each node gets a secondary IP range allocated from the VPC's subnet.
  # Pods get IPs from that secondary range, which are real VPC IPs and are directly routable within the VPC.
  # Enables VPC-native mode (alias IP ranges), required for Dataplane V2 (Cilium).
  # Pod and service IPs are real VPC ranges, directly routable within the VPC without extra routes.
  ip_allocation_policy {}

  # Disable the legacy GKE NetworkPolicy controller — Cilium (Dataplane V2) handles all network policy enforcement.
  network_policy {
    enabled = false
  }

  # Enables Workload Identity on the cluster; it allows Kubernetes service accounts to impersonate GCP service accounts
  # without needing to mount any keys or credentials in pods.
  workload_identity_config {
    workload_pool = "${local.project_ids.platform_management}.svc.id.goog"
  }

  # GKE publishes notifications to Pub/Sub, providing you with a channel to receive relevant information from GKE about your clusters.
  notification_config {
    pubsub {
      enabled = true
      topic   = google_pubsub_topic.notifications.id
    }
  }

  # Enable the cost allocation feature.
  # It breaks down cluster costs by namespace and label in the GCP billing reports, 
  # so you can see how much each workload/tenant costs.
  cost_management_config {
    enabled = true
  }

  # Enables the Kubernetes Gateway API on the cluster
  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  # Enable DNS-based control plane access and disable IP based.
  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
    ip_endpoints_config {
      enabled = false
    }
  }

  # Remove the default node pool, as we will create a custom node pool.
  remove_default_node_pool = true

  # GKE requires at least 1 node to be present during cluster bootstrap.
  initial_node_count = 1

  # GKE requires at least one node to exist during cluster creation, even when
  # remove_default_node_pool = true. The default pool is provisioned momentarily
  # and then immediately deleted once the cluster is ready.
  #
  # Problem: on a free-tier account, the SSD quota in europe-west3 is only 250 GB.
  # GKE's default disk is 100 GB SSD per node, which can push the quota over the limit
  # during that brief creation window — causing the apply to fail.
  #
  # Fix: override node_config here to use pd-standard (HDD) at 32 GB so the temporary
  # default pool never touches the SSD quota.
  #
  # Why ignore_changes: node_config is a ForceNew field on google_container_cluster.
  # Without ignore_changes, subsequent tofu plans would diff this block against GKE's
  # API response (which returns many computed defaults not present in our config) and
  # plan a full cluster replacement. Since the default pool is already gone, ignoring
  # node_config on the cluster resource after creation is safe — it has no effect.
  node_config {
    disk_type    = "pd-standard"
    disk_size_gb = 32
  }

  lifecycle {
    ignore_changes = [node_config]
  }
}

#---------------------------------------------------------------
# Node pool
#---------------------------------------------------------------

resource "google_container_node_pool" "primary" {
  cluster     = google_container_cluster.workload.name
  location    = local.zone
  name_prefix = "spot-"
  node_count  = 2

  autoscaling {
    min_node_count  = 1
    max_node_count  = 2
    location_policy = "BALANCED"
  }

  upgrade_settings {
    strategy        = "SURGE"
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    # Spot VMs are the cheapest option (up to ~91% discount), at the cost of possible preemption.
    spot         = true
    machine_type = "e2-standard-2"
    # Reduce boot disk to 32 GB to stay within SSD quota (default is 100 GB).
    disk_size_gb = 32
    disk_type    = "pd-standard"

    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    service_account = google_service_account.compute.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}
