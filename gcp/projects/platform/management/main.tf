#----------------------------------------------------------------
# Locals
#----------------------------------------------------------------

locals {
  project_id           = "kara-mgmt"
  project_display_name = "Platform Management"
  parent_folder_id = {
    "platform" = "177507122742"
  }
  billing_account_id = "01AB18-BBE5BC-76F96B"
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
    bucket = "management-tfstate-iyldur"
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

resource "google_project" "kara_mgmt" {
  project_id          = local.project_id
  name                = local.project_display_name
  folder_id           = local.parent_folder_id.platform
  billing_account     = local.billing_account_id
  labels              = local.labels
  auto_create_network = false
  deletion_policy     = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }
}

#----------------------------------------------------------------
# Tenant folder
#----------------------------------------------------------------

resource "google_folder" "tenant_environments" {
  display_name = "Tenant Environments"
  parent       = "folders/${local.parent_folder_id.platform}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_folder" "tenant_workload" {
  display_name = "Workload"
  parent       = google_folder.tenant_environments.id

  lifecycle {
    prevent_destroy = true
  }
}


#----------------------------------------------------------------
# Workload Identity Pool
#---------------------------------------------------------------

# Logical container (namespace) for external identity providers
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github"
}

# The below resource registers GitHub Actions as an OIDC provider within the Workload Identity Pool created above.
# Trusts GitHub Actions OIDC tokens and maps their claims to GCP attributes
resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-workflows"
  display_name                       = "Github Workflows"
  description                        = "GitHub Actions identity pool provider for workflows"
  attribute_condition                = "assertion.repository_owner == 'r-karamad'"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.actor"            = "assertion.actor"
    "attribute.aud"              = "assertion.aud"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
  }

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}
