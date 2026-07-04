# Grants 'resources-provisioner' service account the Owner role 'kara-dns' project.
# This service accounts is used by ExternalDNS and Cert-Manager to create DNS records.
resource "google_project_iam_member" "platform_provisioner_dns_user" {
  project = local.project_id
  role    = "roles/owner"
  member  = "serviceAccount:platform-provisioner@kara-mgmt.iam.gserviceaccount.com"
}

#----------------------------------------------------------------
# dns.user custom role
#---------------------------------------------------------------
# This custom role grants Cert-Manager and ExternalDNS the minimum permissions
# required to create DNS records in the 'kara-dns' project.

resource "google_project_iam_custom_role" "dns_user" {
  role_id     = "dns.user"
  title       = "DNS User"
  description = "A limited writer role for DNS users."
  permissions = [
    "dns.resourceRecordSets.create",
    "dns.resourceRecordSets.delete",
    "dns.resourceRecordSets.get",
    "dns.resourceRecordSets.list",
    "dns.resourceRecordSets.update",
    "dns.changes.create",
    "dns.changes.get",
    "dns.changes.list",
    "dns.managedZones.list",
  ]
}
