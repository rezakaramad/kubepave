#----------------------------------------------------------------
# Organization policies
#----------------------------------------------------------------

# Prevents GCP from automatically creating a default VPC in new projects
resource "google_org_policy_policy" "skip_default_network_creation" {
  name   = "organizations/${local.organization_id}/policies/compute.skipDefaultNetworkCreation"
  parent = "organizations/${local.organization_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}
