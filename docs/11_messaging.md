# 11: messaging, one shared RabbitMQ broker + a reusable topology chart

One RabbitMQ broker every workload shares, plus a reusable Helm chart that lets a workload declare its own
topology (exchanges, queues, users) with isolation from the others.

Two pieces:

- Operators plus broker: `argo_apps/platform/{apps,charts}/03_rabbitmq` (wave 3), ONE app. It wraps the
  CloudPirates `rabbitmq-cluster-operator` chart, which installs both the Cluster Operator (reconciles
  `RabbitmqCluster` into the broker StatefulSet) and the Messaging Topology Operator (reconciles
  `Queue`/`Exchange`/`Binding`/`User`/`Permission`/`Vhost`) plus their CRDs. It also renders the broker itself: the
  single `RabbitmqCluster` (3 replicas on the node-local `local-path-ephemeral` class), the one shared `Vhost`
  (`apps`), and the broker's `CiliumNetworkPolicy`. Exactly ONE broker for the whole cluster, unlike Postgres
  which is per-workload, so it lives in platform.
- The reusable chart: `lib/helm/rabbitmq-topology/` (`type: application`, like `pg-cluster` and
  `redis-instance`). A workload consumes it via a `file://` dependency and declares its topology in a
  `rabbitmq-topology:` values block, with no template of its own. Demonstrated by the sample-user-* workloads, see
  [10_sample_workload.md](10_sample_workload.md).

## The two patterns, and who owns what

Separation comes down to who declares the exchange and the queue, and what each user may do. The chart encodes
both patterns as intent-named lists so ownership lands on the correct side.

| Pattern | Shape | Exchange owned by | Queue owned by | Chart keys |
|---|---|---|---|---|
| Command topic | N publishers to 1 consumer | the consumer | the consumer | consumer: `consumeCommands`; publishers: `sendCommands` |
| Event topic | 1 publisher to N consumers | the publisher | each consumer, its own | publisher: `publishEvents`; consumers: `subscribeEvents` |

- A command topic is instantiated and configured on the CONSUMER. Its `consumeCommands` entry declares the
  exchange, its single queue and the binding, and grants the consumer's user `read` on that queue. Every publisher
  merely lists the exchange in its own `sendCommands`, which grants `write` and nothing else.
- An event topic is created on the PUBLISHER. Its `publishEvents` entry declares the exchange and grants the
  publisher `write`. Each consumer declares its OWN private queue via `subscribeEvents`, auto-named
  `<user>.<exchange>` and bound to the publisher's exchange, and only that consumer's user is granted `read` on
  it. So one consumer can never read another's queue.

Each workload gets exactly ONE user, reused across all its publish and consume needs. RabbitMQ has a single
`configure`/`write`/`read` permission triple per user and vhost, so the chart aggregates:

- `write`: every exchange the workload publishes to, from `publishEvents` plus `sendCommands`.
- `read`: every queue it consumes, meaning its command queues plus its per-subscription event queues.
- `configure`: always empty. The operator's admin user declares all topology, so an app user never needs it.

Regex metacharacters in the auto-generated queue names are escaped, so a name matches only itself.

## The reusable chart (`lib/helm/rabbitmq-topology`)

Renders the messaging CRs directly: no upstream dependency, no `Chart.lock`, no vendored `charts/`. A consumer
declares the `file://` dependency and supplies a values block.

```yaml
# Chart.yaml
dependencies:
  - name: rabbitmq-topology
    version: "*"
    repository: "file://../../../../lib/helm/rabbitmq-topology"
```

The sample demonstrates all three exchange types across three real workloads, a user-lifecycle loop from
`sample-user-signup` to `sample-user-manager` and back out to `sample-user-signup` and `sample-audit-logger`. The
manager is the hub and owns every exchange, one of each type.

```yaml
# sample_user_manager/values.yaml: the hub, command consumer + event/audit publisher
rabbitmq-topology:
  user: sample-user-manager             # defaults to the release name; Secret <user>-user-credentials
  consumeCommands:
    - { name: create-user-command }                 # OWNS + sole consumer; always direct
  publishEvents:
    - { name: user-events, type: topic }            # OWNS; publishes users.created AND users.deleted
    - { name: user-audit-logger, type: fanout }     # OWNS; broadcast to every subscriber
# Permission write: ^(user-events|user-audit-logger)$, read: ^(create-user-command)$
```

```yaml
# sample_user_signup/values.yaml: command publisher + event/audit consumer
rabbitmq-topology:
  user: sample-user-signup
  sendCommands: [create-user-command]                          # write on the manager's command exchange
  subscribeEvents:
    - { exchange: user-events, routingKey: "users.created" }   # own queue; binds ONLY users.created
    - { exchange: user-audit-logger }                          # fanout: routingKey ignored; gets all audits
# write: ^(create-user-command)$, read: ^(sample-user-signup\.user-events|sample-user-signup\.user-audit-logger)$
```

```yaml
# sample_audit_logger/values.yaml: a pure audit sink, no write permission at all
rabbitmq-topology:
  user: sample-audit-logger
  subscribeEvents:
    - { exchange: user-audit-logger }                          # fanout; own queue sample-audit-logger.user-audit-logger
# read: ^(sample-audit-logger\.user-audit-logger)$   (no write, it publishes nothing)
```

That is the teaching payoff, all three types in one loop:

- direct (`create-user-command`), point-to-point.
- topic (`user-events`), where signup binds only `users.created`, so `users.deleted`, which the manager still
  publishes, reaches no queue and the broker drops it.
- fanout (`user-audit-logger`), broadcast to two independent subscribers, each with its own
  `<user>.user-audit-logger` queue, so neither can read the other's.

The broker (`rabbitmq`/`rabbitmq`) and the vhost (`apps`) are platform invariants hardcoded in the chart, the same
for every workload. Setting `cluster` or `vhost` is rejected at render.

### Why there is no permission escape hatch

A workload's `Permission` is fully DERIVED, and `configure` is always empty. There is deliberately no knob to
widen it. An app user can therefore never create or delete exchanges, queues or bindings at runtime; it can only
publish to and consume from topology that already exists.

This is a GitOps decision, not a RabbitMQ limitation. Every exchange, queue and binding is declared in this repo
as Kubernetes manifests and reconciled by ArgoCD plus the Messaging Topology Operator, so topology is reviewable
in a diff, versioned, and self-healing: the live broker matches git, full stop.

If apps could declare their own topology, which many client libraries do by default, that state would be created
out of band, invisible to git, un-diffable, and not pruned when the app changes. Exactly the drift GitOps exists to
eliminate. So the app side must be configured to attach to existing resources, never to declare. In Spring AMQP
that means disabling `RabbitAdmin` auto-declaration (`shouldDeclare: false`); equivalents exist in every client.
Granting `configure` would reopen that door.

The rare patterns that genuinely need hand-written permissions, publishing via the default exchange
(`amq.default`) or direct-reply-to RPC (`amq.rabbitmq.reply-to`), do not occur in this cluster's model of async
pub/sub events plus N-to-1 commands over declared exchanges. Which is why removing the hatch cost nothing.

## Secrets: generated, never sealed

The `User` CR omits `importCredentialsSecret`, so the Messaging Topology Operator GENERATES a random username and
password into a Secret `<user>-user-credentials` (keys `username`/`password`) in the workload's OWN namespace. The
pod mounts it via `secretKeyRef`, identical to how the app reads CNPG's `<db>-app` Secret.

This is the repo's operator-generated secret class from [06_secrets.md](06_secrets.md): nothing secret is
committed, no `SealedSecret`, no `.env` key, no `seal_secret` call. Sealing is only for secrets originating
OUTSIDE the cluster, like OAuth. RabbitMQ has none. The username is generated too, so the app reads it from the
Secret rather than hardcoding it, and the `Permission` references the user via `userReference` (the User CR name)
rather than a literal username.

Only the connection details and `WORKLOAD_NAME` are env. The exchange and queue names are compile-time constants
in the binary, so a pod cannot be pointed at the wrong topic:

```yaml
- name: RABBITMQ_HOST
  value: "rabbitmq.rabbitmq.svc.cluster.local"   # the shared broker client Service
- { name: RABBITMQ_PORT, value: "5672" }
- { name: RABBITMQ_VHOST, value: "apps" }
- name: RABBITMQ_USERNAME
  valueFrom: { secretKeyRef: { name: sample-user-manager-user-credentials, key: username } }
- name: RABBITMQ_PASSWORD
  valueFrom: { secretKeyRef: { name: sample-user-manager-user-credentials, key: password } }
- { name: WORKLOAD_NAME, value: "sample-user-manager" }   # message sender + queue-name prefix
```

On a cold start the pod may briefly sit in `CreateContainerConfigError` until the operator writes the Secret, then
self-heals. Same as the CNPG cold-start note in [10_sample_workload.md](10_sample_workload.md).

## Cross-namespace topology

Workloads live in their own namespaces; the broker lives in `rabbitmq`. Each topology CR sets
`spec.rabbitmqClusterReference: { name: rabbitmq, namespace: rabbitmq }`, which the operator only honours because
the `RabbitmqCluster` carries `rabbitmq.com/topology-allowed-namespaces: "*"`.

Rendering the CRs in the workload namespace rather than in `rabbitmq` is deliberate: it puts the generated
`<user>-user-credentials` Secret where the workload's pod can mount it, with no cross-namespace secret copying.

## Decisions

### Why CloudPirates, not Bitnami or raw manifests

Bitnami gated its free-tier images to `latest`-only, which breaks this repo's version pinning. The RabbitMQ
project ships no Helm chart of its own, only kustomize and manifests. The CloudPirates
`rabbitmq-cluster-operator` chart (OCI at `oci://ghcr.io/cloudpirates-io/helm-charts`) is a thin community
wrapper pinning the OFFICIAL upstream images: `ghcr.io/rabbitmq/cluster-operator`,
`ghcr.io/rabbitmq/messaging-topology-operator`, `ghcr.io/rabbitmq/default-user-credential-updater`, and the
server `docker.io/library/rabbitmq` (`-management-alpine`). All multi-arch including arm64. It is the first OCI
Helm dependency in the repo; ArgoCD's repo-server and `helm dependency build` both handle OCI fine.

### 3 replicas, quorum queues

Quorum queues replicate by majority vote, so they need a majority of members present.

- 3 replicas, one per Pi node, tolerate losing 1 node (majority 2 of 3). Real HA.
- 2 would pay the cost of a cluster with no quorum benefit, since the majority of 2 is 2 and one node down stalls
  writes.
- 1 has no HA. The operator recommends odd counts.

The broker defaults new queues to `quorum` (`default_queue_type = quorum` in `additionalConfig`), and the topology
chart sets `spec.type: quorum` explicitly on every queue.

### Dead-letter queues

Every consumer queue a workload owns, meaning each `consumeCommands` and `subscribeEvents` queue, gets a companion
dead-letter exchange `<queue>.dlx` (fanout) and queue `<queue>.dlq` (quorum). The source queue is declared with
`x-dead-letter-exchange: <queue>.dlx` and `x-delivery-limit: 5`, from the chart's `deadLetter` and `deliveryLimit`
knobs, both on by default.

So a poison message, one a consumer repeatedly fails to process, is routed to its DLQ after 5 delivery attempts
rather than being silently dropped, which is RabbitMQ's default at-most-once strategy.

DLQs are holding queues: nothing consumes them. You alert on their depth (`rabbitmq-dlq-not-empty`, see
[09_monitoring.md](09_monitoring.md)) and drain or replay by hand. The DLX and DLQ are admin-operator-declared like
the rest of the topology, so the app user gets no extra permission: the broker dead-letters internally and the app
never publishes to the DLX or consumes the DLQ. The DLQ itself carries no `x-dead-letter-exchange`, so there is no
loop. Set `deadLetter: false` to opt a workload out.

Because queue arguments are immutable (see Caveats), turning this on for a queue that already exists requires
deleting that queue once so the operator redeclares it with the args.

### Storage: node-local, disposable, not Longhorn

Per-broker volumes on the node-local `local-path-ephemeral` class. Quorum queues already replicate every message
across the 3 brokers and fsync locally, so HA and durability live in the app. Replicating the volume underneath
would just be write amplification, the same reason CNPG runs Postgres on `local-path`. See
[08_storage.md](08_storage.md).

Each broker gets a plain node-local volume and it is disposable: lose a node and the replacement broker starts
empty and self-reconciles from the 2 healthy peers. That is why the class is `reclaimPolicy: Delete`, with nothing
to preserve and the host dir auto-cleaned, rather than the `Retain` CNPG relies on.

Trade-offs, all accepted:

- While a node is down there is no spare fault tolerance. A second node loss drops quorum queues below majority,
  so they go read-unavailable until a majority returns.
- The volumes share Postgres's fixed 50 GiB `/var/mnt/localpath` slice. Quorum-log volumes are tiny.
- A broker rejoining with a wiped volume under the same node name usually re-adds itself automatically, but
  occasionally needs a manual `rabbitmq-queues grow`. Never data loss.
- `5Gi` per replica is nominal, since local-path enforces no quota.

### One app: operator plus broker

The operators and the broker live in ONE app, not two. The `RabbitmqCluster` CR cannot reconcile until its CRD
exists and a controller is running, the classic operator-then-CR ordering the repo also solves for cert-manager
into `03_gateway`. Here that ordering is handled WITHIN the single app rather than across waves:

- ArgoCD applies CRDs before ordinary resources (kind order), so the subchart's `RabbitmqCluster` and `Vhost` CRDs
  are created before the CRs in the same sync.
- Both CRs carry `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`, so on a cold boot, when the
  CRD is not registered yet at dry-run time, the sync does not fail on the unknown type.
- `selfHeal` plus sync retry then converge: the CR settles as soon as the operator pod is up and its CRD is
  established. No resource-level sync-waves are used.

The topology operator self-signs its admission-webhook cert (`useCertManager: false`), so the app has no
cert-manager dependency. Wave 3, rather than the wave-2 slot an operator alone would take, simply sorts it
alongside the other data apps; it shares wave 3 with `03_gateway` and `03_redis_operator`, all independent.

Workloads carry no wave. The root-of-roots creates the workloads tree about 5s after the platform root and does
NOT wait for it to be Healthy, so a workload's topology CRs can land before the operators and vhost exist. That
sync fails and retries (`limit: -1`) until they do.

### Network policy: label-based clients, ingress-tight

The broker's `CiliumNetworkPolicy` is default-deny both ways, then allows:

- AMQP `5672` from any pod labelled `messaging-client: "true"`. Label-based, so this platform app never needs
  editing when a new messaging workload appears; the workload opts in by labelling its pod and adding a matching
  egress rule, as the sample workloads do.
- Management `15672` from Envoy for the SSO-gated UI, and from the operators in-namespace.
- Metrics `15692` from vmagent.
- ALL ports among the broker's own pods. Clustering uses several (4369 epmd, 25672 inter-node, the CLI), so a
  missed one could break quorum formation.
- Egress: DNS, the API server entity, and peers.

Roll out audit-first like every netpol here: `PolicyAuditMode` on the broker plus `hubble observe --verdict
DROPPED,AUDIT` while the cluster forms, a client connects and the UI loads, then enforce.

The two operators carry their OWN pod-scoped policies (`networkpolicy-cluster-operator.yaml` and
`networkpolicy-topology-operator.yaml`), because the broker policy is pod-scoped and does not cover them. Each
allows only its real surface: the metrics scrape (cluster-operator only, since the topology operator's metrics are
TLS-off here so nothing scrapes it), the admission webhook (topology operator only), the kubelet health probe,
DNS, the API server, and for the topology operator the broker management API on `15672`.

The subchart's bundled vanilla `NetworkPolicy`s are DISABLED via `...networkPolicy.enabled: false`. They default
to allow-all-egress and Cilium UNIONs them with our CNPs, which would blow the default-deny open. Same reason
argocd pins `global.networkPolicy.create: false`. See [04_networking.md](04_networking.md).

### Management UI

Exposed exactly like the other platform UIs: a `rabbitmq` host on the platform ingress (`06_platform_ingress`,
wave 6) pointing at the broker's `15672` service, gated centrally by `04_google_sso` (wave 4). Edge SSO gates the
network path, then RabbitMQ shows its own login; sign in with the operator-generated admin credentials from the
`rabbitmq-default-user` Secret. It is the last wave, so the broker has long existed.

## Apply and verify

1. `helm dependency build argo_apps/platform/charts/03_rabbitmq` and commit the refreshed `Chart.lock`. ArgoCD's
   repo-server runs `helm dependency build`, and a missing or stale lock breaks sync. The workload charts are
   `file://`-only and therefore lockless, so they need nothing.
2. `git add -A && git commit && git push`. ArgoCD reconciles the pushed remote, not your working tree.

Checks, with `export KUBECONFIG=secrets/kubeconfig`:

- `kubectl -n rabbitmq get pods`: 2 operator pods Running, `rabbitmq-server-0..2` Running on 3 distinct nodes.
- `kubectl -n rabbitmq get rabbitmqcluster,vhost`: `AllReplicasReady=True`, vhost `apps` Ready.
- `kubectl -n sample-user-manager get
  user.rabbitmq.com,exchange.rabbitmq.com,queue.rabbitmq.com,binding.rabbitmq.com,permission.rabbitmq.com`: all
  `Ready=True`, with three exchanges (`user-events`, `user-audit-logger`, `create-user-command`) and one command
  queue. Likewise in `sample-user-signup` and `sample-audit-logger` for each subscriber's user, queues, bindings
  and permission.
- `kubectl -n sample-user-manager get secret sample-user-manager-user-credentials`: exists, with
  `username`/`password`, and the manager pod Running with the `RABBITMQ_*` env wired.
- Live loop: `kubectl -n sample-user-signup logs deploy/sample-user-signup` shows it publishing
  `create-user-command` every 10s and receiving `users.created` plus audit messages. `kubectl -n
  sample-user-manager logs deploy/sample-user-manager` shows it persisting users and emitting events, and past 10
  users evicting the oldest with `users.deleted` plus audit. `kubectl -n sample-audit-logger logs
  deploy/sample-audit-logger` shows audit messages only. `curl
  https://sample-user-manager.app.example.com/users` returns the JSON user list.
- Topology and isolation: `kubectl -n rabbitmq exec rabbitmq-server-0 -c rabbitmq -- rabbitmqctl list_permissions
  -p apps` shows each workload user with only its own `read`/`write` regexes (audit-logger read only) and
  `configure` empty.
- Management UI at `https://rabbitmq.ops.example.com/`: Google login, then the RabbitMQ login (creds from
  `kubectl -n rabbitmq get secret rabbitmq-default-user -o jsonpath='{.data}'`, base64-decoded), then the `apps`
  vhost with the workload users and their queues and exchanges.

## Caveats

- Live message flow is exercised end to end. The sample-app image speaks AMQP across three binaries, so the
  topology CRs, the generated credentials AND real publish/consume are all validated. Tail the three deployments'
  logs to watch the loop, and note that `users.deleted` reaches no consumer (topic routing) while every audit
  message reaches both subscribers (fanout).
- A queue's properties are immutable once declared. Changing a queue's `type`, `durable` or `arguments` means
  deleting and re-creating the `Queue` CR, because the operator will not mutate a live queue. Plan queue names up
  front. This is why enabling the DLQ pattern on queues that already exist needs a one-time delete of the affected
  queues, so they are recreated with the dead-letter arguments. Delete them in the management UI, or delete and
  re-sync the `Queue` CRs; the sample queues are empty so nothing is lost.
- Editing the generated credentials Secret does nothing. The operator does not watch it. To rotate, add a label or
  annotation to the `User` CR to force reconciliation, or re-create it.
- The memory limit is NOT where publishers block, and request == limit, so the limit is node capacity. The chart
  pins `total_memory_available_override_value` to the full limit, because the operator's 0.8x default compounds
  with the watermark and blocks publishers at 0.64x the limit. That leaves one knob: publishers block at
  `vm_memory_high_watermark.relative`, 0.85x the limit, and the remaining 15% absorbs GC overshoot before the
  kernel OOMKills. Both are derived from `resources.limits.memory`, which must therefore stay in `Mi`.

  Sized off measured RSS: an idle 3-node broker sawtooths 105-280Mi of Erlang code, allocator slack and quorum
  ETS, not queue contents. Live data is only ~75Mi, the rest is slack the allocator has not returned. Do NOT set
  `vm_memory_calculation_strategy = allocated` to dodge the sawtooth. It would read that 75Mi and never fire,
  while the kernel still kills on RSS.
- Every Secret the operator reads MUST carry `rabbitmq.com/topology-operator: "true"`, its informer caches no
  others. Unlabelled, the operator cannot see the Secret, retries CREATE forever against `already exists`, and
  the `User` sits `Ready: False`, surfacing as a Degraded ArgoCD app with no unhealthy child named. Only bites
  hand-written or restored Secrets; generated ones are labelled. Fix: `kubectl -n <ns> label secret <name>
  rabbitmq.com/topology-operator=true`.
- Never emit empty `Permission` fields, they cause permanent OutOfSync. RabbitMQ treats a missing
  `configure`/`write`/`read` as `""`, meaning no access, and the topology operator drops empty strings from the
  stored object. So a manifest declaring `configure: ""`, which is the usual case, leaves ArgoCD owning a field
  the live object does not have and holds the `Permission` OutOfSync forever. In practice only `configure`, since
  `write` and `read` are non-empty. The chart therefore emits ONLY the non-empty permission fields, so the desired
  manifest matches what the operator stores. Do not reintroduce empty fields, and do not paper over it with an
  ArgoCD `ignoreDifferences`: matching the stored shape is the correct fix.
- Delete `Permission` before `User`, a latent stuck-`Terminating` risk. On teardown the operator needs the User's
  credentials to remove the RabbitMQ-side permission, so if the `User` and its Secret go first, the `Permission`
  finalizer cannot complete and the object hangs. Today all of a workload's topology syncs in one wave, so this
  only bites on an out-of-order manual delete. Clear it with `kubectl patch permission <name> -p
  '{"metadata":{"finalizers":[]}}' --type=merge`. If it becomes routine, add sync-waves in the chart with User at
  a lower wave than Permission, so prune (reverse-wave) removes Permission first. See
  rabbitmq/messaging-topology-operator#324.
- `prune` deletes the RabbitmqCluster CR AND the data, by design. The broker PVCs are on the
  `local-path-ephemeral` (`Delete`) class, so a prune tears them down and there is no volume to recover. That is
  intentional: HA is the running quorum, not the volume, so a re-created broker rebuilds its state from the healthy
  peers. CNPG's `local-path` class is also `Delete`; what protects Postgres data from a prune is the DB unit's
  `deletionProtection`, not the reclaim policy. See [08_storage.md](08_storage.md).
