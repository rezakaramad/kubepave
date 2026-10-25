# otelcol-app-collector

Applications send their traces, logs and metrics to **app-collector** over OTLP, and app-collector forwards each one to the right backend.

| Signal | Goes to |
|---|---|
| Traces | Tempo |
| Logs | Loki |
| Metrics | Mimir |

- **Listens on** 4317 (gRPC) and 4318 (HTTP) through the `app-collector` Service.
- **Adds** Kubernetes details (pod, namespace, workload) and the cluster name to everything that passes through.

## Good to know

- Keep the pod label `app.kubernetes.io/name: app-collector`. The tenant NetworkPolicy only lets traffic in from pods with that label.
- Its own health metrics go to the [meta-collector](../otelcol-meta-collector), not through itself.
