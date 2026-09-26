# Messaging: one shared RabbitMQ broker and a reusable topology chart

All workloads share one RabbitMQ broker. Each workload declares its own exchanges, queues and user through a shared
chart, isolated from the other workloads. To deploy, check or fix it, see
[runbooks/08_messaging.md](runbooks/08_messaging.md).

| Piece | Where | What |
|---|---|---|
| Operators and broker | `argo_apps/platform/{apps,charts}/03_rabbitmq`, wave 3 | The Cluster Operator, the Messaging Topology Operator, one 3-broker `RabbitmqCluster` and the shared `apps` vhost |
| Topology chart | `lib/helm/rabbitmq-topology` | A workload's user, exchanges, queues, bindings and one `Permission`, from a values block |

The cluster has one broker, so it lives in platform. Postgres is different: each workload owns its own.

## Who owns what

Isolation rests on two things: who declares the exchange and the queue, and what each user may do.

| Pattern | Shape | Exchange owner | Queue owner | Chart keys |
|---|---|---|---|---|
| Command | N publishers to 1 consumer | the consumer | the consumer | consumer: `consumeCommands`. Publishers: `sendCommands` |
| Event | 1 publisher to N consumers | the publisher | each consumer, a private one | publisher: `publishEvents`. Consumers: `subscribeEvents` |

- Each workload gets exactly one user. It may write to the exchanges it publishes to and read the queues it
  consumes. No consumer can read another consumer's queue.
- The sample workloads use one exchange of each type: a direct command exchange, a topic event exchange and a fanout
  audit exchange. The manager owns all three. See `argo_apps/workloads/charts/*/values.yaml`.

## Decisions

### No runtime topology changes

An app user never gets `configure`, and no knob adds it. So an app can publish to and consume from declared
topology, but cannot create or delete it.

This is a GitOps choice, not a RabbitMQ limit. Every exchange, queue and binding is a manifest that Argo CD and the
topology operator reconcile. Topology then shows in a diff and heals itself. Many client libraries declare their own
topology by default, which would live outside git. So configure the app to attach to existing resources only. In
Spring AMQP, that is `shouldDeclare: false`.

Publishing through the default exchange and direct-reply-to RPC would need hand-written permissions. This cluster
uses neither.

### Generated credentials, never sealed

The topology operator generates each workload's username and password into `<user>-user-credentials`, in the
workload's namespace. Nothing secret is in git, and there is no `.env` key. Sealing is only for secrets that come
from outside the cluster. See [03_secrets.md](03_secrets.md).

### CloudPirates chart, not Bitnami or raw manifests

- Bitnami limits its free images to the `latest` tag, which breaks version pinning.
- The RabbitMQ project ships only kustomize and plain manifests, no Helm chart.
- The CloudPirates `rabbitmq-cluster-operator` chart is a thin OCI wrapper. It pins the official upstream images,
  all multi-arch.

### 3 brokers with quorum queues

A quorum queue needs a majority of brokers up.

| Brokers | Survives |
|---|---|
| 3 | the loss of 1 broker |
| 2 | nothing. One broker down stalls writes |
| 1 | nothing |

Anti-affinity puts the 3 brokers on 3 nodes. Every queue is a quorum queue.

### A dead-letter queue per consumer queue

A poison message is one a consumer fails on again and again. Without a dead-letter queue, RabbitMQ drops it after
the delivery limit, with no trace. So every consumer queue gets a `<queue>.dlx` exchange and a `<queue>.dlq` queue,
and a message moves there after 5 failed deliveries. Nothing consumes a DLQ. The `rabbitmq-dlq-not-empty` alert fires
on its depth, and you drain or replay it by hand.

### Longhorn with a local replica, no backups

Quorum queues already copy every message to 3 brokers, so volume replication adds no durability. Longhorn is there
for recovery. A node-local volume cannot follow its broker to another node. See [05_storage.md](05_storage.md).

- `longhorn-r2-ephemeral-local` keeps one replica on the broker's own node. That cut confirm p99 by 31%.
- The volumes use `reclaimPolicy: Delete`, and there are no Longhorn backups. A rebuilt broker copies its state from
  its 2 peers. For the same reason, a prune deletes the broker and its data by design.
- While a node is down, a second node loss stalls the quorum queues until a majority returns.
- A broker on a dead node comes back on another node by itself in about 2 minutes, with no data lost. See
  [13_node_loss.md](13_node_loss.md).

### One app for the operators and the broker

The `RabbitmqCluster` needs its CRD and a running operator. One app holds both, so a single sync applies the CRDs
first and retry converges the rest. The app uses no resource-level sync waves.

### Network policy

The broker denies everything in both directions, then allows what RabbitMQ needs.

- Any pod labelled `messaging-client: "true"` may open AMQP. A new messaging workload needs no change to the
  platform app.
- Brokers reach each other on all ports. A missed clustering port could break quorum formation.
- Each operator has its own default-deny policy.
- The subchart's vanilla `NetworkPolicy` objects are off. They allow all egress, and Cilium merges them with the
  default-deny policies. See [01_networking.md](01_networking.md).

### Management UI behind SSO

The UI is a host on the platform ingress, gated by the central Google SSO. RabbitMQ then shows its own login, with
the operator-generated admin credentials.
