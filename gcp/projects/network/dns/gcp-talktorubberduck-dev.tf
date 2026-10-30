#----------------------------------------------------------------
# DNS Zone :: gcp.talktorubberduck.dev
#----------------------------------------------------------------

resource "google_dns_managed_zone" "gcp_talktorubberduck_dev" {
  name        = "gcp-talktorubberduck-dev"
  dns_name    = "gcp.talktorubberduck.dev."
  description = "Authoritative public DNS zone for gcp.talktorubberduck.dev domain."
  dnssec_config {
    state = "on"
  }
}

#---------------------------------------------------------------
# DNS Zone :: wl.gcp.talktorubberduck.dev
#---------------------------------------------------------------

resource "google_dns_managed_zone" "wl_gcp_talktorubberduck_dev" {
  name        = "wl-gcp-talktorubberduck-dev"
  dns_name    = "wl.gcp.talktorubberduck.dev."
  description = "Authoritative public DNS zone for wl.gcp.talktorubberduck.dev domain."
  dnssec_config {
    state = "on"
  }
}

# Delegate wl.gcp.talktorubberduck.dev to its zone by adding NS records in the parent zone
resource "google_dns_record_set" "wl_gcp_talktorubberduck_dev_ns" {
  managed_zone = google_dns_managed_zone.gcp_talktorubberduck_dev.name
  type         = "NS"
  ttl          = 300
  name         = google_dns_managed_zone.wl_gcp_talktorubberduck_dev.dns_name
  rrdatas      = google_dns_managed_zone.wl_gcp_talktorubberduck_dev.name_servers
}
