# otelcol-app-collector

The front door for your applications. Apps send their traces, logs and metrics here over OTLP, and it forwards each one to the right backend.

| Signal | Goes to |
|---|---|
| Traces | Tempo |
| Logs | Loki |
| Metrics | Mimir |

- **Listens on** 4317 (gRPC) and 4318 (HTTP) through the `app-collector` Service.
- **Adds** Kubernetes details (pod, namespace, workload) and the cluster name to everything that passes through.
- **Runs as** a Deployment, as a non-root user.

## Good to know

- Keep the pod label `app.kubernetes.io/name: app-collector`. The tenant NetworkPolicy only lets traffic in from pods with that label.
- Its own health metrics go to the [meta-collector](../otelcol-meta-collector), not through itself.
