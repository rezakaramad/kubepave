# External DNS
ExternalDNS allows you to control DNS records dynamically via Kubernetes resources in a DNS provider-agnostic way.
It is installed in all of our clusters to handle all DNS creation for our tenants.

Authentication to GCP is handled via Workload Identity Federation, removing the need for long-lived credentials.

The Google Service Account and required IAM roles are created using Config Connector as part of the Helm chart.
While the Helm chart is deployed on all clusters, the Service Account itself is provisioned only from the Management cluster.

All External DNS instances across the platform share this same Google Service Account.

- Google Service Account: `external-dns@jysk-platform.iam.gserviceaccount.com`

The service is responsible for creating DNS records for each tenant in our dedicated [Google Cloud DNS project.](https://console.cloud.google.com/net-services/dns/zones?referrer=search&project=peaceful-zebra-ya4m0o)

## DNS Record Management

External DNS monitors two types of sources for DNS entries:

1. **DNSEndpoint CRDs** - Creates wildcard DNS records during tenant provisioning (e.g., `*.pil.dev.jysk.tech`)
2. **Gateway HTTPRoutes** - Can create individual DNS records per service deployment (legacy, optional)

### Label Filtering

ExternalDNS is configured with `--label-filter=external-dns-create in (true)`, which means it only processes resources carrying the label `external-dns-create: "true"`.

**This filter applies to all sources** (both DNSEndpoint and HTTPRoute), enabling opt-in DNS record creation:

- **DNSEndpoint**: All wildcard DNSEndpoint resources are labeled with `external-dns-create: "true"` to ensure they are processed.
- **HTTPRoute**: Individual HTTPRoute resources must explicitly include `external-dns-create: "true"` in their labels to have DNS records created automatically. This keeps HTTPRoute-based DNS records opt-in while preserving the ability to create them when needed.

Example HTTPRoute with automatic DNS creation:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  labels:
    external-dns-create: "true"
spec:
  hostnames:
    - my-app.pil.dev.jysk.tech
  ...
```

Example HTTPRoute without automatic DNS (no DNS record will be created):
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: internal-app
spec:
  hostnames:
    - internal.pil.dev.jysk.tech
  ...
```

### Wildcard DNS Records

Each tenant gets a single wildcard DNS record created at provisioning time via a `DNSEndpoint` custom resource. This wildcard record points all tenant subdomains to the environment's load balancer IP, enabling instant deployment of new services without DNS propagation delays.



## Tenant Configuration

Each tenant is configured with its own `Gateway` resource in every environment and is assigned a unique subdomain, for example:

```
*.<subdomain>.<env>.jysk.tech
```

- `*` - Controlled by the developer team and can be set to any value they require.
- `<subdomain>` - A unique prefix determined during tenant provisioning (derived from `tenantShortName`). It consists of a 2-4 character string and cannot be changed.
- `<env>` - Identifies the environment in which the application is running. Possible values are `dev`, `test`, or `prod`.

The unique tenant subdomain ensures isolation by preventing naming collisions between tenants and gives developers full flexibility in hostname selection.

## Links
- [ExernalDNS Helm Chart](https://github.com/jysk-dev/platform-hub/tree/main/kubernetes/charts/external-dns)
- [ExternalDNS Docs](https://kubernetes-sigs.github.io/external-dns/latest/)
