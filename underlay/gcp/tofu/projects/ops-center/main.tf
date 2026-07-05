################################################################
# Locals
################################################################

locals {
  buckets = [
    # Add a new bucket here ...
    "organization-tfstate",
    "gke-workload-tfstate",
    "gke-management-tfstate",
    "dns-tfstate",
    "shared-network-tfstate",
    "management-tfstate",
  ]
  project_id = "ops-center-501315"
  region     = "europe-west3"
}

################################################################
# Configuration/Providers
################################################################

terraform {
  backend "gcs" {
    bucket = "tfstate-zeus"
    prefix = "default"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }
}

provider "google" {
  project = local.project_id
  region  = local.region
}


################################################################
# Cloud Storage Buckets
################################################################

resource "random_string" "suffixes" {
  for_each = toset(local.buckets)
  length   = 6
  upper    = false
  special  = false
}

resource "google_storage_bucket" "buckets" {
  for_each      = toset(local.buckets)
  name          = "${each.value}-${random_string.suffixes[each.key].result}"
  location      = local.region
  force_destroy = true
  storage_class = "STANDARD"
  versioning {
    enabled = true
  }
  labels = {
    purpose = "bootstrap"
  }
  soft_delete_policy {
    retention_duration_seconds = 60 * 24 * 60 * 60
  }
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      with_state         = "ARCHIVED"
      num_newer_versions = 3
    }
  }
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      days_since_noncurrent_time = 7
    }
  }
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
}

################################################################
# Outputs
################################################################

output "buckets" {
  description = "All GCS buckets created by this module"
  value       = sort([for b in google_storage_bucket.buckets : b.name])
}
