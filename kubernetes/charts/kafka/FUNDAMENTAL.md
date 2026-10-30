# Kafka Fundamentals
# 1. KRaft vs. Zookeeper

**KRaft replaces ZooKeeper as Kafka’s metadata/cluster coordination system.**

| ZooKeeper-based Kafka | KRaft |
|---|---|
| Kafka + separate ZooKeeper cluster | Kafka manages metadata itself |
| More components to deploy/monitor | Simpler architecture |
| Metadata stored in ZooKeeper | Metadata stored in Kafka’s internal Raft log |
| Controller failover can be slower | Faster controller election/failover |
| Scaling metadata can become a bottleneck | Designed for larger Kafka clusters |

Main ZooKeeper downsides that KRaft addresses:

- **Operational complexity** → no separate ZooKeeper cluster.
- **Two systems to configure/security-monitor** → one Kafka system.
- **Slower metadata/controller recovery** → Raft-based controllers recover faster.
- **Metadata scalability limits** → KRaft is designed to handle larger Kafka clusters.

In short:

**ZooKeeper = external coordination**  
**KRaft = Kafka-native consensus and metadata management**

## 2. What is a metadata / cluster coordination system?

A **metadata / cluster coordination system** is basically the **control center** of a distributed system.

It usually does not hold the main user data. Instead, it keeps track of things like:

- which machines are currently alive
- which machine is responsible for which data
- who is the current leader/controller
- where partitions or replicas are located
- what configuration the cluster should use
- what to do when a machine fails or joins

A useful mental model:

**Data plane** = does the actual work and stores/serves data.  
**Coordination/metadata plane** = keeps everyone organized and in agreement.

For example, in a Kafka cluster with several brokers, the coordination system may maintain facts such as:

- “Broker 2 is the leader for partition 7.”
- “Broker 4 has failed.”
- “Broker 3 should become the new leader.”
- “These are the current topics and partitions.”

ZooKeeper used to provide this coordination externally.

KRaft moves that coordination logic inside Kafka itself.

---

## 3. Why did Kafka originally use ZooKeeper?

When Kafka was first designed, **building a correct distributed consensus and coordination system was a difficult problem that ZooKeeper already solved well**.

Kafka needed a reliable way for multiple brokers to agree on things like:

- which brokers are alive
- who is the controller
- where partitions live
- what happens when a broker dies

Instead of building all of that machinery from scratch, Kafka reused **ZooKeeper**, which was specifically designed for distributed coordination.

The original architecture was roughly:

**Kafka = messaging/data system**  
**ZooKeeper = coordination/consensus system**

This was a practical engineering choice because Kafka developers could focus on building a fast distributed log rather than also implementing their own consensus layer.

Over time, Kafka became much more mature. ZooKeeper then started adding operational complexity:

- two distributed systems to operate
- separate configuration
- separate security
- separate monitoring
- metadata scalability and recovery limitations

Kafka eventually gained its own consensus protocol based on **Raft**. That became **KRaft**. So the evolution is:

**Initially:** “Don’t reinvent distributed consensus; use ZooKeeper.”  
**Later:** “Kafka is mature enough to manage consensus and metadata itself.”

A bit more about the operational complexity mentioned above: with ZooKeeper-based Kafka, operators effectively had to run and maintain two separate distributed systems:

- a Kafka cluster of brokers
- a ZooKeeper ensemble

That created operational complexity because each system had its own configuration, health model, networking, security, upgrades, and failure modes.

Imagine something goes wrong in production and Kafka starts behaving strangely. Maybe a broker keeps disconnecting, controller elections are unstable, or consumer lag suddenly jumps. 

The tricky part with ZooKeeper was that the issue might not even be in Kafka itself. You had to check the brokers, the ZooKeeper cluster, expired sessions, network connectivity between them, TLS or ACL problems, and whether the controller was having trouble reading or updating metadata.

Even when nothing was broken, you were still operating two separate systems. 

Kafka and ZooKeeper had their own monitoring, scaling, security, upgrades, backups, and recovery procedures. So a simple Kafka maintenance task could turn into checking version compatibility, quorum health, rolling restarts, and metadata safety across both systems. 

KRaft simplifies this by keeping the metadata and controller coordination inside Kafka instead of depending on a separate ZooKeeper cluster.

---

## 4. Why is controller election and failover faster with KRaft?

With **ZooKeeper**, controller failover involved coordination through an **external system**.

Roughly:

1. ZooKeeper detects that the controller or broker is gone.
2. Kafka brokers learn about the change through ZooKeeper.
3. A new controller is elected.
4. The new controller loads or reconstructs cluster metadata.
5. It resumes making cluster-level decisions.

This introduces extra network communication and state synchronization.

A bit more about it: in ZooKeeper-based Kafka, brokers and controllers detected changes in the cluster and got information about those changes through **ZooKeeper**.

Technically, Kafka used **ZooKeeper znodes + watches + sessions**.

- Brokers registered themselves in ZooKeeper using ephemeral znodes.
- Kafka components placed watches on relevant znodes.
- When a broker died, its ZooKeeper session expired, so its ephemeral znode disappeared.
- ZooKeeper then triggered watch notifications to interested Kafka components.
- The Kafka controller reacted to those notifications and updated partition leadership / assignments as needed.

So the pattern was:
broker state written to ZooKeeper → Kafka watches ZooKeeper → ZooKeeper notifies on change → controller reacts

- **znode**: a small data node inside ZooKeeper, similar to a file/path in a filesystem. Kafka stored coordination data there, such as broker registration or controller information.
- **watch**: a notification subscription on a znode. Kafka could say, essentially, “tell me if this node changes or disappears.”
- **session**: a live connection between a Kafka broker and ZooKeeper. ZooKeeper tracks whether that client is still alive.
The important part is ephemeral znodes: they exist only while the client’s ZooKeeper session is alive.
So if Broker 2 crashes:
Broker 2 session expires → its ephemeral znode disappears → ZooKeeper triggers watches → Kafka learns Broker 2 is gone.

A **znode** as a tiny file-like entry inside ZooKeeper.

It has:
- a path, like `/brokers/ids/2`
- a small value, like `brokerId=2, host=broker2, port=9092`
- some metadata

So ZooKeeper can look conceptually like:

```text
/
├── brokers
│   └── ids
│       ├── 1
│       ├── 2
│       └── 3
└── controller
```

Here, `/brokers/ids/2` is a znode representing Broker 2.
A znode is not a normal disk file. It is just a small coordination record stored in ZooKeeper’s distributed data tree.
The easiest mental model is:

znode = tiny distributed config/state entry identified by a path.

When a Kafka broker starts in ZooKeeper-based Kafka:

1. The broker connects to ZooKeeper and opens a session.
2. The broker sends a request to ZooKeeper to create an ephemeral znode, for example:
   `/brokers/ids/2`
3. ZooKeeper creates that znode and ties it to that broker’s session.
4. If the broker crashes and the session expires, ZooKeeper automatically deletes the znode.

So it is:
Broker asks ZooKeeper to create znode → ZooKeeper stores it and manages its lifetime
ZooKeeper does not first “discover” the broker on its own. The broker explicitly registers itself.

A ZooKeeper session is a logical client connection between a Kafka broker and the ZooKeeper cluster.
When the broker connects, ZooKeeper gives it a session ID. The broker then keeps that session alive by regularly communicating with ZooKeeper, typically through heartbeats/pings over its TCP connection.
If ZooKeeper stops hearing from the broker for longer than the configured session timeout, it considers that session expired.
Then ZooKeeper automatically removes any ephemeral znodes owned by that session.

So:
Broker ↔ ZooKeeper connection + session ID + heartbeat/timeout = ZooKeeper session
It’s basically ZooKeeper’s way of knowing: “Is this client still alive?”

Networking-wise, it means the Kafka broker has a TCP connection open to a ZooKeeper server, and small ZooKeeper protocol messages travel over that connection.
A heartbeat/ping is basically:
Broker → TCP socket → ZooKeeper: “I’m still here.”
ZooKeeper replies, and as long as this communication keeps happening within the session timeout, the session stays alive.

Important distinction:

- TCP gives them the reliable byte connection.
- ZooKeeper client-server protocol defines what the ping/request messages mean.
- The ping is not a TCP-level heartbeat; it is an application-level ZooKeeper message sent over TCP.

Now **KRaft** comes in..

With KRaft, controllers themselves maintain metadata using a replicated **Raft log**.

Standby controllers continuously follow the latest metadata.

So when the active controller dies, another controller can become leader while already having nearly all of the required state in memory.

Rough comparison:

**ZooKeeper**: fail → external coordination → reload/sync metadata → resume
**KRaft**: fail → elect new Raft leader → resume

That tighter integration is why controller election and failover are generally faster.

---

## 5. How did Kafka coordinate with ZooKeeper?

Kafka and ZooKeeper communicated using a **client-server protocol over TCP**, through the ZooKeeper client library.

The coordination itself happened through small pieces of metadata stored in ZooKeeper called **znodes**.

Examples:

- Kafka broker starts → registers itself in ZooKeeper.
- Controller election → brokers coordinate through a special znode.
- Broker dies → its ephemeral znode disappears when its ZooKeeper session expires.
- Kafka components watch znodes and are notified when things change.

The rough flow was:

**Kafka broker → ZooKeeper client protocol → read/write/watch znodes → ZooKeeper notifies Kafka of changes**

ZooKeeper was not forwarding Kafka messages.

It behaved more like a **shared, strongly consistent coordination database with watches and session tracking**.

---

## 6. What is a broker?

A **broker** is simply a **Kafka server**.

If you have a Kafka cluster with three Kafka servers, you may have:

- Broker 1
- Broker 2
- Broker 3

Brokers store topic partitions and handle reads and writes from producers and consumers.

---

## 7. What is a controller?

The **controller** is a special Kafka role responsible for cluster-level decisions.

It manages things such as:

- which broker leads each partition
- what happens when a broker fails
- partition leadership changes
- metadata about the cluster

With older ZooKeeper-based Kafka, the controller was still part of **Kafka**, not ZooKeeper.

ZooKeeper simply helped Kafka coordinate controller election and cluster state.

A simple summary:

**Broker = Kafka server doing the data work**  
**Controller = Kafka’s cluster manager/leader**  
**ZooKeeper = external coordination service that helped Kafka manage leadership/state**

With KRaft, Kafka controllers coordinate directly using Raft, so ZooKeeper is no longer needed.

---

## 8. What does it mean for a broker to lead a partition?

A **partition** is a way Kafka splits one topic into smaller pieces so the work can be distributed across multiple brokers.

Imagine a topic called:

`orders`

Kafka might split it into:

- `orders-partition-0`
- `orders-partition-1`
- `orders-partition-2`

Each partition is essentially an **ordered append-only log of messages**.

A real-world example:

An online store produces millions of orders.

Kafka may distribute those records across several partitions so multiple brokers can process traffic in parallel.

For fault tolerance, partitions are usually **replicated** across brokers.

Example:

- Partition 0 exists on Broker 1, Broker 2, Broker 3
- Broker 1 is the **leader**
- Broker 2 and Broker 3 are **followers/replicas**

Clients normally read and write through the **leader**.

The followers continuously copy the leader’s data.

If Broker 1 fails, Kafka can promote Broker 2 or Broker 3 to become the new leader.

That is what we mean by:

**“Which broker leads each partition?”**

Useful mental model:

**Topic = book**  
**Partitions = chapters**  
**Brokers = shelves holding copies**  
**Leader = authoritative copy for that chapter**

---

## 9. What is a replicated Raft log?

A **replicated Raft log** is a shared, ordered history of Kafka cluster metadata changes that is copied across multiple KRaft controllers.

Example log entries could be:

- “Broker 3 joined”
- “Partition 5 leader is Broker 2”
- “Broker 1 failed”
- “Make Broker 4 the new leader for Partition 7”

These entries are replicated across controllers so they remain almost continuously synchronized.

For example:

- Controller A - leader
- Controller B - follower
- Controller C - follower

All three follow the same Raft metadata log.

If Controller A dies, Controller B or C can become the new Raft leader.

Because the new leader already has nearly the same metadata and state, it can take over quickly.

This is the core reason KRaft speeds up controller failover:

**ZooKeeper:** new controller → fetch/rebuild state → take over  
**KRaft:** standby already has state → elect leader → take over

Raft handles both:

- metadata replication
- controller election

inside one tightly integrated system.

---

## 10. How is Kafka data preserved when a broker fails?

Kafka protects data mainly through **replication**.

Suppose a partition has a replication factor of **3**.

You might have:

- Partition 0 on Broker 1 - leader
- Partition 0 on Broker 2 - follower
- Partition 0 on Broker 3 - follower

Followers continuously copy new records from the leader.

If Broker 1 fails, Kafka can promote one of the synchronized followers, for example Broker 2, to become the new leader.

Clients then continue reading and writing through Broker 2.

A key concept is **ISR - In-Sync Replicas**.

These are replicas that are sufficiently caught up with the leader.

Kafka normally prefers to elect a new leader from the ISR because that replica has the latest committed data.

The core protection model is:

**one partition → multiple copies on different brokers**

Producer settings such as `acks=all` can make Kafka wait until enough replicas acknowledge a write before treating it as successful.

That reduces the chance of losing recently written data if a broker crashes.

So:

**Broker failure does not normally mean data loss, because another broker has a replicated copy.**

---

## 11. What actual data is stored in a Kafka partition?

A Kafka partition stores a sequence of **records/messages**.

Example topic:

`orders`

A partition might conceptually contain:

```text
Offset 0:
key = "customer-123"
value = {"orderId": 1001, "item": "Laptop", "price": 1200}

Offset 1:
key = "customer-456"
value = {"orderId": 1002, "item": "Mouse", "price": 25}

Offset 2:
key = "customer-123"
value = {"orderId": 1003, "item": "Keyboard", "price": 80}
```

Important pieces of each Kafka record include:

- **key** - optional; often helps determine which partition receives the record
- **value** - the actual application data
- **offset** - the record’s position inside that partition
- **timestamp**
- **headers**
- internal integrity information such as checksums

Conceptually, a partition looks like:

```text
Partition 0

[0] order 1001
[1] order 1002
[2] order 1003
[3] order 1004
...
```

Kafka stores these records on disk in **segment files** on the broker.

If the replication factor is 3, roughly the same partition log exists on three brokers:

```text
Broker 1: Partition 0 -> [0][1][2][3]
Broker 2: Partition 0 -> [0][1][2][3]
Broker 3: Partition 0 -> [0][1][2][3]
```

That replication protects the data when a broker fails.

---

## 12. Does Kafka use disk or memory?

Kafka uses **both**, but **disk is the durable source of truth**.

Messages are written to disk in partition log files so they survive broker restarts and crashes.

Memory is heavily used for performance, especially through the operating system’s **page cache**.

Frequently accessed Kafka data may already be in RAM, which allows reads to be very fast without Kafka needing to keep its own full in-memory copy.

A useful summary:

**Disk = durability**  
**Memory/page cache = speed**

That is one reason Kafka can handle datasets much larger than available RAM.

---
