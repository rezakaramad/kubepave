# otelcol-cluster-collector

The one that watches the cluster itself, not the apps or the nodes. There's only ever **one** of it per cluster.

| What | Goes to |
|---|---|
| Kubernetes events (pod killed, image pull failed, ...) | Loki |
| Object state from [kube-state-metrics](../kube-state-metrics) (is the Deployment ready, how many replicas ...) | Mimir |

- **Adds** Kubernetes details and the cluster name.
- **Runs as** a single-replica Deployment. Nothing sends to it, so there is no Service.

## Good to know

- Keep it at **one replica**. A second copy would ship every event and metric twice.
- It scrapes kube-state-metrics by name (`kube-state-metrics.observability.svc:8080`), so that chart must be installed in the same namespace.
- Control-plane metrics (scheduler and controller manager) aren't scraped. That doesn't apply to kind.
- Its own health metrics go to the [meta-collector](../otelcol-meta-collector), not through itself.
