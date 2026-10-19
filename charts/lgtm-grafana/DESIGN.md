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
                               ▼
                  ┌────────────────────────┐
                  │                        │
                  │        Grafana         │
                  │                        │
                  │ Tenant-scoped querying │
                  │       and access       │
                  └────────────────────────┘
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
Incoming telemetry
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
OpenTelemetry's `k8sattributes` processor supports extracting labels from namespace objects, including the custom label you're using. [¹](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/k8sattributesprocessor/README.md)


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
- The Collector should figure out which namespace the telemetry comes from by verifying the source pod, rather than blindly trusting the `k8s.namespace.name` attribute sent by the application.
- Any tenant-related attributes coming from applications should be removed or overwritten before they're used for routing.
- If we can't figure out which tenant the telemetry belongs to, it shouldn't end up in any customer's storage.
- Namespace labels should be protected so unauthorized users can't change, remove, or bypass them by deleting and recreating namespaces.
- Applications shouldn't be able to skip the trusted Collector and send telemetry directly to LGTM.

The general rule here is to **fail closed**. If we can't confidently identify the tenant, we should reject the telemetry instead of sending it to some default tenant.

**The tricky part: Setting X-Scope-OrgID dynamically**

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

The routing connector checks the tenant label and sends logs to the right pipeline. Each pipeline then sets its own X-Scope-OrgID header before forwarding the logs to Loki.

How the components work together:
- `connectors` decide which pipeline should receive the logs based on platform.tenant.
- `exporters` send the logs to Loki with the correct X-Scope-OrgID header.
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
But you might have noticed one limitation here: the pipelines and exporters need to be configured ahead of time. For example, if a new tenant called `initech` comes along, the Collector won't automatically create a new `logs/initech` pipeline. 

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
      │
      ▼
Central OTel
      │ trusted platform.tenant=acme
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

there is no need to add an initech exporter or pipeline to the Collector.

The gateway resolves the tenant dynamically from the trusted, enriched telemetry.

One thing to keep in mind is that the gateway isn't something you get out of the box with OpenTelemetry. You either need to build it yourself or use an existing solution.

OpenTelemetry does have a `headers_setter` extension that can set outgoing headers, but it works with request context or authentication attributes, not directly with arbitrary telemetry resource attributes.

Another important detail is that a single OTLP request can contain telemetry from multiple tenants. So, the gateway needs to separate that data first and make sure each tenant's telemetry gets the correct `X-Scope-OrgID` header before forwarding it to LGTM.

For a platform where tenants are created dynamically, I'd lean toward **Option B **in the long run, as long as you're comfortable maintaining a tenant-aware gateway or using an existing one.
