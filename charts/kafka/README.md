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

## Links
- [Strimzi Helm Chart](https://github.com/strimzi/strimzi-kafka-operator)
- [Strimzi Docs](https://strimzi.io/docs/operators/latest/overview)
