# 11: messaging, one shared RabbitMQ broker + a reusable topology chart

The cluster's message bus: a single RabbitMQ broker every workload shares, plus a reusable Helm library that
lets a workload declare its own messaging topology (exchanges/queues/users) with proper isolation from other
workloads. Like [07_ingress.md](07_ingress.md), this one doc covers several ArgoCD apps at different waves plus
a shared `lib/helm/` chart.

Three pieces (the operators and the broker are platform; the topology is per-workload):

- **operators** — `argo_apps/platform/{apps,charts}/02_rabbitmq_operator` (wave 2). Wraps the CloudPirates
  `rabbitmq-cluster-operator` chart, which installs BOTH the **RabbitMQ Cluster Operator** (reconciles the
  `RabbitmqCluster` CR into the broker StatefulSet) and the **Messaging Topology Operator** (reconciles
  `Queue`/`Exchange`/`Binding`/`User`/`Permission`/`Vhost` CRs) + their CRDs. Operators + CRDs only.
- **the broker** — `argo_apps/platform/{apps,charts}/03_rabbitmq_cluster` (wave 3). The single `RabbitmqCluster`
  (3 replicas on Longhorn) + the one shared `Vhost` (`apps`) + the broker's `CiliumNetworkPolicy`. There is
  exactly ONE broker for the whole cluster (unlike Postgres, which is per-workload), so it lives in platform.
- **the reusable chart** — `lib/helm/rabbitmq-topology/` (`type: library`, like `ingress-edge`). A workload
  consumes it via a `file://` dependency + a one-line `{{ include "rabbitmq-topology.render" . }}` template and
  declares its topology in values. Demonstrated by `sample_workload` (see [10_sample_workload.md](10_sample_workload.md)).

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
`ingress-edge`; the `pg-cluster` `type: application` apparatus isn't needed because there's no upstream chart to
wrap, only CRs to render). A consumer wires it exactly like `ingress-edge`:

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
```yaml
# values.yaml — sample-workload as BOTH a publisher and a command consumer
rabbitmq-topology:
  user: sample-workload                 # defaults to the release name; -> Secret <user>-user-credentials
  publishEvents:
    - { name: sample-events, type: topic }
  subscribeEvents:
    - { exchange: sample-events, routingKey: "sample.#" }   # its own queue sample-workload.sample-events
  consumeCommands:
    - { name: sample-commands, type: direct }
  # sendCommands: [other-commands]       # write on another workload's command exchange
```
That renders one `User`, the `Exchange`/`Queue`/`Binding` CRs it owns, and one aggregated `Permission`
(`write: ^(sample-events)$`, `read: ^(sample-commands|sample-workload\.sample-events)$`, `configure: ""`).
`cluster.{name,namespace}` and `vhost` are library defaults (`rabbitmq`/`rabbitmq`/`apps`) a workload rarely
touches. `permissionOverrides` is an escape hatch for the rare app that must re-declare topology at runtime.

## Secrets: generated, never sealed

The `User` CR omits `importCredentialsSecret`, so the Messaging Topology Operator **generates** a random
username + password into a Secret `<user>-user-credentials` (keys `username`/`password`) **in the workload's
own namespace**. The pod mounts it via `secretKeyRef`, identical to how the app reads CNPG's `<db>-app`
Secret — this is the repo's "operator-generated" secret class from [06_secrets.md](06_secrets.md): nothing
secret is committed, no `SealedSecret`, no `.env` key, no `seal_secret` call. (Sealing is only for secrets that
originate *outside* the cluster — OAuth/SMTP. RabbitMQ has none.) The username is generated, so the app reads it
from the Secret too (it can't be hardcoded), and the `Permission` references the user via `userReference` (the
User CR name), not a literal username.

`sample_workload` wires it (`templates/app.yaml`):
```yaml
- name: RABBITMQ_HOST
  value: "rabbitmq.rabbitmq.svc.cluster.local"   # the shared broker client Service
- { name: RABBITMQ_PORT, value: "5672" }
- { name: RABBITMQ_VHOST, value: "apps" }
- name: RABBITMQ_USERNAME
  valueFrom: { secretKeyRef: { name: sample-workload-user-credentials, key: username } }
- name: RABBITMQ_PASSWORD
  valueFrom: { secretKeyRef: { name: sample-workload-user-credentials, key: password } }
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

### Storage: Longhorn (deliberate double redundancy)
Per-replica volumes on the Longhorn class. Note this is redundant on purpose: quorum queues already replicate
messages across the 3 broker nodes AND Longhorn replicates each volume across nodes. The upside is a lost node
lets its broker pod reschedule and reattach its volume with data intact; the cost is extra storage. 5Gi per
replica is ample for homelab message/quorum-log volumes.

### Two apps, operator then broker
The `RabbitmqCluster` CR can't reconcile until its CRD exists and a controller is running, so the operators
(wave 2) and the broker CR (wave 3) are separate apps — the same operator-then-CR split the repo uses for
`02_cert_manager` → `03_gateway`. The topology operator self-signs its admission-webhook cert
(`useCertManager: false`), so wave 2 has no cross-wave dependency on cert-manager. Workloads carry no wave: the
root-of-roots creates the workloads tree only after the whole platform is Healthy, so the operators + broker +
`apps` vhost already exist when a workload's topology CRs land.

### Network policy: label-based clients, ingress-tight
The broker's `CiliumNetworkPolicy` (`03_rabbitmq_cluster/templates/networkpolicy.yaml`) is default-deny both
ways, then allows: AMQP `5672` from any pod labelled `messaging-client: "true"` (label-based, so this platform
app never needs editing when a new messaging workload appears — the workload opts in by labelling its pod +
adding a matching egress rule, as `sample_workload` does); management `15672` from Envoy (the SSO-gated UI) and
from the operators in-namespace; metrics `15692` from vmagent; and ALL ports among the broker's own pods
(clustering uses several — 4369 epmd, 25672 inter-node, CLI — so a missed one can't break quorum formation).
Egress: DNS, the API server entity, and peers. **Roll out audit-first** like every netpol here (see
[10_sample_workload.md](10_sample_workload.md)): `PolicyAuditMode` on the broker + `hubble observe --verdict
DROPPED,AUDIT` while the cluster forms + a client connects + the UI loads, then enforce.

### Management UI
Exposed exactly like the other platform UIs (argocd/grafana/vmui): a `rabbitmq` host on the platform ingress
(`08_platform_ingress`, wave 8) → the broker's `15672` service, gated centrally by `04_google_sso` (wave 4).
Edge SSO gates the network path; RabbitMQ then shows its own login — sign in with the operator-generated admin
credentials from the `rabbitmq-default-user` Secret. It's the last wave, so the broker (wave 3) long exists.

## Apply / verify

1. `helm dependency build argo_apps/platform/charts/02_rabbitmq_operator` and
   `helm dependency build argo_apps/workloads/charts/sample_workload`, commit the refreshed `Chart.lock`s
   (ArgoCD's repo-server runs `helm dependency build`; a missing/stale lock breaks sync).
2. `git add -A && git commit && git push` — ArgoCD reconciles the pushed remote, not your working tree.

Checks (`export KUBECONFIG=secrets/kubeconfig`):

- `kubectl -n rabbitmq get pods` → 2 operator pods Running; `rabbitmq-server-0..2` Running on 3 distinct nodes.
- `kubectl -n rabbitmq get rabbitmqcluster,vhost` → `AllReplicasReady=True`; vhost `apps` Ready.
- `kubectl -n sample-workload get user.rabbitmq.com,exchange.rabbitmq.com,queue.rabbitmq.com,binding.rabbitmq.com,permission.rabbitmq.com`
  → all `Ready=True`.
- `kubectl -n sample-workload get secret sample-workload-user-credentials` → exists (`username`/`password`);
  the app pod Running with the `RABBITMQ_*` env wired.
- Topology + isolation — `kubectl -n rabbitmq exec rabbitmq-server-0 -c rabbitmq -- rabbitmqctl list_permissions -p apps`
  → each workload user has only its own `read`/`write` regexes, `configure` empty.
- Management UI — `https://rabbitmq.example.com/`: Google login → RabbitMQ login (creds from
  `kubectl -n rabbitmq get secret rabbitmq-default-user -o jsonpath='{.data}'`, base64-decoded) → the `apps`
  vhost, the workload users, and their queues/exchanges.

## Caveats

- **Declaring topology exercises the wiring, not message flow.** The topology CRs, generated credentials, and
  env are all validated end-to-end, but actually publishing/consuming needs an AMQP-speaking app. If the sample
  binary (`ghcr.io/yama6a/pi5-k8s-sample-app`) doesn't speak AMQP yet, live message flow is a follow-up.
- **A queue's properties are immutable once declared.** Changing a queue's `type`/`durable` means deleting and
  re-creating the `Queue` CR (the operator won't mutate a live queue). Plan queue names up front.
- **Editing the generated credentials Secret does nothing.** The operator doesn't watch it; to rotate, add a
  label/annotation to the `User` CR to force reconciliation (or re-create it).
- **`prune` deletes the RabbitmqCluster CR but not the data.** Longhorn PVCs are retained per Longhorn's reclaim
  policy, so a re-create recovers the volumes.
