# Kafka Example: How Data Moves Through the Data Plane

## Scenario

Imagine a food-delivery company. Every time a customer places an order, the application sends an event to Kafka.

We have:

- Topic: `delivery-orders`
- 3 partitions
- 3 Kafka brokers
- Replication factor: 2
- One producer application
- One consumer group called `dispatch-service`

A topic is basically a named stream of related records.

A broker is a Kafka server physically stores and serves that data.

---

## 1. A producer creates a record

A customer places order `ORD-9007`. The producer creates a Kafka record:

```text
Key: customer-42

Value:
{
  "orderId": "ORD-9007",
  "restaurant": "Pizza House",
  "status": "CREATED"
}
```

A Kafka record is never split across partitions. Each record is written entirely to exactly one partition. Suppose the producer's partitioning logic chooses:

```text
delivery-orders, Partition 1
```

So logically:

```text
ORD-9007
   |
   v
Partition 1
```

---

## 2. Partitions are hosted by brokers

A partition is stored on Kafka brokers. Because the replication factor is `2`, Partition 1 has two copies, stored on two brokers.

For example:

```text
Broker 1
└── Partition 1 — LEADER

Broker 3
└── Partition 1 — FOLLOWER
```

The same is true for the other partitions:

```text
Topic: delivery-orders

Partition 0
  Leader   -> Broker 2
  Follower -> Broker 1

Partition 1
  Leader   -> Broker 1
  Follower -> Broker 3

Partition 2
  Leader   -> Broker 3
  Follower -> Broker 2
```

A broker can lead some partitions and be a follower for others.

---

## 3. The producer writes through the partition leader

The producer discovers from Kafka metadata that:

```text
Partition 1 leader = Broker 1
```

It therefore sends `ORD-9007` to Broker 1.

```text
Producer
   |
   | Produce request
   v
Broker 1
└── Partition 1 — LEADER
    └── offset 105 -> ORD-9007
```

Kafka gives the record an offset inside that partition. For example:

```text
Partition 1

offset 103 -> ORD-9003
offset 104 -> ORD-9005
offset 105 -> ORD-9007
offset 106 -> ORD-9010
```

Offsets are local to a partition. `offset 105` in Partition 1 is unrelated to `offset 105` in Partition 0.

---

## 4. The follower replicates the data

Broker 3 has the follower replica of Partition 1. It copies records from the leader:

```text
Broker 1
Partition 1 — LEADER

offset 103 -> ORD-9003
offset 104 -> ORD-9005
offset 105 -> ORD-9007
        |
        | replication
        v
Broker 3
Partition 1 — FOLLOWER

offset 103 -> ORD-9003
offset 104 -> ORD-9005
offset 105 -> ORD-9007
```

So `ORD-9007` logically belongs to one partition, but it may physically exist on multiple brokers because the partition is replicated. The follower is primarily there for replication and failover.

---

## 5. A Python consumer starts

Suppose the dispatch service contains this simplified consumer:

```python
from kafka import KafkaConsumer

consumer = KafkaConsumer(
    "delivery-orders",
    bootstrap_servers=["broker1:9092", "broker2:9092", "broker3:9092"],
    group_id="dispatch-service"
)

for message in consumer:
    print(message.value)
```

The consumer is not saying:

```text
Give me ORD-9007
```

Kafka is not primarily a database where the consumer searches by order ID. Instead, Kafka is a distributed system for storing and delivering a continuous sequence of events between applications.

Applications write events to Kafka, Kafka keeps those events in ordered logs on disk, and other applications read them when they are ready.

So unlike a typical database, where you usually ask for a specific row or object, Kafka is mainly designed for applications to publish events and consume them as a stream over time.

Consumers generally do not query Kafka for a specific record. Instead, they read records sequentially from a partition in offset order, continuing from where they previously stopped.

So the interaction is closer to:

“Give me the next events from where I left off.”

rather than:

“Find this specific record for me.”

Consumers can also move back to an earlier offset and replay previously stored events.

---

## 6. Kafka assigns partitions to consumers

Suppose there are two running instances of the dispatch service:

```text
Consumer A
Consumer B
```

Both belong to:

```text
group.id = dispatch-service
```

Kafka might assign partitions like this:

```text
Partition 0 -> Consumer A
Partition 1 -> Consumer B
Partition 2 -> Consumer A
```

When we say:

```text
Consumer B is assigned Partition 1
```

it simply means:

> Consumer B is the consumer that should fetch and process records from Partition 1 for this consumer group.

It does not mean Consumer B owns or stores the partition. The partition is still stored on Kafka brokers.

Kafka also informs each consumer which partitions it has been assigned. This happens through the consumer group coordination protocol. The consumer communicates with a **group coordinator broker**. During a rebalance, Kafka determines the partition assignments and sends the result back to the consumers.

Conceptually, Consumer B is told:

```text
You are assigned:
Partition 1
```

After that, the Kafka consumer library starts fetching records from Partition 1 on behalf of Consumer B.

The application usually does not handle this low-level protocol itself. The Kafka consumer client library manages the assignment, rebalance, and fetching automatically.

If the application process restarts, its Kafka consumer temporarily disappears from the consumer group. Kafka then detects that the consumer is gone and may trigger a rebalance, redistributing that consumer’s partitions to the remaining consumers.
When the application comes back up:

```text
Consumer B restarts
        ↓
joins group again
        ↓
Kafka may rebalance
        ↓
Consumer B receives a new partition assignment
```

---

## 7. The consumer finds the partition leader

Consumer B needs to read Partition 1. Kafka metadata tells it:

```text
Partition 1 leader = Broker 1
```

So the read path becomes:

```text
Consumer B
    |
    | Fetch request:
    | Partition 1,
    | starting from offset 105
    v
Broker 1
└── Partition 1 — LEADER
```

Broker 1 returns records from that offset onward.

For example:

```text
offset 105 -> ORD-9007
offset 106 -> ORD-9010
offset 107 -> ORD-9011
```

The consumer processes them sequentially.

---

## 8. Kafka does not normally search for a specific record

The consumer usually reads like this:

```text
"Give me records from Partition 1 starting at offset 105."
```

not like this:

```text
"Find order ORD-9007."
```

Kafka is designed around ordered logs. A useful mental model is:

```text
Partition = append-only log

offset 103
offset 104
offset 105
offset 106
...
```

Consumers move through that log.

---

## 9. What happens if the leader fails?

Suppose Broker 1 crashes. Before the failure:

```text
Partition 1

Broker 1 -> Leader
Broker 3 -> Follower
```

Broker 3 already has a replicated copy of the partition. Kafka can elect Broker 3 as the new leader:

```text
Partition 1

Broker 1 -> unavailable
Broker 3 -> NEW LEADER
```

The client refreshes its metadata and learns:

```text
Partition 1 leader = Broker 3
```

The read path then becomes:

```text
Consumer B
    |
    v
Broker 3
└── Partition 1 — NEW LEADER
```

The consumer continues reading from the same partition. The partition did not change. Its leader changed.

---

# The Data Plane

The **data plane** is the part of Kafka that moves the actual application data. In this example, the data plane includes:

```text
Producer
   |
   | Produce request containing ORD-9007
   v
Partition 1 Leader on Broker 1
   |
   | replication
   v
Partition 1 Follower on Broker 3


Consumer B
   |
   | Fetch request
   v
Partition 1 Leader on Broker 1
   |
   | records
   v
Consumer B
```

The important data-plane operations are:

- producers sending records to partition leaders;
- leaders appending records to partition logs;
- followers replicating partition data;
- consumers fetching records from partition leaders;
- clients sending and receiving actual record data.

> Consumer reads records from assigned partitions of a topic. Consumer commits its progress per partition for its consumer group. And importantly, fetching a record and committing an offset are separate operations.

---

# Metadata vs Data Plane

Before a producer or consumer can move records, it needs metadata such as:

```text
Which partitions exist?
Who is the leader of Partition 1?
Which broker should I contact?
Which partitions is this consumer assigned?
```

That information helps the client determine where to send data-plane requests. Then the actual record movement happens through the data plane.

A simplified view:

```text
Metadata knowledge:
"Partition 1 leader is Broker 1"
            |
            v
Data-plane operation:
Consumer -> Broker 1 -> fetch records
```

---

# Complete Picture

```text
                         KAFKA CLUSTER

             Broker 1                    Broker 3
        -------------------          -------------------
        Partition 1 LEADER           Partition 1 FOLLOWER
        offset 104 -> ORD-9005       offset 104 -> ORD-9005
        offset 105 -> ORD-9007 ----> offset 105 -> ORD-9007
        offset 106 -> ORD-9010       offset 106 -> ORD-9010
               ^
               |
               | Produce
               |
            Producer


Consumer B
    |
    | Fetch Partition 1 from offset 105
    v
Broker 1
    |
    +--> ORD-9007
    +--> ORD-9010
```

If Broker 1 fails:

```text
Broker 3 becomes leader for Partition 1

Consumer B
    |
    | metadata refresh
    v
"Partition 1 leader is now Broker 3"
    |
    | Fetch
    v
Broker 3
```

---

# Core Concepts to Remember

| Concept | Meaning |
|---|---|
| Record | One piece of data written to Kafka |
| Topic | Logical stream/category of records |
| Partition | Ordered append-only log inside a topic |
| Offset | Position of a record inside one partition |
| Broker | Kafka server storing partition replicas |
| Partition leader | Broker replica that normally handles reads and writes for that partition |
| Follower replica | Copy that replicates the leader for fault tolerance |
| Producer | Application that writes records |
| Consumer | Application that reads records |
| Consumer group | A group of consumers sharing partition-reading work |
| Partition assignment | Determines which consumer reads which partition |
| Replication | Copies partition data across brokers |
| Data plane | Actual movement of records between producers, brokers, replicas, and consumers |

---

## One-sentence mental model

**A producer writes a record to one partition through that partition's leader; followers replicate it, and a consumer assigned that partition fetches the record from the current leader using offsets.**
