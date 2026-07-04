# Config Connector

Config Connector is installed on all clusters and is used to provision and manage Google Cloud resources in the same way as Crossplane.

In the management cluster, it provisions the resources required for the platform itself as well as all tenant resources.
In tenant clusters, each tenant namespace has its own Config Connector controller, which provisions the cloud resources needed for that tenant.

Config Connector can be installed as an add-on when creating the cluster.
This approach is simple, but it comes with a trade-off: you cannot control the version of Config Connector running in the cluster.
There is no way to force an upgrade, and the bundled version often lags significantly behind the latest release.

To maintain full control over the version installed, we need to install Config Connector manually.

This Helm chart includes a `Justfile` that fetches the latest version of Config Connector from https://storage.googleapis.com/configconnector-operator/ .
The release bundle is then extracted into the `crds/` and `templates/` folders.

The CRDs are annotated with the release version, but, by design, Helm does not update existing CRDs if they change.

Config Connector is installed in "namespaced" mode. See more at the [Config Connector docs.](https://docs.cloud.google.com/config-connector/docs/how-to/install-manually)

## How to upgrade

Use [Justfile](https://github.com/casey/just) to run the update process.

```sh
just get-latest-release
```

This will download the latest release and updates the `appVersion` field in `Chart.yaml` accordingly.

## Links

- [Config Connector Helm Chart](https://github.com/jysk-dev/platform-hub/tree/main/kubernetes/charts/config-connector)
- [Config Connector Docs](https://docs.cloud.google.com/config-connector/docs/overview)
