# Strimzi Kafka Operator

Runs Apache Kafka in KRaft mode via the Strimzi operator, which is
bundled as a chart dependency. 

The cluster uses two dedicated node pools so the metadata quorum and the data plane
scale and roll independently:

- **controller**: runs the KRaft metadata quorum that tracks cluster state.
- **broker**: stores topic partitions on disk and serves produce/consume traffic.

Clients connect over a single TLS listener on port `9093` (internal to the cluster).
Strimzi provisions the cluster CA and broker certificates automatically.

## Durability configuration

The `cluster.config` values are Kafka's durability knobs. Every partition can be
copied to multiple brokers (its *replicas*); the copies kept current are the
*in-sync replicas* (ISR). With 3 brokers, the defaults below keep 3 copies and
require 2 to confirm each write, so the cluster survives one broker failure with no
data loss.

| Option | What it controls |
| --- | --- |
| `offsets.topic.replication.factor` | Copies of the internal topic that tracks which messages each consumer has read. |
| `transaction.state.log.replication.factor` | Copies of the internal topic that tracks in-flight (exactly-once) transactions. |
| `transaction.state.log.min.isr` | Minimum in-sync copies required before a transaction-state write is allowed. |
| `default.replication.factor` | Default number of copies for new topics when a client doesn't specify one. |
| `min.insync.replicas` | Minimum in-sync copies that must confirm a write before it is acknowledged (pairs with producer `acks=all`). |

Rule of thumb: keep `replication.factor` equal to the broker count (up to 3) and set
`min.insync.replicas` to `replication.factor - 1`. Lower them only for single-broker
dev setups, where `1`/`1` is appropriate.

## OAuth authentication (Kubernetes ServiceAccount JWT)

The TLS listener authenticates clients with OAuth: a workload presents its Kubernetes
ServiceAccount token (a JWT) and the broker validates it against the cluster's
OIDC/JWKS endpoint. 

Strimzi 1.x (`v1` API) removed the built-in `oauth` listener type, so this is wired
through `type: custom` using Strimzi's bundled OAuth library (see
`cluster.listeners[].authentication` in `values.yaml`). Validation pins the issuer,
checks the audience contains `kafka`, and derives the Kafka principal from the `sub`
claim (`system:serviceaccount:<ns>:<sa>`).

### Why the `kafka-jwks-proxy` (nginx) exists

To verify a token's signature, the broker fetches the cluster's public keys from the
Kubernetes JWKS endpoint `…/openid/v1/jwks`. Two things collide locally:

- Kubernetes' JWKS endpoint serves **only** `application/jwk-set+json` and returns
  **HTTP 406 Not Acceptable** for any other `Accept` header.
- The bundled Strimzi OAuth library requests `Accept: application/json`, and offers
  no option to change it; so it gets a 406 and validation fails.

`templates/jwks-proxy.yaml` deploys a tiny nginx reverse proxy whose only job is to
relay that one request with the correct `Accept: application/jwk-set+json` header
(verifying the API server TLS with its own mounted cluster CA). The broker's
`oauth.jwks.endpoint.uri` points at the proxy over plain in-cluster HTTP:

```
broker --HTTP--> kafka-jwks-proxy:8080 --HTTPS (Accept: jwk-set+json)--> apiserver /openid/v1/jwks
```

This is a workaround for the **raw kube-apiserver's strict content negotiation**, which
is all a local kind cluster exposes. A managed provider such as GKE additionally
publishes a public, lenient issuer endpoint (`container.googleapis.com/...`) that
serves `application/json` directly; there you point `oauth.jwks.endpoint.uri` straight
at it and set `cluster.jwksProxy.enabled: false`, dropping the proxy entirely.

## Links
- [Strimzi Helm Chart](https://github.com/strimzi/strimzi-kafka-operator)
- [Strimzi Docs](https://strimzi.io/docs/operators/latest/overview)
- [Strimzi OAuth library](https://github.com/strimzi/strimzi-kafka-oauth)
