# Strimzi Kafka Operator

Runs Apache Kafka in [KRaft mode](https://kafka.apache.org/41/operations/kraft/) via the [Strimzi operator](https://github.com/strimzi/strimzi-kafka-operator), which is
bundled as a chart dependency. 

The cluster uses two dedicated node pools so the metadata quorum and the data plane
scale and roll independently:

- **controller**: runs the KRaft metadata quorum that tracks cluster state.
- **broker**: stores topic partitions on disk and serves produce/consume traffic.

Clients inside the cluster connect over the internal TLS listener on port `9093`, using the Strimzi
cluster CA that the operator provisions automatically.

Clients outside the cluster (the development cluster) connect over the `external` listener on port
`9094` ([`cluster.external`](values.yaml#L65) in `values.yaml`). It is a LoadBalancer listener: Strimzi creates one service for the bootstrap address and one per broker, and external-dns publishes `kafka.<domain>` and
`kafka-<id>.<domain>` from their hostname annotations. Its certificate is issued by cert-manager from
the platform root CA (`templates/listener-certificate.yaml`), so clients trust it through the root CA.
The Certificate lists every one of those names, so adding a broker adds its name automatically.

## Durability configuration

The [`cluster.config`](values.yaml#L123) values are Kafka's durability knobs. Every partition can be
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

### Fetching the JWKS from the Kubernetes API server

To verify a token's signature, the broker fetches the cluster's public keys live from the
Kubernetes JWKS endpoint `…/openid/v1/jwks`. Kubernetes' endpoint serves **only**
`application/jwk-set+json` and returns **HTTP 406 Not Acceptable** for an explicit
`Accept: application/json`, which the Strimzi OAuth library sends by default.

Setting `oauth.include.accept.header="false"` stops the library sending that header. The JVM's
default `Accept` then ends in `*/*`, which the API server accepts, so the broker reads the endpoint
directly: `oauth.jwks.endpoint.uri="https://kubernetes.default.svc/openid/v1/jwks"`. The pod's own
cluster CA (`/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`) is the truststore, and the API
server must allow anonymous reads of the discovery endpoints (the local kind setup already does).

### External listener (development cluster clients)

The `external` listener authenticates the same way (SA token, principal = SA name) but trusts the
**development** cluster instead of the management one: `cluster.external.oauth.validIssuerUri` is the
development API server's issuer (`https://development.kind.local`).

The broker fetches the development JWKS live from the development API server
(`cluster.external.oauth.jwksEndpointUri`, the pinned kind node IP) with the same settings. Both
kind clusters are created with one shared CA (`local/kind/kind-configs/.crt`, see
`setup-clusters.sh`), so the broker pod's own service account CA already trusts that API server. The
clusters keep separate service account signing keys, so their tokens stay distinguishable.

`oauth.fail.fast="false"` on both listeners lets a broker start and keep retrying if an API server
is unreachable or does not yet allow anonymous discovery, instead of exiting.

## Links
- [Strimzi Helm Chart](https://github.com/strimzi/strimzi-kafka-operator)
- [Strimzi Docs](https://strimzi.io/docs/operators/latest/overview)
- [Strimzi OAuth library](https://github.com/strimzi/strimzi-kafka-oauth)
