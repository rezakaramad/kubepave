################################################################
#                           Locals                             #
################################################################

locals {
  organization_id    = "410359545724"
  billing_account_id = "01AB18-BBE5BC-76F96B"
  region             = "europe-west3"
}

#----------------------------------------------------------------
# Configuration/Providers
#----------------------------------------------------------------

terraform {
  backend "gcs" {
    bucket = "organization-tfstate-tasrrd"
    prefix = "tfstate"
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
  region                = local.region
  user_project_override = true
  billing_project       = "ops-center-501315"
}
