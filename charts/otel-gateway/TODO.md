# TODO: multi-tenancy, what is left

Entra: the per-tenant app role and the redirect URI, both in the OpenTofu file.
Switch-on: the composition's grafana.enabled switch.
Dashboards: the per-tenant default dashboard, which is step 9.

Design and decisions: `charts/lgtm-grafana/DESIGN.md`. Gateway details: `README.md` in this folder.

## Where we are

Working and checked on the live clusters:
- All writers (metrics, logs, traces) go through the gateway with a static bearer token.
- Mimir, Loki and Tempo run with tenancy on, behind NetworkPolicies (gateway writes, Grafana reads).
- Tenant comes from the namespace label `platform.rezakara.demo/tenant`, falling back to `platform`. Node collector, app-scraper and cluster collector (kube-state-metrics) tag per tenant. Events are not confirmed.
- One Grafana per tenant is built in `charts/tenant-management/templates/grafana/` (off by default) and served by the dedicated `grafana-traefik` gateway at `<tenant>.grafana.mgmt.rezakara.demo`.
- Tested with a hand-applied `demo` Grafana (since removed): only demo data, and the client cannot override the tenant header.

## Do first

1. **Entra, so tenant users can log in.** This is per tenant, so it belongs in `xtenantentra` (it already creates the app role, group and assignment on the Vault app), not in OpenTofu:
   - `charts/crossplane/templates/xtenantentra/composition.yaml`: add a `grafanaApp` block (`appRegObjectID`, `enterpriseAppObjectID`) next to `argocdApp` and `vaultApp`. The IDs are the `azuread_application.grafana` and `azuread_service_principal.grafana` object IDs from `infra/azure/entraid-apps.tf`.
   - `function-xtenantentra` (separate repo): create an app role with `value = <tenant name, lowercase>` on the Grafana app and assign it to the tenant's group, and add `https://<tenant>.grafana.mgmt.rezakara.demo/login/azuread` to the app's redirect URIs. Check that the Entra provider has a resource for redirect URIs.
   - `infra/azure/entraid-apps.tf`: the Grafana app already ignores `app_role`, but not `web`. Make tofu stop owning `web.redirect_uris`, or the next apply removes the tenant URLs.
2. **Switch it on in `xtenantargo`:** add `grafana.enabled: "true"` to the helm parameters in `charts/crossplane/templates/xtenantargo/composition.yaml`. It deploys `tenant-management` per tenant, so the Grafana, datasources and route follow. No tenant is onboarded yet (no `tn-*` namespaces), so also onboard one to test end to end.
3. **After the chart rename (`otelcol-*` to `otel-*`):** in Argo CD, delete the old `otelcol-*` applications without cascade, then sync the new `otel-*` ones, so the new applications can take over the existing resources. The OpenBao path `kv/shared/otelcol-gateway/auth` and the image `otelcol-gateway` keep their old names on purpose.

## Then

- **Per-tenant default dashboard** (step 9): publish from `grafkit` as an OCI artifact and add a `GrafanaDashboard` template to `charts/tenant-management/templates/grafana/`, selected with `dashboards: grafana-<tenant>`. `xtenantargo` then provisions it with the rest of the tenant.
- **Platform Grafana:** keep it for platform admins only. It reads `platform|demo` and has no tenant separation. Anyone whose token carries Admin or Viewer can log in.
- **Tenant onboarding changes the label list:** every tenant namespace needs the `platform.rezakara.demo/tenant` label, or its data lands under `platform`.

## Open items and known limits

- **Static gateway token** shared by all collectors (`kv/shared/otelcol-gateway/auth`). Replace with something dynamic, for example a ServiceAccount token with `oidcauth` (needs an image rebuild).
- **Official collector image:** the gateway uses a custom build because `partitioning` is not in a released contrib image. Switch back after the next release; steps are in the "Switching back" section of `README.md`.
- **Kubernetes events** are not confirmed to be tagged per tenant; I found no event streams in Loki.
- **app-scraper** drops every `*-system` namespace, so today it scrapes nothing. Its tenant tagging is untested until a workload namespace has a scrape-annotated pod.
- **Gateway NetworkPolicy:** nothing limits who can reach the gateway itself. The Mimir, Loki and Tempo policies only work if Cilium enforces them (not confirmed).
- **Old data** under the previous default tenants (`anonymous` in Mimir, `fake` in Loki, `single-tenant` in Tempo) is invisible. Delete it or let retention remove it.
- **Grafana 13.1.3 cannot delete organizations**, and an empty org `orgtest` (id 2) is left in the shared Grafana from testing. Harmless.
- **Operator limits:** the Grafana operator cannot manage organizations ([grafana-operator#2895](https://github.com/grafana/grafana-operator/issues/2895), closed as not planned). Documented in `DESIGN.md`.
- **Gateway `partitioning` on logs and traces** is alpha upstream. Watch for 4xx or dropped data after image changes.

## Useful checks

- Per tenant, through the shared Grafana pod: `kubectl --context kind-management -n observability exec deploy/grafana-deployment -c grafana -- wget -qO- --header="X-Scope-OrgID: demo" <backend url>` (Mimir `http://mimir-gateway.observability.svc/prometheus/api/v1/...`, Loki `http://loki.observability.svc:3100/loki/api/v1/...`, Tempo `http://tempo.observability.svc:3200/api/...`). A bogus tenant must return nothing and `anonymous` must stay empty.
- Render a chart with the repo-server's Helm (local Helm 3.14 cannot render charts that use `fromToml`) and validate collector configs with the image that runs them.
- Use fish syntax in the terminal (see user notes): no heredocs, no `VAR=val`.
