#----------------------------------------------------------------
# Locals
#----------------------------------------------------------------

locals {
  project_id         = "ops-center-501315"
  region             = "europe-west3"
  labels = {
    managed-by-tofu = "true"
  }

  tfstate_project_id = "ops-center-501315"
}

#----------------------------------------------------------------
# Configuration / providers
#----------------------------------------------------------------

terraform {
  backend "gcs" {
    bucket = "artifact-registry-tfstate-f19yee"
    prefix = "default"

  }
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.1.0"
    }
  }
}

provider "google" {
  project = local.project_id
  region  = local.region
}
