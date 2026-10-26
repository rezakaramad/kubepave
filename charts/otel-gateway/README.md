# otel-gateway

Tenant-aware OTLP gateway for the LGTM stack. It receives telemetry that the platform collectors have already tagged with `tenant.id`, splits every request by tenant, and sets the `X-Scope-OrgID` header per tenant before forwarding to Mimir, Loki and Tempo. See [DESIGN.md, section 2](../lgtm-grafana/DESIGN.md#2-what-well-be-doing) for the design.

```text
app-collector ──► gateway-collector ──► Mimir / Loki / Tempo
 (adds tenant.id)   partitioning by tenant.id
                    headers_setter: X-Scope-OrgID
                    drops telemetry without a tenant
```

Inside the cluster it listens on `gateway-collector.observability.svc:4319` (OTLP/HTTP, ServiceAccount token required).

## Why a custom image

The gateway needs two components from the OpenTelemetry Collector contrib distribution:

- `partitioning` processor: splits a batch by an OTTL expression (here `resource.attributes["tenant.id"]`) and puts the key into the request metadata.
- `headers_setter` extension: sets `X-Scope-OrgID` from that request metadata (`from_context`).

`headers_setter` can only read request metadata, never resource attributes, so without `partitioning` there is no way to set the tenant header from the tenant label on the telemetry.

**The `partitioning` processor is not in any released `otelcol-contrib` image yet.**

| Image | Has `partitioning`? | How we know |
|---|---|---|
| `otelcol-contrib:0.161.0` (what the other collectors run) | No | Predates the component |
| `otelcol-contrib:0.163.2` (latest release when this was written) | No | `otelcol-contrib components` lists no `partitioning`; the `v0.163.2` manifest does not include it |
| [`main` branch manifest](https://github.com/open-telemetry/opentelemetry-collector-releases/blob/main/distributions/otelcol-contrib/manifest.yaml) of `opentelemetry-collector-releases` | Yes | `partitioningprocessor` is listed |

So we build our own image with the official OpenTelemetry Collector Builder (OCB) and the official component modules, published at `v0.163.0`. The image contains only what the gateway needs.

- Source: [`images/otel-gateway-controller`](https://github.com/rezakaramad/dockerkit/tree/main/images/otel-gateway-controller) in the `dockerkit` repository ([`Dockerfile`](https://github.com/rezakaramad/dockerkit/blob/main/images/otel-gateway-controller/Dockerfile) and [`builder-config.yaml`](https://github.com/rezakaramad/dockerkit/blob/main/images/otel-gateway-controller/builder-config.yaml)).
- Image: `ghcr.io/rezakaramad/dockerkit/otel-gateway-controller`, pinned in [values.yaml](values.yaml) by digest. The current digest was built from `dockerkit` commit [`89aed38`](https://github.com/rezakaramad/dockerkit/commit/89aed38cac5bff88268b094547bc7ab1f4965407).
- Contents: receiver `otlp`; processors `batch`, `filter`, `memory_limiter`, `partitioning`, `resource`, `transform`; extensions `headers_setter`, `health_check`, `oidc`; exporters `debug`, `otlp_grpc`, `otlp_http`.

## Switching back to the official image

This custom image is temporary. **Once the maintainers publish the next `otelcol-contrib` release that includes `partitioning`, we move to the official image.**

1. Check the new release:
```
docker run --rm ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:<version> components | grep partitioning
```

2. In [values.yaml](values.yaml), set `otelCollector.image.repository` to [`ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib`](https://github.com/open-telemetry/opentelemetry-collector-releases/pkgs/container/opentelemetry-collector-releases%2Fopentelemetry-collector-contrib), set the tag or digest, and set `otelCollector.command.name` to `otelcol-contrib`.
3. Check that the exporter names still match. The official image uses `otlp_http` for the OTLP/HTTP exporter, the same as the custom build.
4. Remove [`images/otel-gateway-controller`](https://github.com/rezakaramad/dockerkit/tree/main/images/otel-gateway-controller) from `dockerkit`.

## Upstream references

The `partitioning` processor:

- Proposal and tracking issue: [contrib#39199](https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/39199) (OTTL-based request partitioning processor)
- Component skeleton: [contrib#51729](https://github.com/open-telemetry/opentelemetry-collector-contrib/pull/51729)
- Logs partitioning: [contrib#51768](https://github.com/open-telemetry/opentelemetry-collector-contrib/pull/51768)
- Traces partitioning: [contrib#51870](https://github.com/open-telemetry/opentelemetry-collector-contrib/pull/51870)
- Metrics partitioning: [contrib#51879](https://github.com/open-telemetry/opentelemetry-collector-contrib/pull/51879)
- Pipeline examples in the README: [contrib#51968](https://github.com/open-telemetry/opentelemetry-collector-contrib/pull/51968)
- Internal telemetry metrics: [contrib#51969](https://github.com/open-telemetry/opentelemetry-collector-contrib/pull/51969)
- Promoted to alpha and added to the contrib distribution: [contrib#52215](https://github.com/open-telemetry/opentelemetry-collector-contrib/pull/52215)
- Processor README, including the "Set a per-tenant HTTP header" example: [processor/partitioningprocessor](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/partitioningprocessor/README.md)

The pattern we use (`partitioning` + `headers_setter` + exporter batching by `tenant_id`) was posted by the maintainers as the answer to an LGTM multi-tenancy request: [contrib#46744](https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/46744) (component donation: `lgtmexporter`, closed as solved by this combination).

The `headers_setter` extension and the history of requests to set tenant headers dynamically:

- New component request: [contrib#12922](https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/12922)
- Extension added: [contrib#12892](https://github.com/open-telemetry/opentelemetry-collector-contrib/pull/12892)
- Set `X-Scope-OrgID` dynamically for Mimir: [contrib#27901](https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/27901)
- Dynamic header for Mimir multi-tenancy: [contrib#42800](https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/42800) (closed as not planned)
- Support values from attributes: [contrib#34257](https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/34257) (closed as not planned)
- Access to client request metadata: [contrib#41879](https://github.com/open-telemetry/opentelemetry-collector-contrib/pull/41879)

Batching the exporter by metadata key (`sending_queue.batch.partition.metadata_keys`):

- [opentelemetry-collector#10825](https://github.com/open-telemetry/opentelemetry-collector/issues/10825) (exporterhelper: batch by a key from pdata or context)

Release manifests used to check which components ship in each image:

- [v0.163.2 `otelcol-contrib` manifest](https://github.com/open-telemetry/opentelemetry-collector-releases/blob/v0.163.2/distributions/otelcol-contrib/manifest.yaml)
- [`main` manifest](https://github.com/open-telemetry/opentelemetry-collector-releases/blob/main/distributions/otelcol-contrib/manifest.yaml)

## Current scope and limits

- Metrics, logs and traces are all configured (Mimir, Loki, Tempo). Metrics are proven; the `partitioning` processor on logs and traces is only validated, so check them after the first sync.
- Mimir runs with multi-tenancy and federation on. A NetworkPolicy lets only the gateway (writes), Grafana (reads) and Tempo (span metrics) reach Mimir, and the external `mimir.mgmt` route is gone. The Grafana datasource reads `platform|demo`. Mimir's nginx stores a request without `X-Scope-OrgID` under the tenant `anonymous` instead of rejecting it, so check that tenant stays empty.
- Every writer goes through the gateway: `app-collector` (metrics, logs and traces; tenant from the namespace label `platform.rezakara.demo/tenant`) and the node, cluster, app-scraper and meta collectors (tenant `platform`). Tempo's span metrics are written to Mimir under the tenant of the trace.
- Loki and Tempo run with multi-tenancy on and have a NetworkPolicy like Mimir's (gateway for writes, Grafana for reads). Their external routes are gone and the Grafana datasources read `platform|demo`. Data written before tenancy sits under the old default tenant and is invisible.
- The node collector (container logs, kubelet metrics) and the app-scraper take the tenant from the label on the pod's namespace and fall back to `platform`. The cluster collector does the same for kube-state-metrics series that carry a `namespace` label (pods, deployments, namespaces). Cluster-scoped series such as nodes stay `platform`. Kubernetes events are not confirmed to be tagged per tenant.
- The receiver requires a ServiceAccount JWT for the audience `otel-gateway` (`oidc` extension, see [AUTH.md](AUTH.md)) from one of the platform collector ServiceAccounts; other valid tokens are dropped. The signing keys come from OpenBao `kv/shared/pki/jwks` (written by `infra/local/kind/setup-secrets.sh`) through an ExternalSecret. The development cluster reaches the gateway through the route `gateway-collector.mgmt.rezakara.demo`. A NetworkPolicy that limits who can reach the gateway itself is still to do (the one on Mimir only works if the CNI enforces it).
- Telemetry with no `tenant.id` is dropped, so any OTLP sender in a namespace without the tenant label loses its telemetry once it goes through the gateway.
- `partitioning` is alpha upstream.
