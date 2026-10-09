# otelcol-node-collector

The one that looks at the machines. It runs on **every node** and collects what apps don't send on their own.

| What | Goes to |
|---|---|
| Pod logs (read from `/var/log/pods`) | Loki |
| Host metrics (CPU, memory, disk, network) | Mimir |
| Kubelet stats (per pod and container usage) | Mimir |

- **Adds** Kubernetes details and the cluster name.
- **Runs as** a DaemonSet. Nothing sends to it, so there is no Service.

## Good to know

- It runs as **root**, because container log files are root-owned. Its namespace therefore allows privileged pods, and the pod mounts host paths read-only.
- The kubelet check skips certificate verification, because the kind kubelet uses a self-signed certificate. Revisit that for a real cluster.
- Its own health metrics go to the [meta-collector](../otelcol-meta-collector), not through itself.
