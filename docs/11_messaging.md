# 11: messaging, one shared RabbitMQ broker + a reusable topology chart

The cluster's message bus: a single RabbitMQ broker every workload shares, plus a reusable Helm library that
lets a workload declare its own messaging topology (exchanges/queues/users) with proper isolation from other
workloads. Like [07_ingress.md](07_ingress.md), this one doc covers several ArgoCD apps at different waves plus
a shared `lib/helm/` chart.

Two pieces (the operators + broker are one platform app; the topology is per-workload):

- **operators + broker** — `argo_apps/platform/{apps,charts}/03_rabbitmq` (wave 3), ONE app. It wraps the
  CloudPirates `rabbitmq-cluster-operator` chart — which installs BOTH the **RabbitMQ Cluster Operator**
  (reconciles the `RabbitmqCluster` CR into the broker StatefulSet) and the **Messaging Topology Operator**
  (reconciles `Queue`/`Exchange`/`Binding`/`User`/`Permission`/`Vhost` CRs) + their CRDs — AND renders the
  broker itself: the single `RabbitmqCluster` (3 replicas on the node-local `local-path-ephemeral` class) + the
  one shared `Vhost` (`apps`) + the broker's `CiliumNetworkPolicy`. There is exactly ONE broker for the whole
  cluster (unlike Postgres, which is per-workload), so it lives in platform. (See "One app: operator + broker"
  below for why operators and their CRs safely share one wave.)
- **the reusable chart** — `lib/helm/rabbitmq-topology/` (`type: library`, like `ingress`). A workload
  consumes it via a `file://` dependency + a one-line `{{ include "rabbitmq-topology.render" . }}` template and
  declares its topology in values. Demonstrated by the sample-user-* workloads (see [10_sample_workload.md](10_sample_workload.md)).

## The two patterns, and who owns what

RabbitMQ separation comes down to *who declares the exchange and the queue*, and *what each user is allowed to
do*. The library encodes both patterns as intent-named lists so ownership lands on the correct side:

| Pattern | Shape | Exchange owned by | Queue owned by | Library keys |
|---|---|---|---|---|
| **Command topic** | N publishers → 1 consumer | the **consumer** | the **consumer** | consumer: `consumeCommands`; publishers: `sendCommands` |
| **Event topic** | 1 publisher → N consumers | the **publisher** | each **consumer** (its own) | publisher: `publishEvents`; consumers: `subscribeEvents` |

- A **command topic** is instantiated and configured on the **consumer**: its `consumeCommands` entry declares
  the exchange + its single queue + the binding, and grants the consumer's user `read` on that queue. Every
  publisher merely lists the exchange in its own `sendCommands`, which grants it `write` — nothing else.
- An **event topic** is created on the **publisher**: its `publishEvents` entry declares the exchange and grants
  the publisher `write`. Each **consumer** declares its OWN private queue via `subscribeEvents` (auto-named
  `<user>.<exchange>`, bound to the publisher's exchange), and only that consumer's user is granted `read` on
  it — so one consumer can never read another's queue.

Each workload gets exactly **one** user (reusable across all its publish/consume needs). RabbitMQ has a single
`configure`/`write`/`read` permission triple per user+vhost, so the library aggregates: `write` = every
exchange the workload publishes to (`publishEvents` + `sendCommands`), `read` = every queue it consumes (its
command queues + its per-subscription event queues), `configure` = `""` (the operator's admin user declares all
topology, so an app user never needs configure). Regex metacharacters in the auto queue names are escaped, so a
name matches only itself.

## The reusable chart (`lib/helm/rabbitmq-topology`)

A `type: library` chart — no upstream dependency, no `Chart.lock`, no vendored `charts/` (the exact shape of
`ingress`; the `pg-cluster` `type: application` apparatus isn't needed because there's no upstream chart to
wrap, only CRs to render). A consumer wires it exactly like `ingress`:

```yaml
# Chart.yaml
dependencies:
  - name: rabbitmq-topology
    version: "*"
    repository: "file://../../../../lib/helm/rabbitmq-topology"
```
```yaml
# templates/messaging.yaml — the whole thing
{{ include "rabbitmq-topology.render" . }}
```
The sample app demonstrates all three exchange types across three real workloads — a user-lifecycle loop
(`sample-user-signup` → `sample-user-manager` → `sample-user-signup`/`sample-audit-logger`). The manager (the
hub) owns every exchange; one of each type:

```yaml
# sample_user_manager/values.yaml — the hub: command consumer + event/audit publisher
rabbitmq-topology:
  user: sample-user-manager             # defaults to the release name; -> Secret <user>-user-credentials
  consumeCommands:
    - { name: create-user-command }                 # OWNS + sole consumer (always direct: N publishers → 1 consumer)
  publishEvents:
    - { name: user-events, type: topic }            # OWNS; publishes users.created AND users.deleted
    - { name: user-audit-logger, type: fanout }     # OWNS; broadcast to every subscriber
# -> Permission write: ^(user-events|user-audit-logger)$, read: ^(create-user-command)$
```
```yaml
# sample_user_signup/values.yaml — command publisher + event/audit consumer
rabbitmq-topology:
  user: sample-user-signup
  sendCommands: [create-user-command]                          # write on the manager's command exchange
  subscribeEvents:
    - { exchange: user-events, routingKey: "users.created" }   # own queue; binds ONLY users.created
    - { exchange: user-audit-logger }                          # fanout: routingKey ignored; gets all audits
# -> write: ^(create-user-command)$, read: ^(sample-user-signup\.user-events|sample-user-signup\.user-audit-logger)$
```
```yaml
# sample_audit_logger/values.yaml — a pure audit sink (no write permission at all)
rabbitmq-topology:
  user: sample-audit-logger
  subscribeEvents:
    - { exchange: user-audit-logger }                          # fanout; own queue sample-audit-logger.user-audit-logger
# -> read: ^(sample-audit-logger\.user-audit-logger)$   (no write — it publishes nothing)
```
This is the teaching payoff: **direct** (`create-user-command`) point-to-point; **topic** (`user-events`) where
signup binds only `users.created`, so `users.deleted` — which the manager still publishes — reaches no queue
and is dropped by the broker; **fanout** (`user-audit-logger`) broadcast to two independent subscribers
(signup + audit-logger), each with its OWN `<user>.user-audit-logger` queue, so neither can read the other's.
`cluster.{name,namespace}` and `vhost` are library defaults (`rabbitmq`/`rabbitmq`/`apps`) a workload rarely
touches.

### Why there is no permission escape hatch (apps never create topology)

A workload's `Permission` is fully DERIVED — `write` from `publishEvents`+`sendCommands`, `read` from the
queues it consumes — and `configure` is **always** empty. There is intentionally no knob to widen it (an
earlier `permissionOverrides` field was dropped). An app user therefore can never create or delete exchanges,
queues, or bindings at runtime: it can only publish to / consume from topology that already exists.

This is a GitOps decision, not a RabbitMQ limitation. All infra — every exchange, queue, and binding — is
declared in this repo as Kubernetes manifests and reconciled by ArgoCD + the Messaging Topology Operator.
Topology is therefore reviewable in a diff, versioned, and self-healing; the live broker matches git, full
stop. If apps could declare their own topology (many client libraries, e.g. Spring AMQP, do so by default),
that state would be created out-of-band, invisible to git, un-diffable, and not pruned when the app changes —
exactly the config drift GitOps exists to eliminate. So the app side must be configured to attach to existing
resources, never to declare (Spring AMQP: disable `RabbitAdmin` auto-declaration / `shouldDeclare: false`;
equivalents exist in every client). Granting `configure` would reopen that door, so the chart doesn't offer it.

The rare patterns that genuinely need hand-written permissions — publishing via the default exchange
(`amq.default`), or direct-reply-to RPC (`amq.rabbitmq.reply-to`) — don't occur in this cluster's model (async
events pub/sub + N:1 commands, all over declared exchanges), which is why removing the hatch cost nothing.

## Secrets: generated, never sealed

The `User` CR omits `importCredentialsSecret`, so the Messaging Topology Operator **generates** a random
username + password into a Secret `<user>-user-credentials` (keys `username`/`password`) **in the workload's
own namespace**. The pod mounts it via `secretKeyRef`, identical to how the app reads CNPG's `<db>-app`
Secret — this is the repo's "operator-generated" secret class from [06_secrets.md](06_secrets.md): nothing
secret is committed, no `SealedSecret`, no `.env` key, no `seal_secret` call. (Sealing is only for secrets that
originate *outside* the cluster — OAuth/SMTP. RabbitMQ has none.) The username is generated, so the app reads it
from the Secret too (it can't be hardcoded), and the `Permission` references the user via `userReference` (the
User CR name), not a literal username.

`sample_user_manager` wires it (`templates/app.yaml`; signup + audit-logger wire the same block, each with its
own `<user>-user-credentials`). Note only connection + `WORKLOAD_NAME` are env — the exchange/queue names are
compile-time constants in the binary, so a pod can't be pointed at the wrong topic:
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
On a cold start the pod may briefly `CreateContainerConfigError` until the operator writes the Secret, then
self-heals (same as the CNPG cold-start note in [10_sample_workload.md](10_sample_workload.md)).

## Cross-namespace topology

Workloads live in their own namespaces; the broker lives in `rabbitmq`. Each topology CR sets
`spec.rabbitmqClusterReference: { name: rabbitmq, namespace: rabbitmq }`, which the operator only honours
because the `RabbitmqCluster` carries the annotation `rabbitmq.com/topology-allowed-namespaces: "*"`. Rendering
the CRs in the workload namespace (rather than in `rabbitmq`) is deliberate: it puts the generated
`<user>-user-credentials` Secret where the workload's pod can mount it, with no cross-namespace secret copying.

## Decisions

### Why CloudPirates, not Bitnami or raw manifests
Since 2025-08-28 Bitnami gated its free-tier images to `latest`-only, which breaks this repo's version pinning.
The RabbitMQ project ships no Helm chart of its own (only kustomize/manifests). The CloudPirates
`rabbitmq-cluster-operator` chart (`0.3.3`, OCI at `oci://ghcr.io/cloudpirates-io/helm-charts`) is a thin
community wrapper that pins the **official** upstream images — `ghcr.io/rabbitmq/cluster-operator:2.21.0`,
`ghcr.io/rabbitmq/messaging-topology-operator:1.19.2`, `ghcr.io/rabbitmq/default-user-credential-updater`, and
the server `docker.io/library/rabbitmq:4.2.8-management-alpine` — all multi-arch incl. arm64. It's the first
OCI Helm dependency in the repo; ArgoCD's repo-server and `helm dependency build` both handle OCI fine.

### 3 replicas, quorum queues
Quorum queues use Raft and need a **majority** of members. 3 replicas (one per Pi node) tolerate losing 1 node
(majority 2 of 3) — real HA. 2 would pay the cost of a cluster with no quorum benefit (majority of 2 is 2, so
one node down stalls writes); 1 has no HA. The operator recommends odd counts. The broker defaults new queues to
`quorum` (`default_queue_type = quorum` in `additionalConfig`), and the topology chart sets `spec.type: quorum`
explicitly on every queue — classic mirrored queues are gone in RabbitMQ 4.x.

### Storage: node-local, disposable (not Longhorn)
Per-broker volumes on the node-local `local-path-ephemeral` class, **not** Longhorn. Quorum queues already
replicate every message across the 3 brokers (Raft) and fsync locally, so HA and durability live in the app;
replicating the volume underneath too would just be write amplification — the same reason CNPG runs Postgres on
`local-path` (see [08_storage.md](08_storage.md)). Each broker therefore gets a plain node-local volume, and
it's **disposable**: lose a node and the replacement broker starts empty and self-reconciles from the 2 healthy
peers. That's why the class is `reclaimPolicy: Delete` (nothing to preserve; the host dir is auto-cleaned)
rather than the `Retain` CNPG relies on. Trade-offs, all accepted: while a node is down there's no spare fault
tolerance (a 2nd node loss drops quorum queues below majority → read-unavailable until a majority returns); the
volumes share Postgres's fixed 50 GiB `/var/mnt/cnpg` slice (quorum-log volumes are tiny); and a broker
rejoining with a wiped volume under the same node name usually re-adds itself automatically in RabbitMQ 4.x but
occasionally needs a manual `rabbitmq-queues grow` — never data loss. `5Gi` per replica is nominal (local-path
enforces no quota).

### One app: operator + broker
The operators and the broker live in ONE app (`03_rabbitmq`, wave 3), not two. The `RabbitmqCluster` CR can't
reconcile until its CRD exists and a controller is running — the classic operator-then-CR ordering the repo also
solves for `02_cert_manager` → `03_gateway` — but here that ordering is handled *within* the single app rather
than across waves:

- ArgoCD applies CRDs before ordinary resources (kind order), so the subchart's `RabbitmqCluster`/`Vhost` CRDs
  are created before the CRs in the same sync.
- The two CRs carry `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`, so on a cold boot — when
  the CRD isn't registered yet at dry-run time — the sync doesn't fail on the unknown type.
- `selfHeal` + ArgoCD's sync retry then converge: the CR settles as soon as the operator pod is up and its CRD is
  established. (No resource-level sync-waves are used, keeping the repo's convention.)

The topology operator self-signs its admission-webhook cert (`useCertManager: false`), so the app has no
dependency on cert-manager. Wave 3 (rather than the wave-2 slot an operator alone would take) simply sorts it
alongside the other data apps; it shares wave 3 with `03_gateway` / `03_redis_operator` (all independent).
Workloads carry no wave: the root-of-roots creates the workloads tree only after the whole platform is Healthy,
so the operators + broker + `apps` vhost already exist when a workload's topology CRs land.

### Network policy: label-based clients, ingress-tight
The broker's `CiliumNetworkPolicy` (`03_rabbitmq/templates/networkpolicy.yaml`) is default-deny both
ways, then allows: AMQP `5672` from any pod labelled `messaging-client: "true"` (label-based, so this platform
app never needs editing when a new messaging workload appears — the workload opts in by labelling its pod +
adding a matching egress rule, as the sample-user-* workloads do); management `15672` from Envoy (the SSO-gated UI) and
from the operators in-namespace; metrics `15692` from vmagent; and ALL ports among the broker's own pods
(clustering uses several — 4369 epmd, 25672 inter-node, CLI — so a missed one can't break quorum formation).
Egress: DNS, the API server entity, and peers. **Roll out audit-first** like every netpol here (see
[10_sample_workload.md](10_sample_workload.md)): `PolicyAuditMode` on the broker + `hubble observe --verdict
DROPPED,AUDIT` while the cluster forms + a client connects + the UI loads, then enforce.

### Management UI
Exposed exactly like the other platform UIs (argocd/grafana/vmui): a `rabbitmq` host on the platform ingress
(`06_platform_ingress`, wave 6) → the broker's `15672` service, gated centrally by `04_google_sso` (wave 4).
Edge SSO gates the network path; RabbitMQ then shows its own login — sign in with the operator-generated admin
credentials from the `rabbitmq-default-user` Secret. It's the last wave, so the broker (wave 3) long exists.

## Apply / verify

1. `helm dependency build argo_apps/platform/charts/03_rabbitmq` and
   `helm dependency build` each of `argo_apps/workloads/charts/sample_user_{manager,signup}` +
   `sample_audit_logger`, commit the refreshed `Chart.lock`s (ArgoCD's repo-server runs `helm dependency
   build`; a missing/stale lock breaks sync).
2. `git add -A && git commit && git push` — ArgoCD reconciles the pushed remote, not your working tree.

Checks (`export KUBECONFIG=secrets/kubeconfig`):

- `kubectl -n rabbitmq get pods` → 2 operator pods Running; `rabbitmq-server-0..2` Running on 3 distinct nodes.
- `kubectl -n rabbitmq get rabbitmqcluster,vhost` → `AllReplicasReady=True`; vhost `apps` Ready.
- `kubectl -n sample-user-manager get user.rabbitmq.com,exchange.rabbitmq.com,queue.rabbitmq.com,binding.rabbitmq.com,permission.rabbitmq.com`
  → all `Ready=True` (three exchanges: `user-events`/`user-audit-logger`/`create-user-command`; one command
  queue). Likewise `-n sample-user-signup` / `-n sample-audit-logger` for each subscriber's user + queue(s) + binding(s) + permission.
- `kubectl -n sample-user-manager get secret sample-user-manager-user-credentials` → exists (`username`/`password`);
  the manager pod Running with the `RABBITMQ_*` env wired.
- **Live loop** — `kubectl -n sample-user-signup logs deploy/sample-user-signup` shows it publishing
  `create-user-command` every 10s and receiving `users.created` + audit messages; `kubectl -n
  sample-user-manager logs deploy/sample-user-manager` shows it persisting users and emitting events (and, past
  10 users, evicting the oldest with `users.deleted` + audit); `kubectl -n sample-audit-logger logs
  deploy/sample-audit-logger` shows audit messages only. `curl https://sample-user-manager.app.example.com/users`
  → the JSON user list.
- Topology + isolation — `kubectl -n rabbitmq exec rabbitmq-server-0 -c rabbitmq -- rabbitmqctl list_permissions -p apps`
  → each workload user has only its own `read`/`write` regexes (audit-logger has read only), `configure` empty.
- Management UI — `https://rabbitmq.ops.example.com/`: Google login → RabbitMQ login (creds from
  `kubectl -n rabbitmq get secret rabbitmq-default-user -o jsonpath='{.data}'`, base64-decoded) → the `apps`
  vhost, the workload users, and their queues/exchanges.

## Caveats

- **Live message flow is exercised end-to-end.** The sample-app image speaks AMQP across three binaries:
  `/signup` (sample-user-signup) publishes `create-user-command` every 10s; `/manager` (sample-user-manager)
  persists each user and emits `users.created` + an audit message, evicting the oldest past 10 users
  (`users.deleted` + audit); `/auditor` (sample-audit-logger) logs audit messages. So the topology CRs,
  generated credentials, AND real publish/consume are all validated — tail the three deployments' logs to
  watch the loop, and note `users.deleted` reaches no consumer (topic routing) while every audit message
  reaches both subscribers (fanout).
- **A queue's properties are immutable once declared.** Changing a queue's `type`/`durable` means deleting and
  re-creating the `Queue` CR (the operator won't mutate a live queue). Plan queue names up front.
- **Editing the generated credentials Secret does nothing.** The operator doesn't watch it; to rotate, add a
  label/annotation to the `User` CR to force reconciliation (or re-create it).
- **Never emit empty `Permission` fields (they cause permanent OutOfSync).** RabbitMQ treats a missing
  `configure`/`write`/`read` as `""` (no access), and the topology operator drops empty strings from the stored
  object. So a manifest that declares `configure: ""` (the usual case — an app user needs no configure) leaves
  ArgoCD owning a field the live object doesn't have, holding the `Permission` OutOfSync forever (only
  `configure` in practice, since `write`/`read` are non-empty). The `rabbitmq-topology` library therefore emits
  ONLY the non-empty permission fields (`_all.tpl` builds the map, `_permission.tpl` `toYaml`s it), so the
  desired manifest matches what the operator stores. Don't reintroduce empty fields, and don't paper over it
  with an ArgoCD `ignoreDifferences` — matching the stored shape is the correct fix.
- **Delete `Permission` before `User` (latent stuck-`Terminating` risk).** On teardown, the operator needs the
  User's credentials to remove the RabbitMQ-side permission; if the `User` (and its Secret) go first, the
  `Permission` finalizer can't complete and the object hangs in `Terminating`. Today all a workload's topology
  syncs in one wave, so this only bites on an out-of-order manual delete — clear it with
  `kubectl patch permission <name> -p '{"metadata":{"finalizers":[]}}' --type=merge`. If it becomes a routine
  problem, add sync-waves in the library (User at a lower wave than Permission, so prune — reverse-wave —
  removes Permission first); see rabbitmq/messaging-topology-operator#324.
- **`prune` deletes the RabbitmqCluster CR *and* the data — by design.** The broker PVCs are on the
  `local-path-ephemeral` (`Delete`) class, so a prune tears them down; there is no volume to recover. That's
  intentional: HA is the running quorum, not the volume, so a re-created broker rebuilds its state from the
  healthy peers. (Contrast CNPG, whose `local-path` class is `Retain` precisely because Postgres data is *not*
  disposable.)
