# OpenTelemetry
## How an OTel Collector works

An OTel Collector has three main components:

```text
       ┌─────────────────────────┐
       │       1. Receiver       │
       └─────────────────────────┘
      Receives telemetry from apps
                   │
                   ▼
       ┌─────────────────────────┐
       │      2. Processors      │
       └─────────────────────────┘
      Enrich, filter, transform,
           or batch telemetry
                   │
                   ▼
       ┌─────────────────────────┐
       │       3. Exporter       │
       └─────────────────────────┘
      Sends telemetry to Loki,
            Mimir, or Tempo
```

A pipeline connects these components together.

For example:
```yaml
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp/tempo]
```
This means:
- otlp: Receive traces from applications.
- batch: Group traces for efficient transmission.
- otlp/tempo: Send traces to Tempo.
That's one pipeline.

Normally, you might have one traces pipeline sending all tenants' traces to Tempo.
In a multi-tenant setup, Tempo needs to know which tenant each trace belongs to.
One straightforward implementation is to have a different exporter for each tenant

```text
                  Central OTel Collector
              Receives traces from team-a and team-b
                              │
                              ▼
                      Routing connector
             Which Kubernetes namespace did
                   this trace come from?
                              │
                 ┌────────────┴────────────┐
                 ▼                         ▼
          Team A pipeline           Team B pipeline
            Exporter A                Exporter B
       X-Scope-OrgID: team-a     X-Scope-OrgID: team-b
                 │                         │
                 └────────────┬────────────┘
                              ▼
                         Shared Tempo
             Stores traces under the corresponding
                       logical tenant ID
```

Both exporters send data to the same Tempo deployment. The only difference is the tenant header attached to their requests:

```yaml
exporters:
  otlp/team-a:
    endpoint: tempo:4317
    headers:
      X-Scope-OrgID: team-a

  otlp/team-b:
    endpoint: tempo:4317
    headers:
      X-Scope-OrgID: team-b
```
Notice that endpoint is identical for both exporters. Only X-Scope-OrgID changes.
