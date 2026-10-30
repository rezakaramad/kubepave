## Plan: Replace the static gateway bearer token with OIDC (Kubernetes ServiceAccount tokens)

Status: planned (2026-10-26), not started. Read kubernetes/charts/otel-gateway/AUTH.md for background. Repo: /home/kara/github/rezakaramad/idp/kubepave; image repo: /home/kara/github/rezakaramad/dockerkit. Terminal is fish; repo scripts are bash. kind clusters may be off (contexts kind-management, kind-development).

Goal: collectors send projected, rotating ServiceAccount JWTs; the gateway validates them with `oidcauthextension` and accepts only the platform collector ServiceAccounts. No static secret remains.

### Facts verified in the repo
- Static token: env GATEWAY_TOKEN from Secret gateway-collector-auth, used by extension `bearertokenauth/gateway` (same name in all collector charts) and exporter `otlphttp/gateway` (authenticator: bearertokenauth/gateway). Charts: otel-app-collector, otel-app-scraper, otel-cluster-collector, otel-node-collector, otel-meta-collector; the gateway is kubernetes/charts/otel-gateway/values.yaml (extension `bearertokenauth`, grpc 4317 and http 4318 receivers).
- Secret creation: ExternalSecret in kubernetes/charts/otel-gateway/templates/auth-secret.yaml (mgmt) and kubernetes/charts/otel-app-collector/templates/gateway-auth.yaml (gated by `gatewayAuth.enabled`: values.yaml L2, values-local-development.yaml L1-3). Source: OpenBao kv/shared/otel-gateway/auth, written by create_otel_gateway_secrets() in local/kind/setup-secrets.sh (L462, call at L498).
- Endpoints: dev https://gateway-collector.mgmt.rezakara.demo (values-local-development.yaml, ca_file /etc/root-ca/ca.crt); mgmt http://gateway-collector.observability.svc:4318. Route: kubernetes/charts/otel-gateway/templates/httproute.yaml (port 4318).
- ServiceAccount names (= fullnameOverride): app-collector, app-scraper, cluster-collector, node-collector, meta-collector, gateway-collector, namespace observability. The `otel-` prefix regex in AUTH.md is WRONG. Use system:serviceaccount:observability:(app-collector|app-scraper|cluster-collector|meta-collector|node-collector).
- meta-collector sends its own metrics with an SDK exporter header `Authorization: Bearer ${env:GATEWAY_TOKEN}` (values-local-development.yaml L33-47, values-local-management.yaml L10-24). It cannot read a rotating file; needs a separate solution.
- Gateway image: dockerkit/images/otel-gateway-controller/builder-config.yaml (OCB v0.163.0; extensions headerssetter, healthcheck, basicauth, bearertokenauth; no oidcauth). Image digest pinned in kubernetes/charts/otel-gateway/values.yaml L8-10; Contents line in kubernetes/charts/otel-gateway/README.md L35.
- kind configs: local/kind/kind-configs/{management,development}.yaml already have kubeadmConfigPatches. Helper pattern for cross-cluster trust: local/kind/setup-openbao.sh (libs/common.sh, libs/utils.sh, kind_context, cluster_api_url).
- Gateway pipelines (metrics/logs/traces): memory_limiter, filter/drop_untenanted, partitioning.

### Phase 0: Decisions and spikes
1. Verify `bearertokenauth` supports `filename` with reload on otelcol-contrib 0.161.0 (`otelcol-contrib validate` with such a config).
2. Verify on the gateway build (v0.163.0) that oidcauthextension exposes `auth.claims.subject` to the `resource` processor via `from_context`, and that a `filter` on the copied attribute works (test with a hand-made JWT).
3. Decide meta-collector self-metrics: preferred is internal telemetry exporter to its own local OTLP receiver plus a pipeline exporting with `otlphttp/gateway`; confirm no feedback loop.
4. Confirm the dual-run shape: second OIDC receiver on port 4319 plus a temporary route hostname for dev.

### Phase 1: Gateway image (dockerkit)
1. Add `github.com/open-telemetry/opentelemetry-collector-contrib/extension/oidcauthextension v0.163.0` to builder-config.yaml (keep bearertokenauth until cleanup).
2. Build, push, take the digest; update kubernetes/charts/otel-gateway/values.yaml (digest and commit comment) and the README Contents line.

### Phase 2: Cluster trust (kind; managed clusters skip)
1. Add distinct `service-account-issuer` API server args in both kind configs (for example https://management.kind.local, https://development.kind.local). Requires recreating the clusters.
2. Add local/kind/setup-otel-oidc.sh (model on setup-openbao.sh): export keys with `kubectl --context <ctx> get --raw /openid/v1/jwks`, create/update ConfigMap otel-gateway-oidc-jwks (management.json, development.json) in observability of the management cluster; re-run after cluster recreation; document in local/kind/README.md.
3. Real clusters (GKE): use the public issuer URL and discovery; no files.

### Phase 3: Gateway dual-run (kubernetes/charts/otel-gateway)
1. values.yaml: add extension `oidc` with two providers (issuer URLs, audience `otel-gateway`, `public_keys_file` from the mounted ConfigMap via extraVolumes/extraVolumeMounts).
2. Add receiver `otlp/oidc` (http, 4319, include_metadata: true, auth: oidc), Service port 4319, add it to the three pipelines. Keep the bearer receivers for now.
3. Add `resource/caller` (upsert caller.subject from_context auth.claims.subject) and `filter/only_platform_collectors` (drop non-matching subjects for metrics/traces/logs), then delete `caller.subject` before export. Data from the old bearer receiver has no caller.subject, so use separate pipelines or apply the filter only after cutover.
4. Temporary HTTPRoute hostname gateway-collector-oidc.mgmt.rezakara.demo to port 4319 (label external-dns-create: "true"); check the wildcard cert covers it.

### Phase 4: Collectors (order: node-collector, app-scraper, cluster-collector, app-collector, meta-collector)
1. Per chart values.yaml: extension `bearertokenauth/gateway` reads `filename: /var/run/secrets/otel-gateway/token`; remove the GATEWAY_TOKEN extraEnvs; add a projected serviceAccountToken volume (audience otel-gateway, expirationSeconds 3600, path token) and a read-only mount. Extension and exporter names stay the same.
2. Endpoints: mgmt values-local-management.yaml to http://gateway-collector.observability.svc:4319; dev values-local-development.yaml to https://gateway-collector-oidc.mgmt.rezakara.demo.
3. meta-collector: implement the Phase 0.3 decision (remove the Authorization header with GATEWAY_TOKEN from both values-local-*.yaml).
4. Sync one at a time; check gateway logs and per-tenant data in Mimir/Loki/Tempo.

### Phase 5: Cutover and cleanup (after all collectors verified)
1. Gateway: remove `bearertokenauth` extension, old receiver authenticators, GATEWAY_TOKEN env/extraEnvs. Keep the OIDC receiver on 4319, switch templates/httproute.yaml backendRef to 4319, move dev collectors back to https://gateway-collector.mgmt.rezakara.demo, delete the temporary route.
2. Delete kubernetes/charts/otel-gateway/templates/auth-secret.yaml and kubernetes/charts/otel-app-collector/templates/gateway-auth.yaml; remove `gatewayAuth` from otel-app-collector values.yaml and values-local-development.yaml; confirm Secret gateway-collector-auth is pruned in both clusters.
3. Remove create_otel_gateway_secrets() and its call in local/kind/setup-secrets.sh. Delete OpenBao kv/shared/otel-gateway/auth and, if present, kv/shared/otelcol-gateway/auth.
4. Repo-wide grep must find nothing for: GATEWAY_TOKEN, gateway-collector-auth, otel-gateway/auth, otelcol-gateway/auth, bearertokenauth on the gateway, gatewayAuth.
5. Image: remove bearertokenauthextension (and basicauthextension if unused) from the dockerkit builder-config, rebuild, update digest and README Contents.
6. Docs: kubernetes/charts/otel-gateway/README.md (L35, L91), kubernetes/charts/otel-gateway/TODO.md (L26 step 4, L36 open item), kubernetes/charts/lgtm-grafana/DESIGN.md (bullet about collectors authenticating through a Traefik route with authentication), AUTH.md.

### Phase 6: AUTH.md corrections
- Fix the regex and subject text in the Authorization sketch (real ServiceAccount names, no `otel-` prefix).
- Remove or shorten the "Static shared bearer token" section (not used after migration).

### Verification
1. Gateway only: OIDC receiver with no token, malformed token, wrong audience, and a valid token from a throwaway pod in a tenant namespace. Expected: first three 401; the tenant pod's data accepted by the authenticator but absent in every backend (dropped by the filter), with a drop counter or log.
2. Per collector: no 401 in gateway logs; data keeps arriving for tenants `demo` and `platform`; bogus tenant returns nothing; `anonymous`, `fake`, `single-tenant` stay empty (checks in kubernetes/charts/otel-gateway/TODO.md).
3. Rotation: temporarily set expirationSeconds 600, keep a collector past one rotation, confirm no errors and no restart.
4. After cleanup: delete the old Secret, confirm all components stay healthy, rerun the repo-wide grep.
5. Recreate a kind cluster and re-run setup-otel-oidc.sh; collectors from it fail with 401 before the re-run and work after.

### Decisions already made
- Kubernetes ServiceAccount tokens, not Entra ID.
- Real clusters use issuer discovery; local kind uses key files and distinct issuers.
- Authorization in the gateway pipeline from the token subject.
- Static token section is background only and removed or shortened after migration.

### Scope
- Included: gateway, five collector charts, kind configs and scripts, docs, image rebuild, full cleanup of the static token.
- Excluded: gateway NetworkPolicy (still on TODO.md), mTLS, Entra setup, switching to the official collector image.

### Risks and open questions
- bearertokenauth `filename` support on 0.161.0 and oidc claim access on 0.163.0 are unverified (Phase 0).
- Changing the kind issuer needs cluster recreation; stale JWKS after recreation means 401 from that cluster until the script is re-run (consider an alert on gateway auth failures).
- The subject filter drops data with HTTP 200, not 401, so drops must be made visible.
- meta-collector self-metrics design (Phase 0.3).
