# Messaging: one shared RabbitMQ broker and a reusable topology chart

All workloads share one RabbitMQ broker. A reusable Helm chart lets each workload declare its own topology
(exchanges, queues, users), isolated from the other workloads.

Two pieces:

- **Operators and broker**: `argo_apps/platform/{apps,charts}/03_rabbitmq` (wave 3), one app. It wraps the
  CloudPirates `rabbitmq-cluster-operator` chart, which installs two operators and their CRDs:
  - the Cluster Operator, which turns a `RabbitmqCluster` into the broker StatefulSet.
  - the Messaging Topology Operator, which reconciles `Queue`, `Exchange`, `Binding`, `User`, `Permission` and
    `Vhost`.

  The app also renders the broker itself: the single `RabbitmqCluster` (3 replicas on the
  `longhorn-r2-ephemeral-local` class), the one shared `Vhost` (`apps`), and the broker's `CiliumNetworkPolicy`.
  The cluster has exactly one broker, so it lives in platform. Postgres is different: each workload gets its own.
- **The reusable chart**: `lib/helm/rabbitmq-topology/` (`type: application`, like `pg-cluster` and
  `redis-instance`). A workload consumes it through a `file://` dependency. It declares its topology in a
  `rabbitmq-topology:` values block and needs no template of its own. The sample-user-* workloads use it, see
  [07_sample_workload.md](07_sample_workload.md).

## The two patterns, and who owns what

Isolation depends on two things: who declares the exchange and the queue, and what each user may do. The chart
names its lists after the intent, so ownership lands on the correct side.

| Pattern | Shape | Exchange owned by | Queue owned by | Chart keys |
|---|---|---|---|---|
| Command topic | N publishers to 1 consumer | the consumer | the consumer | consumer: `consumeCommands`. Publishers: `sendCommands` |
| Event topic | 1 publisher to N consumers | the publisher | each consumer, its own | publisher: `publishEvents`. Consumers: `subscribeEvents` |

- **Command topic**: the consumer declares it. Its `consumeCommands` entry declares the exchange, the single
  queue and the binding. It grants the consumer's user `read` on that queue. Each publisher lists the exchange in
  its own `sendCommands`, which grants `write` and nothing else.
- **Event topic**: the publisher declares it. Its `publishEvents` entry declares the exchange and grants the
  publisher `write`. Each consumer declares its own private queue with `subscribeEvents`. The chart names that
  queue `<user>.<exchange>` and binds it to the publisher's exchange. Only that consumer's user gets `read` on it,
  so no consumer can read the queue of another.

Each workload gets exactly one user for all its publish and consume needs. RabbitMQ has one
`configure`/`write`/`read` permission triple per user and vhost, so the chart aggregates:

- `write`: every exchange the workload publishes to, from `publishEvents` and `sendCommands`.
- `read`: every queue it consumes. That is its command queues and its event queues, one per subscription.
- `configure`: always empty. The operator's admin user declares all topology, so an app user never needs it.

The chart escapes regex metacharacters in the generated queue names, so a name matches only itself.

## The reusable chart (`lib/helm/rabbitmq-topology`)

The chart renders the messaging CRs directly. It has no upstream dependency, no `Chart.lock` and no vendored
`charts/`. A consumer declares the `file://` dependency and supplies a values block.

```yaml
# Chart.yaml
dependencies:
  - name: rabbitmq-topology
    version: "*"
    repository: "file://../../../../lib/helm/rabbitmq-topology"
```

The sample shows all three exchange types across three workloads. They form a user-lifecycle loop:
`sample-user-signup` sends to `sample-user-manager`, which sends back to `sample-user-signup` and to
`sample-audit-logger`. The manager is the hub and owns every exchange, one of each type.

```yaml
# sample_user_manager/values.yaml: the hub, command consumer and event/audit publisher
rabbitmq-topology:
  user: sample-user-manager             # default: the release name. Secret: <user>-user-credentials
  consumeCommands:
    - { name: create-user-command }                 # owns it, sole consumer, always direct
  publishEvents:
    - { name: user-events, type: topic }            # owns it, publishes users.created and users.deleted
    - { name: user-audit-logger, type: fanout }     # owns it, broadcast to every subscriber
# Permission write: ^(user-events|user-audit-logger)$, read: ^(create-user-command)$
```

```yaml
# sample_user_signup/values.yaml: command publisher and event/audit consumer
rabbitmq-topology:
  user: sample-user-signup
  sendCommands: [create-user-command]                          # write on the manager's command exchange
  subscribeEvents:
    - { exchange: user-events, routingKey: "users.created" }   # own queue, binds only users.created
    - { exchange: user-audit-logger }                          # fanout ignores routingKey, gets all audits
# write: ^(create-user-command)$, read: ^(sample-user-signup\.user-events|sample-user-signup\.user-audit-logger)$
```

```yaml
# sample_audit_logger/values.yaml: an audit sink with no write permission
rabbitmq-topology:
  user: sample-audit-logger
  subscribeEvents:
    - { exchange: user-audit-logger }                          # fanout, own queue sample-audit-logger.user-audit-logger
# read: ^(sample-audit-logger\.user-audit-logger)$   (no write, it publishes nothing)
```

The loop shows all three exchange types:

| Type | Exchange | Behaviour |
|---|---|---|
| direct | `create-user-command` | point to point |
| topic | `user-events` | signup binds only `users.created`. The manager still publishes `users.deleted`, which reaches no queue, so the broker drops it |
| fanout | `user-audit-logger` | broadcast to two subscribers. Each has its own `<user>.user-audit-logger` queue and cannot read the other |

The broker (`rabbitmq`/`rabbitmq`) and the vhost (`apps`) are platform invariants. The chart hardcodes them for
every workload. It fails the render if a workload sets `cluster` or `vhost`.

### Why there is no permission escape hatch

The chart derives each workload's `Permission` completely, and `configure` is always empty. No knob widens it.
So an app user can never create or delete exchanges, queues or bindings at runtime. It can only publish to and
consume from topology that already exists.

This is a GitOps decision, not a RabbitMQ limit:

- This repo declares every exchange, queue and binding as a Kubernetes manifest.
- Argo CD and the Messaging Topology Operator reconcile them.
- So topology shows in a diff, has versions, and heals itself. The live broker matches git.

Many client libraries declare their own topology by default. That state would live outside git: nobody can
diff it, and nothing prunes it when the app changes. GitOps exists to stop that drift. So configure the app to
attach to existing resources and never to declare them. In Spring AMQP, turn off `RabbitAdmin` auto-declaration
(`shouldDeclare: false`). Every client has an equivalent. A `configure` grant would open that door again.

Two rare patterns need hand-written permissions:

- publishing through the default exchange (`amq.default`).
- direct-reply-to RPC (`amq.rabbitmq.reply-to`).

Neither occurs here. This cluster uses async pub/sub events and N-to-1 commands over declared exchanges. So the
missing escape hatch costs nothing.

## Secrets: generated, never sealed

The `User` CR omits `importCredentialsSecret`. So the Messaging Topology Operator generates a random username and
password into a Secret `<user>-user-credentials` (keys `username`/`password`). The Secret lands in the workload's
own namespace. The pod mounts it through `secretKeyRef`, the same way the app reads CNPG's `<db>-app` Secret.

This is the operator-generated secret class from [03_secrets.md](03_secrets.md). Nothing secret is committed.
There is no `SealedSecret`, no `.env` key and no `seal_secret` call. Sealing is only for secrets that come from
outside the cluster, such as OAuth. RabbitMQ has none.

The operator generates the username too:

- The app reads the username from the Secret and never hardcodes it.
- The `Permission` points at the user through `userReference`, the User CR name, not a literal username.

Only the connection details and `WORKLOAD_NAME` are env vars. The exchange and queue names are compile-time
constants in the binary, so nobody can point a pod at the wrong topic:

```yaml
- name: RABBITMQ_HOST
  value: "rabbitmq.rabbitmq.svc.cluster.local"   # the shared broker client Service
- { name: RABBITMQ_PORT, value: "5672" }
- { name: RABBITMQ_VHOST, value: "apps" }
- name: RABBITMQ_USERNAME
  valueFrom: { secretKeyRef: { name: sample-user-manager-user-credentials, key: username } }
- name: RABBITMQ_PASSWORD
  valueFrom: { secretKeyRef: { name: sample-user-manager-user-credentials, key: password } }
- { name: WORKLOAD_NAME, value: "sample-user-manager" }   # message sender and queue-name prefix
```

On a cold start the pod can sit in `CreateContainerConfigError` for a short time. It recovers by itself once the
operator writes the Secret. The CNPG cold-start note in [07_sample_workload.md](07_sample_workload.md) is the same
case.

## Cross-namespace topology

Each workload lives in its own namespace. The broker lives in `rabbitmq`. Each topology CR sets
`spec.rabbitmqClusterReference: { name: rabbitmq, namespace: rabbitmq }`. The operator accepts that only because
the `RabbitmqCluster` carries `rabbitmq.com/topology-allowed-namespaces: "*"`.

The chart renders the CRs in the workload namespace, not in `rabbitmq`. So the generated
`<user>-user-credentials` Secret lands where the workload's pod can mount it. Nothing copies Secrets across
namespaces.

## Decisions

### Why CloudPirates, not Bitnami or raw manifests

- Bitnami limits its free images to the `latest` tag. That breaks version pinning in this repo.
- The RabbitMQ project ships no Helm chart. It ships only kustomize and plain manifests.
- The CloudPirates `rabbitmq-cluster-operator` chart (OCI at `oci://ghcr.io/cloudpirates-io/helm-charts`) is a
  thin community wrapper. It pins the official upstream images, all multi-arch including arm64:
  - `ghcr.io/rabbitmq/cluster-operator`
  - `ghcr.io/rabbitmq/messaging-topology-operator`
  - `ghcr.io/rabbitmq/default-user-credential-updater`
  - the server, `docker.io/library/rabbitmq` (`-management-alpine`)

The chart is an OCI Helm dependency. Argo CD's repo-server and `helm dependency build` both handle OCI.

### 3 replicas, quorum queues

**Quorum queues** replicate each message by majority vote, so a majority of members must be up.

| Replicas | Majority | Tolerates |
|---|---|---|
| 3 | 2 | losing 1 broker. This is real HA |
| 2 | 2 | nothing. One broker down stalls writes, so you pay for a cluster with no quorum benefit |
| 1 | 1 | nothing. No HA. The operator recommends odd counts |

Hostname anti-affinity puts the 3 brokers on 3 distinct nodes.

The broker makes `quorum` the default type for new queues (`default_queue_type = quorum` in `additionalConfig`).
The topology chart also sets `spec.type: quorum` on every queue.

### Dead-letter queues

Every consumer queue a workload owns gets a dead-letter pair. That is each `consumeCommands` and each
`subscribeEvents` queue.

- a dead-letter exchange `<queue>.dlx` (fanout).
- a dead-letter queue `<queue>.dlq` (quorum).

The chart declares the source queue with `x-dead-letter-exchange: <queue>.dlx` and `x-delivery-limit: 5`. The
chart knobs `deadLetter` and `deliveryLimit` control this. Both are on by default.

A **poison message** is one a consumer fails to process again and again. After 5 delivery attempts the broker
routes it to its DLQ. Without the DLQ, RabbitMQ drops it silently (at-most-once).

- Nothing consumes a DLQ. The `rabbitmq-dlq-not-empty` alert fires on its depth (see
  [06_monitoring.md](06_monitoring.md)). You drain or replay it by hand.
- The admin operator declares the DLX and DLQ, like the rest of the topology. So the app user gets no extra
  permission. The broker dead-letters internally. The app never publishes to the DLX or consumes the DLQ.
- The DLQ has no `x-dead-letter-exchange`, so messages cannot loop.
- Set `deadLetter: false` to turn this off for a workload.

Queue arguments are immutable (see [Caveats](#caveats)). To turn this on for a queue that already exists, delete
that queue once. The operator then declares it again with the arguments.

### Storage: Longhorn, with a local replica

Each broker gets a `10Gi` volume on `longhorn-r2-ephemeral-local`.

Quorum queues already copy every message to all 3 brokers and fsync locally. So volume replication adds nothing
to durability. It exists for recovery. A node-local volume cannot follow its broker to a surviving machine, so
the pod would stay stuck on the dead one until a human wiped it. On Longhorn the new broker reattaches its own
data and rejoins with its Raft log intact. The full reasoning is in [05_storage.md](05_storage.md).

`dataLocality: best-effort` keeps one replica on the broker's own node, so fsync stays on that node's SSD. That
cuts confirm p99 by 31% here. The cost is low: consumers keep the queues drained, so a volume holds almost
nothing, and the copy Longhorn moves on a reschedule is small. Postgres does not get this, for the opposite
reason.

`reclaimPolicy: Delete`, because a broker's volume is disposable in the end. HA is the running quorum. A broker
rebuilt from scratch copies its state from its 2 healthy peers. For the same reason, there are no Longhorn
backups.

Accepted trade-offs:

- While a node is down, there is no spare fault tolerance. A second node loss drops quorum queues below
  majority. They stay unavailable until a majority returns.
- When a broker's machine dies, the broker comes back on a surviving node by itself, with its data. This takes
  about two minutes. Expect one container restart while the startup probe waits for it to catch up. No data is
  lost. See [13_node_loss.md](13_node_loss.md).
- `10Gi` per replica is a ceiling, not a reservation, because Longhorn volumes are thin. The operator hardcodes
  `disk_free_limit.absolute = 2GB`. So publishers block once any broker's volume holds 8Gi. That is the real
  backlog budget. The disk alarm is cluster-wide: one broker over the limit blocks publishers on all brokers.

### One app: operator plus broker

The operators and the broker live in one app, not two. The `RabbitmqCluster` CR cannot reconcile until its CRD
exists and a controller runs. The repo has the same operator-then-CR order for cert-manager and `03_gateway`.
Here the single app handles the order, not the waves:

- Argo CD applies CRDs before other resources (kind order). So the subchart's `RabbitmqCluster` and `Vhost` CRDs
  exist before the CRs in the same sync.
- Both CRs carry `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`. On a cold boot the CRD is
  not registered yet at dry-run time. This option stops the sync from failing on the unknown type.
- `selfHeal` and sync retry then converge. The CR settles as soon as the operator pod is up and its CRD is
  established. The chart uses no resource-level sync-waves.

The topology operator gets its admission-webhook cert from cert-manager (`useCertManager: true`). The chart's
self-signed path mints the cert at render time. Argo CD would render a new cert on every reconcile. The Secret
and caBundle would stay OutOfSync, and topology CR writes would fail for short periods. The cost is a dependency
on cert-manager, which is in wave 2. Waves only order creation. So on a cold boot the Certificate can stay pending
until the app's retry converges.

Workloads carry no wave. The root-of-roots creates the workloads tree about 5s after the platform root. It does
not wait for the platform to be Healthy. So a workload's topology CRs can land before the operators and the vhost
exist. That sync fails and retries (`limit: -1`) until they do.

### Network policy

The broker's `CiliumNetworkPolicy` denies everything in both directions by default, then allows:

| Port | From or to | Why |
|---|---|---|
| AMQP `5672` | any pod labelled `messaging-client: "true"` | a new messaging workload needs no change to this platform app. The workload labels its pod and adds a matching egress rule, as the sample workloads do |
| Management `15672` | Envoy, and the operators in the same namespace | the SSO-gated UI and topology reconcile |
| Metrics `15692` | vmagent | scraping |
| all ports | the broker's own pods | clustering uses several ports (4369 epmd, 25672 inter-node, the CLI). A missed port could break quorum formation |
| egress | DNS, the API server entity, peers | |

Roll it out in audit mode first, like every network policy here:

1. Put the broker in `PolicyAuditMode`.
2. Run `hubble observe --verdict DROPPED,AUDIT` while the cluster forms, a client connects and the UI loads.
3. Enforce once the output is clean.

The broker policy selects broker pods only, so it does not cover the two operators. Each operator has its own
policy (`networkpolicy-cluster-operator.yaml` and `networkpolicy-topology-operator.yaml`). Each allows only what
that operator uses:

- the metrics scrape, cluster operator only. The topology operator's metrics endpoint needs TLS, so nothing
  scrapes it.
- the admission webhook, topology operator only.
- the kubelet health probe.
- DNS and the API server.
- the broker management API on `15672`, topology operator only.

The subchart's bundled vanilla `NetworkPolicy` objects are off (`...networkPolicy.enabled: false`). They allow
all egress by default, and Cilium unions them with our CNPs. That would open the default-deny. Argo CD pins
`global.networkPolicy.create: false` for the same reason. See [01_networking.md](01_networking.md).

### Management UI

The UI works like the other platform UIs. A `rabbitmq` host on the platform ingress (`06_platform_ingress`,
wave 6) points at the broker's `15672` service. `04_google_sso` (wave 4) gates it centrally.

1. Edge SSO gates the network path.
2. RabbitMQ then shows its own login. Sign in with the operator-generated admin credentials from the
   `rabbitmq-default-user` Secret.

The platform ingress is the last wave, so the broker exists long before it.

## Apply and verify

1. Run `helm dependency build argo_apps/platform/charts/03_rabbitmq` and commit the new `Chart.lock`. Argo CD's
   repo-server runs `helm dependency build`, and a missing or stale lock breaks sync. The workload charts use only
   `file://` dependencies and have no lock, so they need nothing.
2. Run `git add -A && git commit && git push`. Argo CD reconciles the pushed remote, not your working tree.

Checks, with `export KUBECONFIG=.cache/kubeconfig` (the pinned kubeconfig that `lib/shell/common.sh` writes):

- `kubectl -n rabbitmq get pods`: 2 operator pods Running. `rabbitmq-server-0..2` Running on 3 distinct nodes.
- `kubectl -n rabbitmq get rabbitmqcluster,vhost`: `AllReplicasReady=True`, vhost `apps` Ready.
- `kubectl -n sample-user-manager get
  user.rabbitmq.com,exchange.rabbitmq.com,queue.rabbitmq.com,binding.rabbitmq.com,permission.rabbitmq.com`: all
  `Ready=True`. Three exchanges (`user-events`, `user-audit-logger`, `create-user-command`) and one command queue.
  Check `sample-user-signup` and `sample-audit-logger` the same way for each subscriber's user, queues, bindings
  and permission.
- `kubectl -n sample-user-manager get secret sample-user-manager-user-credentials`: exists, with
  `username`/`password`. The manager pod is Running with the `RABBITMQ_*` env vars set.
- Live loop:
  - `kubectl -n sample-user-signup logs deploy/sample-user-signup` shows it publish `create-user-command` every
    10s. It also receives `users.created` and audit messages.
  - `kubectl -n sample-user-manager logs deploy/sample-user-manager` shows it store users and emit events. Past
    10 users it evicts the oldest with `users.deleted` and an audit message.
  - `kubectl -n sample-audit-logger logs deploy/sample-audit-logger` shows audit messages only.
  - `curl https://sample-user-manager.app.example.com/users` returns the JSON user list.
- Topology and isolation: `kubectl -n rabbitmq exec rabbitmq-server-0 -c rabbitmq -- rabbitmqctl list_permissions
  -p apps`. Each workload user has only its own `read`/`write` regexes, and `configure` is empty. The audit logger
  has `read` only.
- Management UI at `https://rabbitmq.ops.example.com/`: Google login, then the RabbitMQ login, then the `apps`
  vhost with the workload users, queues and exchanges. Get the RabbitMQ credentials with
  `kubectl -n rabbitmq get secret rabbitmq-default-user -o jsonpath='{.data}'` and base64-decode them.

## Caveats

- **Message flow**: the sample image speaks AMQP across three binaries. So the loop tests the topology CRs, the
  generated credentials and real publish and consume, end to end. Tail the logs of the three deployments to watch
  it. `users.deleted` reaches no consumer (topic routing). Every audit message reaches both subscribers (fanout).
- **Queue properties are immutable once declared.** The operator does not change a live queue. To change a
  queue's `type`, `durable` or `arguments`, delete and re-create the `Queue` CR. Plan queue names up front.
  - Turning on the DLQ pattern for existing queues needs a one-time delete of those queues. The operator then
    re-creates them with the dead-letter arguments.
  - Delete them in the management UI, or delete and re-sync the `Queue` CRs. The sample queues are empty, so
    nothing is lost.
- **Editing the generated credentials Secret does nothing.** The operator does not watch it. To rotate, add a
  label or annotation to the `User` CR to force a reconcile, or re-create the CR.
- **Publishers do not block at the memory limit.** Request equals limit, so the limit is the node capacity the
  broker gets.
  - The operator's default counts only 0.8x of the limit as available. That compounds with the watermark, and
    publishers would block at 0.64x the limit. So the chart sets `total_memory_available_override_value` to the
    full limit.
  - That leaves one knob. Publishers block at `vm_memory_high_watermark.relative`, 0.85x the limit. The last
    15% absorbs GC overshoot before the kernel OOMKills the broker.
  - The chart derives both values from `resources.limits.memory`, so that value must stay in `Mi`.
  - Sizing comes from measured RSS. An idle 3-node broker swings between 105Mi and 280Mi. That is Erlang code,
    allocator slack and quorum ETS tables, not queue contents. Live data is only about 75Mi. The rest is slack
    the allocator has not returned.
  - Do not set `vm_memory_calculation_strategy = allocated` to hide the swing. It would read the 75Mi and never
    fire, while the kernel still kills on RSS.
- **Every Secret the operator reads must carry `rabbitmq.com/topology-operator: "true"`.** The operator's
  informer caches no other Secrets.
  - Without the label, the operator cannot see the Secret. It retries CREATE forever against `already exists`.
    The `User` stays `Ready: False`. Argo CD shows a Degraded app but names no unhealthy child.
  - Only hand-written or restored Secrets hit this. Generated ones carry the label.
  - Fix: `kubectl -n <ns> label secret <name> rabbitmq.com/topology-operator=true`.
- **Never emit empty `Permission` fields.** They cause a permanent OutOfSync.
  - RabbitMQ treats a missing `configure`, `write` or `read` as `""`, which means no access. The topology
    operator drops empty strings from the stored object.
  - A manifest with `configure: ""`, the usual case, makes Argo CD own a field the live object does not have. The
    `Permission` then stays OutOfSync forever. In practice this is only `configure`, since `write` and `read` are
    not empty.
  - So the chart emits only the non-empty permission fields, and the manifest matches what the operator stores.
  - Do not add empty fields back. Do not hide the diff with an Argo CD `ignoreDifferences`. Matching the stored
    shape is the correct fix.
- **Delete `Permission` before `User`.** Otherwise the `Permission` can hang in `Terminating`.
  - On teardown the operator needs the user's credentials to remove the permission inside RabbitMQ. If the `User`
    and its Secret go first, the `Permission` finalizer cannot complete.
  - All of a workload's topology syncs in one wave today. So this only happens on a manual delete in the wrong
    order.
  - Clear it with `kubectl patch permission <name> -p '{"metadata":{"finalizers":[]}}' --type=merge`.
  - If it becomes routine, add sync-waves to the chart with `User` in a lower wave than `Permission`. Prune runs
    in reverse wave order, so it then removes `Permission` first. See rabbitmq/messaging-topology-operator#324.
- **`prune` deletes the `RabbitmqCluster` CR and its data, by design.** The broker PVCs use the
  `longhorn-r2-ephemeral-local` class (`Delete`). A prune removes them, and no volume is left to recover.
  - That is intended. HA is the running quorum, not the volume. A re-created broker rebuilds its state from the
    healthy peers.
  - CNPG's class is `Delete` too. The DB unit's `deletionProtection` protects Postgres data from a prune, not
    the reclaim policy. See [05_storage.md](05_storage.md).
