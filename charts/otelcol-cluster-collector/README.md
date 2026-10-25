# otelcol-cluster-collector

The one that watches the cluster itself, not the apps or the nodes. There's only ever **one** of it per cluster.

It collects two things.

**Kubernetes events** (pod killed, image pull failed, ...) go to Loki, through the gateway.

**Object state** from [kube-state-metrics](../kube-state-metrics) (is the Deployment ready, how many replicas, ...) goes to Mimir, through the gateway.

- **Adds** Kubernetes details and the cluster name.
- **Runs as** a single-replica Deployment. Nothing sends to it, so there is no Service.

## Good to know

- Keep it at **one replica**. A second copy would ship every event and metric twice.
- The address of kube-state-metrics is fixed in [values.yaml](values.yaml#L78): `kube-state-metrics.observability.svc:8080`. Install that chart in the `observability` namespace. If you move or rename it, change the address there too, or the object-state metrics stop without any error.
- The Kubernetes control plane (scheduler, controller manager, API server, etcd) is not monitored, so there are no control-plane dashboards or alerts. [Why](#why-the-control-plane-is-not-monitored) is below.
- Its own health metrics go to the [meta-collector](../otelcol-meta-collector), not through itself.

## Why the control plane is not monitored

The scheduler, controller manager and etcd all serve metrics, but on kind (checked on a default v1.35 cluster) they listen only on the node's `127.0.0.1`. A program bound to `127.0.0.1` accepts connections only from inside its own network. The collector runs in a pod with its own network, so its `localhost` is not the node's. It would have to connect to the node's address, and a server bound to `127.0.0.1` refuses that. The API server listens on all addresses, so a pod can reach it, but it answers `403` without credentials.

The flags of the control-plane pods show where each one listens (fish syntax):

```text
$ for c in kube-scheduler kube-controller-manager etcd
      kubectl -n kube-system get pod -l component=$c -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep -E 'bind-address|listen-metrics-urls' | sed "s/^/$c: /"
  end
kube-scheduler: "--bind-address=127.0.0.1"
kube-controller-manager: "--bind-address=127.0.0.1"
etcd: "--listen-metrics-urls=http://127.0.0.1:2381"
```

The sockets on the node confirm it. Only the API server listens on all addresses (`*`):

```text
$ docker exec <cluster>-control-plane ss -ltnp
LISTEN 127.0.0.1:2381    users:(("etcd",...))
LISTEN 127.0.0.1:10259   users:(("kube-scheduler",...))
LISTEN 127.0.0.1:10257   users:(("kube-controller",...))
LISTEN *:6443            users:(("kube-apiserver",...))
```

From a pod, the scheduler, controller manager and etcd refuse the connection (curl exit code 7).

## On a real cluster

It depends on who runs the control plane.

### Managed (GKE, and similar)

You cannot reach the scheduler or controller manager at all, because the provider runs them. Use the provider's own metrics instead. On GKE, enable the control-plane packages, and the metrics go to Cloud Monitoring, not to this collector:

```text
gcloud container clusters update <cluster> \
  --monitoring=SYSTEM,API_SERVER,SCHEDULER,CONTROLLER_MANAGER
```

With Terraform this is `monitoring_config.enable_components` on `google_container_cluster`. The GKE docs list API server, scheduler and controller manager, but not etcd ([configure metrics](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/configure-metrics)). For other managed services, check the provider's docs (not verified here).

### Self-managed (kubeadm and similar)

1. **Let a pod reach them.** Change the bind addresses in the kubeadm `ClusterConfiguration` ([docs](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/control-plane-flags/)):

   ```yaml
   apiVersion: kubeadm.k8s.io/v1beta4
   kind: ClusterConfiguration
   controllerManager:
     extraArgs:
       - name: bind-address
         value: 0.0.0.0
   scheduler:
     extraArgs:
       - name: bind-address
         value: 0.0.0.0
   etcd:
     local:
       extraArgs:
         - name: listen-metrics-urls
           value: http://0.0.0.0:2381
   ```

   This opens those ports to everything that can reach the node, so limit them with a firewall to the nodes that run the collector.
2. **Give the collector permission.** The scheduler and controller manager answer over HTTPS and check credentials. The collector's ServiceAccount needs `get` on the non-resource URL `/metrics`. etcd's metrics port is plain HTTP in the setup above, so it needs no token.
3. **Add the scrapes** to the Prometheus receiver in [values.yaml](values.yaml). Target the control-plane nodes by IP. This is an untested sketch for the scheduler:

   ```yaml
   - job_name: kube-scheduler
     scheme: https
     authorization:
       credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
     tls_config:
       insecure_skip_verify: true
     kubernetes_sd_configs:
       - role: node
     relabel_configs:
       - source_labels: [__meta_kubernetes_node_labelpresent_node_role_kubernetes_io_control_plane]
         regex: "true"
         action: keep
       - source_labels: [__meta_kubernetes_node_address_InternalIP]
         regex: (.+)
         replacement: $1:10259
         target_label: __address__
   ```

   The controller manager is the same with port `10257`. etcd uses `scheme: http` and port `2381`. The API server needs no changes to the node: scrape `kubernetes.default.svc:443` with the same token and the cluster CA at `/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`.

The collector's Prometheus receiver also needs permission to list nodes for the discovery above.
