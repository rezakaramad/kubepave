# Cert Manager

Cert Manager is installed on all Platform clusters, with a ClusterIssuer configured to perform DNS validation using Google Cloud DNS in the DNS Management Project.

Authentication to GCP is handled via Workload Identity Federation, removing the need for long-lived credentials.

The Google Service Account and required IAM roles are created using Config Connector as part of the Helm chart.
While the Helm chart is deployed on all clusters, the Service Account itself is provisioned only from the Management cluster.

All Cert Manager instances across the platform share this same Service Account.

- Google Service Account: `cert-manager@kara-mgmt.iam.gserviceaccount.com`

## How it works

**1. The request: DNS-01 challenge**

When cert-manager requests a certificate from Let's Encrypt, LE needs to verify you own the domain. With dns01, cert-manager must create a temporary TXT record (e.g. _acme-challenge.yourdomain.com) in Cloud DNS to prove ownership. Once verified, LE issues the cert and cert-manager deletes the TXT record.

**2. The permission chain (Workload Identity)**
```
cert-manager Pod (KSA)
  → impersonates → cert-manager GCP SA (GSA)
    → has → dns.user role on kara-dns project
      → can create/delete TXT records in Cloud DNS
```
Step by step:

**Pod → GSA** via Workload Identity:
- The cert-manager Kubernetes Service Account (KSA) has annotation iam.gke.io/gcp-service-account: cert-manager@kara-mgmt.iam.gserviceaccount.com
- The GSA has roles/iam.workloadIdentityUser granted to kara-mgmt.svc.id.goog[platform-system/cert-manager] — this is the IAMPartialPolicy on the SA itself
- GKE's token projection lets the pod exchange its KSA token for a GCP access token scoped to the GSA — no key files needed

**GSA → Cloud DNS** via project IAM:
- The GSA has `projects/kara-dns/roles/dns.user` on the `kara-dns` project (the second IAMPartialPolicy targeting the project)
`dns.user` allows creating/deleting DNS records in any zone in that project

**3. ClusterIssuer wires it together**

```
solvers:
- dns01:
    cloudDNS:
      project: kara-dns   # tells cert-manager which GCP project hosts the zone
```

cert-manager's controller uses the pod's Workload Identity credentials (which are automatically available via the metadata server) to call the Cloud DNS API in `kara-dns` and manage challenge records.

**4. `createIamServiceAccount: false`**

The GSA and IAM bindings are only created once (controlled by this flag) — since the same `cert-manager@kara-mgmt` GSA is shared across all clusters. Multiple clusters' cert-manager pods can all impersonate the same GSA; the Workload Identity binding allows any `cert-manager` KSA from `kara-mgmt`'s identity pool.


## Links
- [Cert Manager Docs](https://cert-manager.io/docs/)
