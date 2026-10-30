################################################################
#                           Locales                            #
################################################################

locals {
  project_id           = "kara-dns"
  project_display_name = "DNS Management"
  parent_folder_id = {
    "network" = "20321694990"
  }
  billing_account_id = "01AB18-BBE5BC-76F96B"
  region             = "europe-west3"
  labels = {
    managed-by-tofu = "true"
  }

  tfstate_project_id = "ops-center-501315"
}

#----------------------------------------------------------------
# Configuration/Providers
#----------------------------------------------------------------

terraform {
  backend "gcs" {
    bucket = "dns-tfstate-5eoajk"
    prefix = "default"

  }
  required_version = ">= v1.10.3"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.36.0"
    }
  }
}

provider "google" {
  project = local.project_id
  region  = local.region
}

#----------------------------------------------------------------
# Project
#----------------------------------------------------------------

resource "google_project" "dns" {
  project_id          = local.project_id
  name                = local.project_display_name
  folder_id           = local.parent_folder_id.network
  billing_account     = local.billing_account_id
  labels              = local.labels
  auto_create_network = false
  deletion_policy     = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }
}
