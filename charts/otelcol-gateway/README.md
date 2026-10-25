# otelcol-gateway

Tenant-aware OTLP gateway for the LGTM stack. It receives telemetry that the platform collectors have already tagged with `tenant.id`, splits every request by tenant, and sets the `X-Scope-OrgID` header per tenant before forwarding to Mimir (and later Loki and Tempo). See `charts/lgtm-grafana/DESIGN.md`, section 2, for the design.

```text
app-collector ──► gateway-collector ──► Mimir / Loki / Tempo
 (adds tenant.id)   partitioning by tenant.id
                    headers_setter: X-Scope-OrgID
                    drops telemetry without a tenant
```

The Deployment and Service are named `gateway-collector`, like the other collectors. Inside the cluster it listens on `gateway-collector.observability.svc` (OTLP gRPC 4317, OTLP HTTP 4318).

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
| `main` branch manifest of `opentelemetry-collector-releases` | Yes | `partitioningprocessor` is listed |

So we build our own image with the official OpenTelemetry Collector Builder (OCB) and the official component modules, published at `v0.163.0`. The image contains only what the gateway needs.

- Source: `images/otelcol-gateway` in the `dockerkit` repository (`Dockerfile` and `builder-config.yaml`).
- Image: `ghcr.io/rezakaramad/dockerkit/otelcol-gateway`, pinned in `values.yaml` by digest. The current digest was built from `dockerkit` commit `2fe7c14da82ebb5b5310327c85058513275d3150`.
- Contents: receiver `otlp`; processors `batch`, `filter`, `memory_limiter`, `partitioning`, `transform`; extensions `basicauth`, `bearertokenauth`, `headers_setter`, `health_check`; exporters `debug`, `otlp_grpc`, `otlp_http`.

## Switching back to the official image

This custom image is temporary. **Once the maintainers publish the next `otelcol-contrib` release that includes `partitioning`, we move to the official image.**

1. Check the new release: `docker run --rm ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:<version> components | grep partitioning`.
2. In `values.yaml`, set `otelCollector.image.repository` to `ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib`, set the tag or digest, and set `otelCollector.command.name` to `otelcol-contrib`.
3. Check that the exporter names still match. The official image uses `otlp_http` for the OTLP/HTTP exporter, the same as the custom build.
4. Remove `images/otelcol-gateway` from `dockerkit`.

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

- Only the **metrics** pipeline to Mimir is configured. Logs and traces are added after metrics are proven. The processor supports all three signals, but only metrics were tested.
- Mimir still runs without multi-tenancy, so it ignores `X-Scope-OrgID` for now. Deploying this chart does not change behaviour until tenancy is turned on.
- Nothing but the development `app-collector` sends to the gateway yet, and only its metrics. It adds `tenant.id` from the namespace label `platform.rezakara.demo/tenant`; the management cluster collectors still write to Mimir directly.
- The receivers require a bearer token (`bearertokenauth`). The token is shared by all platform collectors, stored in OpenBao at `kv/shared/otelcol-gateway/auth` (written once by `infra/local/kind/setup-secrets.sh`) and delivered by an ExternalSecret named `gateway-collector-auth`. The development cluster reaches the gateway through the route `gateway-collector.mgmt.rezakara.demo`. A NetworkPolicy that limits who can reach the gateway and the backends is still to do.
- Telemetry with no `tenant.id` is dropped, so any OTLP sender in a namespace without the tenant label loses its metrics once it goes through the gateway.
- `partitioning` is alpha upstream.
