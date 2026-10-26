# 1. The architecture we're designing for

We assumed in our setup,
- Each environment has a K8s cluster containing a central `observability` namespace.
- Tenant application namespaces are dynamically created in that cluster.
- OpenTelemetry Collectors live centrally in `observability`, not inside each tenant namespace.
- The whole system must be deployable and managed using Argo CD.
- Tenants are not allowed to manipulate their namespace's metadata.
- Each tenant namespace has `platform.rezakara.demo/tenant` label.

## Proposed architecture

```text
                    KUBERNETES CLUSTER

   ┌─────────────────────────┐  ┌─────────────────────────┐
   │       Namespace A       │  │       Namespace B       │
   │      tenant: acme       │  │      tenant: globex     │
   │ Applications + telemetry│  │ Applications + telemetry│
   └────────────┬────────────┘  └────────────┬────────────┘
                │                            │
                └────────────┬───────────────┘
                             │
                    OTLP / telemetry
                             │
                             ▼
   ┌──────────────────────────────────────────────────────┐
   │           Central observability namespace            │
   │                                                      │
   │                   OTel Collectors                    │
   │             Receive logs, metrics, traces            │
   │                          │                           │
   │                          ▼                           │
   │             Kubernetes metadata enrichment           │
   │          Source pod → namespace → tenant label       │
   │                          │                           │
   │                          ▼                           │
   │                  Tenant-aware export                 │
   │          Map trusted label to LGTM tenant ID         │
   └──────────────────────────┬───────────────────────────┘
                              │
                              ▼
       ┌──────────────────────┬──────────────────────┐
       ▼                      ▼                      ▼
   ┌──────────┐           ┌──────────┐           ┌──────────┐
   │   Loki   │           │  Mimir   │           │  Tempo   │
   │  Native  │           │  Native  │           │  Native  │
   │ tenancy  │           │ tenancy  │           │ tenancy  │
   └────┬─────┘           └────┬─────┘           └────┬─────┘
        │                      │                      │
        └──────────────────────┼──────────────────────┘
                               │
              ┌────────────────┴────────────────┐
              ▼                                 ▼
    ┌───────────────────┐             ┌───────────────────┐
    │                   │             │                   │
    │  Grafana (acme)   │             │ Grafana (globex)  │
    │                   │             │                   │
    │ Tenant-scoped data│             │ Tenant-scoped data│
    │ sources and access│             │ sources and access│
    └───────────────────┘             └───────────────────┘
```
### Namespace metadata as the single source of truth

We have, right now, something like:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: acme
  labels:
    platform.rezakara.demo/tenant: acme
```

The ideal flow is:

```text
Incoming telemetry (sent by tenant apps)
       │
       ▼
Identify source Kubernetes Pod
       │
       ▼
Retrieve owning Namespace
       │
       ▼
Read platform.rezakara.demo/tenant
       │
       ▼
Tenant ID = acme
       │
       ▼
Export to tenant acme in LGTM
```
OpenTelemetry's `k8sattributes` processor supports extracting labels from `namespace` objects, including the custom label you're using. [¹](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/k8sattributesprocessor/README.md)


**What could go wrong?**
Consider this malicious OTLP payload:
```yaml
resource:
  attributes:
    k8s.namespace.name: globex
    platform.tenant: globex
```

It is sent by an application actually running in namespace `acme`. If you blindly trust resource attributes supplied by applications, `Acme` could impersonate `Globex`.

A second problem occurs when an intermediate proxy or shared collector forwards telemetry. The central collector might see the proxy's IP address rather than the original workload's IP.

So, here are a few rules I'd stick to:
- The platform-owned trusted Collector should figure out which namespace the telemetry comes from by verifying the source pod, rather than blindly trusting the `k8s.namespace.name` attribute sent by the application.
- Any tenant-related attributes coming from applications should be **removed** or **overwritten** before they're used for routing.
- If we can't figure out which tenant the telemetry belongs to, it shouldn't end up in any customer's storage.
- Namespace labels should be protected so tenant users can't change, remove, or bypass them by deleting and recreating namespaces.
- Applications shouldn't be able to skip the trusted Collector and send telemetry directly to LGTM.

The general rule here is to **fail closed**. If we can't confidently identify the tenant, we should reject the telemetry instead of sending it to some default tenant.

**The tricky part: Setting `X-Scope-OrgID` dynamically**

Knowing which tenant the telemetry belongs to is one thing, but making sure Loki, Mimir, and Tempo store it under the right tenant is another.

All three use the `X-Scope-OrgID` header to identify the tenant. For example:
```text
X-Scope-OrgID: acme
```
The tricky part is that one OTel Collector can receive telemetry from different tenants. So, before sending anything to LGTM, it needs to separate the data by tenant and make sure each request has the correct `X-Scope-OrgID` header.

So, we need to make sure telemetry is grouped by tenant before exporting it, with the correct `X-Scope-OrgID` set for each request. Otherwise, we risk sending one tenant's data into another tenant's storage.

There are two ways we can handle this.

### Option A: Generated tenant-specific OTel pipelines

```text
                  Central OTel Collector
              Metadata enrichment + routing
                            │
                            ▼
             ┌──────────────┴──────────────┐
             │                             │
             ▼                             ▼
      Acme pipeline                 Globex pipeline
      Header: acme                  Header: globex
             │                             │
             └──────────────┬──────────────┘
                            │
                            ▼
                Shared Loki / Mimir / Tempo
```

Use the OpenTelemetry `routing` connector to direct telemetry into predeclared pipelines based on `platform.tenant`.

A simplified logs-only illustration:

```yaml
connectors:
  routing/tenant:
    table:
      - condition: resource.attributes["platform.tenant"] == "acme"
        pipelines: [logs/acme]

      - condition: resource.attributes["platform.tenant"] == "globex"
        pipelines: [logs/globex]

exporters:
  otlphttp/loki-acme:
    endpoint: http://loki-gateway/otlp
    headers:
      X-Scope-OrgID: acme

  otlphttp/loki-globex:
    endpoint: http://loki-gateway/otlp
    headers:
      X-Scope-OrgID: globex

service:
  pipelines:
    logs/input:
      receivers: [otlp]
      processors: [k8sattributes]
      exporters: [routing/tenant]

    logs/acme:
      receivers: [routing/tenant]
      exporters: [otlphttp/loki-acme]

    logs/globex:
      receivers: [routing/tenant]
      exporters: [otlphttp/loki-globex]
```

The routing connector checks the tenant label and sends logs to the right pipeline. Each pipeline then sets its own `X-Scope-OrgID` header before forwarding the logs to Loki.

How the components work together:
- `connectors` decide which pipeline should receive the logs based on platform.tenant.
- `exporters` send the logs to Loki with the correct `X-Scope-OrgID` header.
- `service.pipelines` connects the routing logic to the exporters.

```text
             logs/input pipeline
                     │
                     ▼
              routing/tenant
            (checks tenant label)
                     │
            ┌────────┴────────┐
            ▼                 ▼
        logs/acme         logs/globex
            │                 │
            ▼                 ▼
     otlphttp/loki-acme  otlphttp/loki-globex
            │                 │
            ▼                 ▼
     X-Scope-OrgID: acme  X-Scope-OrgID: globex
            │                 │
            └────────┬────────┘
                     ▼
                 Shared Loki
```

So the logic:
```text
Tenant attribute → Routing connector → Tenant pipeline → Exporter → Loki
```
But you might have noticed one limitation here: the pipelines and exporters need to be configured **ahead of time**. For example, if a new tenant called `initech` comes along, the Collector won't automatically create a new `logs/initech` pipeline. 

You'd need some automation to update the Collector configuration and then reload or roll out the changes.

This might be fine for a handful of tenants, but if you're dealing with lots of tenants and onboarding new ones regularly, it can quickly become hard to manage and doesn't scale very well.

### Option B: Generic OTel pipelines with a tenant-aware routing service

```text
                  Central OTel Collectors
                 Trusted Kubernetes enrichment
                One generic pipeline per signal
                              │
                              ▼
                 Tenant-aware OTLP gateway
             Split telemetry by trusted tenant
                  Set native tenant headers
                     Forward to backend
                              │
                              ▼
             ┌────────────────┼────────────────┐
             ▼                ▼                ▼
            Loki             Mimir            Tempo
```
The idea is to keep the OTel Collector configuration independent of the number of tenants.

For example:
```text
Namespace acme
      │ telemetry
      ▼
Platform-owned OTel Collectors (in observability namespace)
      │ add trusted platform.tenant=acme from the namespace label
      ▼
OTLP tenant gateway
      │
      ├── Split by tenant and signal
      ├── Header X-Scope-OrgID: acme
      └── Export to appropriate backend
```

When a namespace is created with the label:
```
platform.rezakara.demo/tenant: initech
```

there is no need to add an `initech` exporter or pipeline to the Collector.

The gateway resolves the tenant dynamically from the trusted, enriched telemetry.

**One thing to keep in mind** is that the gateway isn't something you get out of the box with the official OpenTelemetry Collector distributions. You either need to build it yourself or use an existing solution. ([See section 2: we use the new `partitioning` processor, which currently needs a custom-built collector image](#2-what-well-be-doing).)

OpenTelemetry does have a `headers_setter` extension that can set outgoing headers, but it works with request context or authentication attributes, not directly with arbitrary telemetry resource attributes.

Another important detail is that a single OTLP request can contain telemetry from multiple tenants. So, the gateway needs to separate that data first and make sure each tenant's telemetry gets the correct `X-Scope-OrgID` header before forwarding it to LGTM.

For a platform where tenants are created dynamically, I'd lean toward **Option B **in the long run, as long as you're comfortable maintaining a tenant-aware gateway or using an existing one.

# 2. What we'll be doing

We go with **Option B**, and the gateway turns out to need no custom code. The OpenTelemetry Collector contrib has a new `partitioning` processor (alpha) that splits a batch by an OTTL expression and puts the key into the request metadata. `headers_setter` can then read that metadata, which is the missing link described above.

```text
Tenant namespaces ──► Collectors (observability)     ──► Gateway collector            ──► Loki / Mimir / Tempo
                      k8sattributes: namespace label     partitioning by tenant.id        one tenant ID per request
                      → tenant.id, drop if missing       headers_setter: X-Scope-OrgID
```

**How it works**
- Collectors derive `tenant.id` from the `platform.rezakara.demo/tenant` namespace label, overwrite anything the app sent, and drop telemetry with no tenant (fail closed). Platform namespaces map explicitly to a `platform` tenant.
- The gateway is a central collector: `partitioning` splits by `tenant.id`, `headers_setter` sets `X-Scope-OrgID` from it, and the exporter batches per tenant (`sending_queue.batch.partition.metadata_keys`). Adding a tenant needs no collector change.
- Loki, Mimir and Tempo run with native multi-tenancy. Only the gateway may write to them, enforced with NetworkPolicy. Collectors authenticate to the gateway, and the **development** cluster reaches it through a Traefik route with authentication.
- Every tenant gets its own Grafana instance (a `Grafana` resource for the operator) with datasources that send only that tenant's `X-Scope-OrgID`. Users log in with Entra ID and the `roles` claim must carry the tenant name. Only Grafana can read from the backends. The shared Grafana stays for platform admins and reads all tenants. See "Why one Grafana per tenant" below.
- Each tenant gets one default dashboard, published from [`grafkit`](https://github.com/rezakaramad/grafkit) as an OCI artifact.

**Order of work**
1. Check the collector image includes the `partitioning` processor.
2. Prove the gateway on one signal (metrics) and one tenant.
3. Turn on tenancy in the backends and lock down write access.
4. Add the remaining signals.
5. Create a Grafana instance, datasources and SSO mapping per tenant.
6. Roll out the per-tenant default dashboard.

## Why one Grafana per tenant

The operator (v5.25) cannot manage Grafana organizations. Organizations, users and org membership have no CRDs, so datasources, dashboards and folders always land in the default org. We tested it: a `GrafanaDatasource` with `spec.datasource.orgId: 2` was reported as applied, but the datasource appeared in org 1 and org 2 stayed empty.

The request for `GrafanaOrganization`, `GrafanaUser` and `GrafanaOrganizationMember` resources is [grafana-operator#2895](https://github.com/grafana/grafana-operator/issues/2895). It was closed as not planned. The maintainers point to the earlier discussion in [#408](https://github.com/grafana/grafana-operator/issues/408) and recommend running multiple Grafana instances instead. They also mention a workaround for orgs: a separate `Grafana` resource whose `spec.client.headers` sets `X-Grafana-Org-Id`.

We chose one instance per tenant because it stays fully declarative and isolates tenants more strongly than orgs. Orgs would also be hard to undo: deleting one failed on Grafana 13.1.3 ("failed to delete dashboards for org"), which we hit while testing.

Costs: one pod, one route and one Entra redirect URI per tenant.

**How it is built**
- The `tenant-management` chart creates, per tenant and only when `grafana.enabled` is true: a `Grafana`, three datasources that send only that tenant's ID, an ExternalSecret for the Entra client and an HTTPRoute. The instance runs in `observability` and is served at `<tenant>.grafana.mgmt.rezakara.demo`.
- A dedicated Traefik gateway, `grafana-traefik` in `platform-system`, serves `*.grafana.mgmt.rezakara.demo` with its own wildcard certificate and accepts routes only from `observability`. The default wildcard certificate covers only one label, so it cannot serve that name. The shared platform Grafana uses it too, at `platform.grafana.mgmt.rezakara.demo`.
- Pods carry the label `platform.rezakara.demo/component: grafana`, which the Mimir, Loki and Tempo NetworkPolicies allow.
- Login needs the tenant name in the `roles` claim (`role_attribute_strict`), and users get at most Editor, which cannot change datasources.

**Before turning it on for a tenant** (`grafana.enabled` is off by default and not set in the `xtenantargo` composition yet)
- Entra: an app role with `value = <tenant name>` on the Grafana app, assigned to the tenant's group. `xtenantentra` creates this role only on the Vault app today.
- Entra: the callback URL `https://<tenant>.grafana.mgmt.rezakara.demo/login/azuread` as a redirect URI. The Grafana app's list lives in `infra/azure/entraid-apps.tf` and is not set to ignore changes, so a manual edit would be reverted by the next apply.

