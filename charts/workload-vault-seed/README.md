# workload-vault-seed

This chart is a prerequisite. `setup-vault.sh` expects the `vault-reviewer` SA to already exist on the **workload cluster** when it runs. If you try to configure the Vault Kubernetes auth backend before installing this chart, the script will fail with:
```
vault-reviewer ServiceAccount missing — install workload-vault-seed first
```

So the install order matters: deploy this chart → then run `setup-vault.sh`.

That said, if you're using `task kind:up` to bring everything up, you don't have to worry about it; the script already takes care of the correct order.

## Why it exists

Vault (running on the **management cluster**) uses the Kubernetes **auth** method to verify
the identity of workload pods. When a pod presents its service account JWT to Vault,
Vault calls the workload cluster's **TokenReview API** to confirm the token is valid.

To make that API call, Vault needs its own credential for the workload cluster; a
service account token with permission to perform token reviews. This chart creates
exactly that.

## What it deploys

| Resource | Name | Purpose |
|---|---|---|
| `ServiceAccount` | `vault-reviewer` (kube-system) | Identity Vault uses to call the workload cluster API |
| `ClusterRoleBinding` | `vault-reviewer-tokenreview` | Binds `vault-reviewer` to `system:auth-delegator`, granting TokenReview permission |

After the chart is installed, `setup-vault.sh` creates a long-lived
`vault-reviewer-token` Secret from this SA and uses it to configure the
`kubernetes-workload` auth backend in Vault.

## Auth flow

```
pod (workload cluster)
  │  presents its SA JWT
  ▼
Vault (management cluster)
  │  calls TokenReview API with the JWT
  ▼
workload cluster API server
  │  validates token (requires vault-reviewer + system:auth-delegator)
  ▼
Vault checks role config (bound SA name/namespace, policies)
  │
  ▼
issues Vault token to the pod
```

