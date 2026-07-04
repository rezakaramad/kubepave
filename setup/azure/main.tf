# ---------------------------------------------------------------
# Terraform configuration for Azure AD resources for Argo CD
# ---------------------------------------------------------------
terraform {
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "3.8.0"
    }
  }
}

provider "azuread" {}
