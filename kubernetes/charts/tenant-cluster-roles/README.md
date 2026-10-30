# Tenant Cluster Roles
This chart deploys the required `ClusterRole` resources used by tenant workloads across clusters.

## namespace-viewer
The `namespace-viewer` `ClusterRole` grants `get`, `list`, and `watch` permissions on the `Namespace` resource.

It is deployed to all tenant clusters.

## tenant-default-aggregated-role
The `tenant-default-aggregated-role` is a `ClusterRole` without any direct rules. Instead, it aggregates permissions from other `ClusterRole` resources labeled with below which All automatically merges matching roles into this role.
```
rbac.jysk.tech/aggregate-to-tenant-default-role: "true"
```
It is deployed to all tenant clusters.
## tenant-base-defaults
This role defines the base set of permissions granted to all tenants across all clusters.
Additional permissions can be layered on top by creating cluster-specific `ClusterRole` resources that are aggregated into the `tenant-default-aggregated-role`.

It is deployed to all tenant clusters.
## tenant-cluster-specific-role
Cluster-specific permissions can be defined by creating a file named `rbac-env-<env>-aggregated.yaml` in the `templates` folder.

This file should define a `ClusterRole` that is conditionally rendered based on the provided `clusterName`.
It extends the base permissions with cluster-specific access.

It is deployed only to the targeted cluster.
