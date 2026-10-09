# otelcol-app-scraper

The one that goes and fetches. Apps that expose a `/metrics` page but don't send OTLP get picked up here, and their metrics are forwarded to Mimir.

## How a pod gets scraped

Annotate the pod:

```yaml
prometheus.io/scrape: "true"
prometheus.io/port: "8080"
prometheus.io/path: "/metrics"
```

- **Set the port.** Without it, every container port the pod declares gets scraped, not only the metrics one.
- It finds annotated pods in every namespace, **except** namespaces ending in `-system` (kube-system, platform-system, ...). Those are infrastructure, not tenant apps.
- **Adds** the `namespace` and `pod` labels, plus the cluster name.
- **Runs as** a single-replica Deployment. Nothing sends to it, so there is no Service.

## Good to know

- Keep it at **one replica**. A second copy would scrape every pod twice.
- It has a cluster-wide read-only role for pods and namespaces, which is what lets it discover them.
- Its own health metrics go to the [meta-collector](../otelcol-meta-collector), not through itself.
