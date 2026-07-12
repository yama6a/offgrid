# 12: Redis, per-workload caches via the OpsTree operator

Redis on this cluster follows the same shape as [Postgres](08_storage.md#cloudnativepg): an **operator** installed
once as platform infrastructure, plus a **reusable shared chart** a workload instantiates one-or-more times. There
is no single shared Redis (unlike the one shared RabbitMQ broker in [11_messaging.md](11_messaging.md)) — each
workload owns its own instances, private and unshared. Like `07_ingress.md`/`11_messaging.md`, this one doc covers an
ArgoCD platform app, a `lib/helm/` shared chart, and the sample usage.

Three pieces (the operator + storage classes are platform; the instances are per-workload):

| Piece | Where | What |
|-------|-------|------|
| **operator + storage** | `argo_apps/platform/{apps,charts}/03_redis_operator` (wave 3) | wraps the OpsTree `ot-helm/redis-operator` chart (the controller + its `Redis`/`RedisReplication`/`RedisCluster`/`RedisSentinel` CRDs) AND ships the two Longhorn classes `redis-instance` selects between via `persistence`: `longhorn-redis-persistent` (Retain) + `longhorn-redis-ephemeral` (Delete), both 2-replica. Wave 3 because those classes use Longhorn's provisioner. |
| **the reusable chart** | `lib/helm/redis-instance/` (`type: application`) | renders ONE standalone `Redis` CR + its `ServiceMonitor` + a default-deny `CiliumNetworkPolicy`. A workload consumes it via an aliased `file://` dependency, one alias per instance (like `pg-cluster`). |
| **sample usage** | `argo_apps/workloads/charts/sample_user_manager` | two instances showcasing BOTH modes — `redis-cache` (the audit-log demo, **ephemeral** for the demo) + `redis-sessions` (**persistent**, provisioned but unused). The manager binary stores audit events in `redis-cache` and serves them at `GET /audit`. |

Why OpsTree (`ot-container-kit/redis-operator`): it's the mature, CNCF-adjacent Redis operator with a plain CRD, and
its operator + `quay.io/opstree/redis` images are multi-arch incl. **arm64** (the Pi-5 gate — see the exporter
caveat below). We run **standalone** single-instance Redis (`kind: Redis`): one pod, one PVC — a deliberate choice
(no HA / replication / sentinel / cluster, no backups). Persistence is a REQUIRED per-instance flag (no default —
each instance chooses durable vs ephemeral; see below); on a node loss the pod reschedules and Longhorn reattaches
the volume, a brief availability gap.

## The operator + storage classes (`03_redis_operator`, wave 3)

One app ships both the operator and the two StorageClasses. The wrapper chart pins `ot-helm/redis-operator`
`0.25.0` (app `0.25.0`; operator config under the `redis-operator:` key in `values.yaml`) and renders the two
Longhorn classes from its own `templates/storageclasses.yaml` (top-level `persistent:`/`ephemeral:` values).
Automated `prune`+`selfHeal`, `CreateNamespace=true`, `ServerSideApply=true` (the CRDs are large). The operator
runs in its own `redis-operator` namespace and watches all namespaces (cluster RBAC scope, the chart default), so
per-workload `Redis` CRs in the workloads tree are reconciled once the platform is Healthy.

**Wave 3, not 2:** the operator alone would be a wave-2 independent leaf (needs only the CNI, like `cnpg-operator`),
but the bundled StorageClasses use Longhorn's `driver.longhorn.io` provisioner, so the whole app lands after
Longhorn (wave 2) — the operator/engine-then-consumer ordering the waves exist for. Bundling keeps all Redis
platform setup in one app; the only cost is the operator installing one wave later, invisible in practice (redis
workloads are post-platform and need Longhorn anyway).

**Values worth calling out** (under `redis-operator:`):

- `redisOperator.webhook: false` — the operator's admission webhook only guards the master-slave anti-affinity
  feature (`RedisReplication`), which we don't use. Off means there's no webhook serving-cert to manage at all — no
  cert-manager dependency. (The chart would self-sign if the webhook were on with `certmanager.enabled=false`, but
  we don't need the feature.) The chart's webhook/cert-manager templates render to nothing with this off.
- `redisOperator.metrics.enabled: true` — exposes the controller's `/metrics` (:8080). No PodMonitor is shipped
  from the wrapper (the upstream chart has no toggle, and the signal that matters is the per-instance
  redis-exporter); the endpoint is just left live for a future PodMonitor.
- `resources` — trimmed from the chart's 500m/500Mi default to a Pi-modest 25m/128Mi req, 250m/256Mi limit. Fully
  specified (not just memory) because Helm deep-merges the map — an omitted key would silently inherit 500m.

The CRDs ship in the chart's `crds/` dir; ArgoCD renders Helm with `--include-crds`, so they're applied on sync.

## The reusable chart (`lib/helm/redis-instance`)

A **first-party `type: application` chart** — it templates the `Redis` CR itself (no upstream dependency, so no
`Chart.lock`, no vendored `charts/*.tgz`); the CRD comes from the operator. This is a third `lib/helm/` variant
distinct from both `ingress-edge` (`type: library`) and `pg-cluster` (`type: application` **with** a wrapped upstream
chart). It renders three things per instance: the `Redis` CR, a `ServiceMonitor`, and a `CiliumNetworkPolicy`, plus a
`validate.yaml` that hard-fails on missing required knobs (the `pg-cluster` pattern).

A workload consumes it exactly like `pg-cluster`: an **aliased `file://` dependency, once per instance** — "one or
more Redis" is just "one or more aliases". Each alias is a values key carrying its own `name`:

```yaml
# Chart.yaml
- { name: redis-instance, alias: redis-cache,    version: "*", repository: "file://../../../../lib/helm/redis-instance" }
- { name: redis-instance, alias: redis-sessions, version: "*", repository: "file://../../../../lib/helm/redis-instance" }
```
```yaml
# values.yaml — the four REQUIRED knobs (+ optional initialFixedDiskSize); rest is hardcoded in the templates
redis-cache:
  name: sample-user-manager-redis-cache   # also the Service DNS clients dial
  persistence: false                      # REQUIRED, no default: true = durable (Retain + AOF) | false = ephemeral (Delete, RDB-only)
  resources: { requests: { cpu: 25m, memory: 64Mi }, limits: { memory: 96Mi } }
  allowedClients: [ { namespace: sample-user-manager, matchLabels: { app: sample-user-manager } } ]
  # initialFixedDiskSize: 2Gi   # optional; default 1Gi; create-time only (see "Resizing an instance")
```

Everything a workload shouldn't decide is **hardcoded in `templates/redis.yaml`** (one place, updated for every
instance at once): the redis + exporter images/tags, the redis-exporter sidecar, non-root uid/gid 1000,
`maxmemory` = 80% of the memory limit (so Redis can't OOM its cgroup), and no-auth (the storage class + AOF follow
the `persistence` flag). The
workload interface is deliberately just four required knobs, plus an optional create-time `initialFixedDiskSize`
(default 1Gi; see "Resizing an instance" for why it's create-time) — see
`lib/helm/redis-instance/README.md`.

## Storage & persistence

A standalone `Redis` is one PVC. A **REQUIRED `persistence`** flag (no default) picks the mode; the two Longhorn
StorageClasses it selects between are shipped by the **`03_redis_operator`** app (wave 3, after Longhorn) alongside
the operator — NOT in the Longhorn chart, since this is Redis's storage policy, not Longhorn's. Both classes are `numberOfReplicas: 2`
(this cluster's nodes are flaky, so even a cache should survive a node loss) and mirror Longhorn's default-class
parameters, differing only in reclaimPolicy:

| `persistence` | Storage class | reclaimPolicy | AOF | For |
|---|---|---|---|---|
| `true` | `longhorn-redis-persistent` | **Retain** — volume survives a PVC delete/prune, so an ArgoCD prune is data-safe (Released volumes cleaned up manually) | **on** (`appendfsync everysec`) | durable data |
| `false` | `longhorn-redis-ephemeral` | **Delete** — volume cleaned up when its PVC is deleted | **off** (RDB only) | disposable caches |

- **AOF (persistent only).** `templates/configmap.yaml` renders an extra-config ConfigMap (`<name>-ext-config`,
  wired via the CR's `redisConfig.additionalRedisConfig`) that sets `appendonly yes` + `appendfsync everysec`. On
  restart the instance replays its append-only log — at most ~1s of writes lost on a hard crash, not the whole
  window back to the last RDB snapshot. AOF + RDB both land on the PVC (`dir=/data`). Ephemeral instances skip the
  ConfigMap entirely and run RDB-only: still restart-persistent via the snapshot, just not crash-durable, and the
  volume is discarded on delete.
- **`maxmemory` + eviction (both modes).** `maxMemoryPercentOfLimit: 80` sets `maxmemory` to 80% of the container
  memory limit — the ~20% headroom is for the persistence fork's copy-on-write (every page mutated during an
  RDB/AOF rewrite is copied) plus non-dataset overhead (client/AOF buffers, jemalloc fragmentation), so the kernel
  doesn't OOM-kill the pod. Eviction stays the Redis default `noeviction`: at the cap, writes FAIL rather than
  silently dropping data.

**Size the disk against memory, not the dataset.** `noeviction` lets the keyspace grow to `maxmemory` (≈80% of the
mem limit), and that whole dataset is persisted (RDB ~1× + AOF up to ~2× during a rewrite), so budget the PVC at
**~2× the memory limit**. If the disk fills, `stop-writes-on-bgsave-error` (Redis default) halts writes — the same
safe-but-degraded failure as hitting `maxmemory`. So `initialFixedDiskSize` (default 1Gi) and `resources.limits.memory` are linked:
bump both together. The 1Gi default comfortably covers the small instances typical here (a 96Mi limit ⇒ ~10× headroom).

**Deliberately out of scope:** HA (a single standalone pod — a node loss is a brief availability gap until the pod
reschedules and re-attaches its volume) and off-cluster backup. A workload needing them would use a
`RedisReplication`/`RedisSentinel` variant or a backup CronJob — not added for now.

## Resizing an instance

`initialFixedDiskSize` is exactly that — **the size the volume is born at, and editing it later does nothing to a
running instance.** The size lives in the operator-managed StatefulSet's `volumeClaimTemplate`, which Kubernetes
treats as immutable *and* which only governs newly-created PVCs; and the OpsTree operator does not reconcile PVC
expansion (its only response to a storage change is to recreate the StatefulSet — which re-adopts the same PVC at
its old size). So a changed value just sits there (the operator's reconcile may error), the pod keeps its original
disk, and nothing is rebooted or wiped. This is unlike CNPG/Postgres in this repo, where changing the storage size
*is* reconciled — don't carry that intuition over.

**To grow a live instance (increase only)** — expand the PVC directly; both redis classes set
`allowVolumeExpansion: true`, so Longhorn grows the volume + ext4 filesystem online (no reboot, no data loss):

```bash
kubectl -n <ns> get pvc                                   # find the instance's PVC (STS-owned)
kubectl -n <ns> patch pvc <pvc> --type merge \
  -p '{"spec":{"resources":{"requests":{"storage":"5Gi"}}}}'
```

`selfHeal` won't revert this (ArgoCD doesn't manage the STS-owned PVC, and the operator never shrinks it). Bump
`initialFixedDiskSize` in git to match, so a from-scratch reprovision (disaster recovery) creates the volume at the
new size instead of the old one and then needing re-expansion. (If you want the git change *itself* to drive the
expansion, wire an ArgoCD PreSync hook Job that patches the PVC — not done here; the manual patch is simpler for a
homelab.)

**Decreasing is not possible in place.** Kubernetes only allows `requests.storage` to grow — the API server
rejects any shrink outright (Longhorn doesn't shrink either), so the "reduce below what's already on disk" case
never even gets evaluated; the request is refused first. That guard is what stops a filesystem being truncated
under live data.

**To shrink, or for any change the in-place path can't do — migrate to a fresh instance.** This is also the clean
way to change anything else immutable. Provision a *second* Redis (add another alias — see the aliasing section)
sized as you want, copy the data across while both run, cut the app over, then delete the old alias:

```bash
# per-key move between two standalone instances (preserves TTLs; MIGRATE is atomic per key):
kubectl -n <ns> exec <old-pod> -- sh -c '
  redis-cli --scan | while read k; do
    redis-cli MIGRATE <new-svc> 6379 "$k" 0 5000 COPY REPLACE
  done'
```

(`--scan` avoids blocking like `KEYS *`; `COPY` leaves the source intact for rollback; drop it once verified.
For a large dataset prefer a streaming tool such as `redis-shake`.) Then repoint the app (`app.redis` →
the new instance's `name`, so `REDIS_ADDR` follows), sync, confirm, and remove the old alias. Because our data is
regenerable audit logs with a 1h TTL, "just start fresh on a new instance" is often simpler than migrating at all.

## Security: no password, gated by network policy

**Redis runs without `requirepass` by default.** Access is enforced entirely at the network layer by each instance's
default-deny `CiliumNetworkPolicy`: only the owning workload's pods (`allowedClients`) may open `:6379`,
plus the operator (reconcile) and vmagent (metrics). Instances are ClusterIP-only and never exposed via ingress.

Why not a password? The repo's [secrets bright line](06_secrets.md) is: never commit cluster-mintable secrets —
Sealed Secrets are for externally-sourced, human-supplied credentials (OAuth, SMTP). A Redis password is
cluster-mintable, so it'd want the CNPG/RabbitMQ route (operator generates it, app reads it via `secretKeyRef`,
nothing in git). But the OpsTree operator does **not** auto-generate one, and a Helm-generated "sticky random"
password is unreliable under ArgoCD (its repo-server renders with `helm template`, where the `lookup` function
returns nothing, so the password regenerates on every sync → churn). That leaves two clean options; we take the
first:

1. **No password + `CiliumNetworkPolicy`** (chosen) — network-RBAC. Nothing to commit or generate; the policy is the
   access control. For a per-workload, in-namespace, never-exposed cache this is a defensible and simple posture.
2. **A committed SealedSecret** (not wired) — to add `requirepass`, drop a `redisSecret: { name, key }` into
   `templates/redis.yaml` pointing at a SealedSecret. Deliberately a small chart edit, not a per-workload knob:
   the default posture is no-password, and keeping auth out of values keeps the workload interface small.

**Netpol rollout is audit-first** (like every netpol here — see [10_sample_workload.md](10_sample_workload.md) and the
pg-cluster/rabbitmq lockdowns): put the redis endpoints in Cilium `PolicyAuditMode`, `hubble observe --verdict
DROPPED,AUDIT` while the pod starts, the operator reconciles, a client connects and vmagent scrapes, and only enforce
once clean. This is also the safety net for the pod-label selector (`app: <name>`): if the operator ever relabels its
pods, audit mode surfaces it before enforcement could leave an instance unprotected.

## Monitoring

Each instance enables the redis-exporter sidecar and ships a `ServiceMonitor` selecting that instance's
operator-created Service (`app: <name>, redis_setup_type: standalone, role: standalone`, port `redis-exporter`). The
VM operator auto-converts it to a `VMServiceScrape` and vmagent discovers it cluster-wide (`selectAllByDefault`), so
it wires into VictoriaMetrics with no extra config (CRDs exist from wave 0). See [09_monitoring.md](09_monitoring.md).

**arm64 exporter caveat.** The OpsTree `redis` chart's default exporter tag `quay.io/opstree/redis-exporter:v1.44.0`
is **amd64-only** and will not run on the Pi 5. The `redis-instance` chart pins a recent multi-arch tag
(`v1.84.0`); verify arm64 (quay v2 manifest-list API) before bumping. The redis + operator images are multi-arch.

## The sample: audit-log cache + `GET /audit`

`sample_user_manager` provisions two instances to showcase both multiplicity AND both persistence modes:
**`redis-cache`** (dialed; **`persistence: false`** — for the sake of the demo the audit-log cache is treated as
ephemeral, since its data is 1h-TTL and regenerable) and **`redis-sessions`** (**`persistence: true`**, durable;
provisioned + monitored + egress-allowed, but never dialed — the Redis equivalent of the `analyticsdb`
extra-Postgres demo). The app wiring mirrors Postgres: `app.redis` is the primary (fed as `REDIS_ADDR`),
`app.extraRedis` only widens the app's egress NetworkPolicy.

The manager binary ([`pi5-k8s-sample-app`](https://github.com/yama6a/pi5-k8s-sample-app), `internal/audit`) already
emitted an `AuditLog` on every user create/delete (broadcast on the `user-audit-logger` fanout). It now ALSO stores
each event in `redis-cache`: `RPUSH audit:<uuid>` + `EXPIRE 1h` (refreshed per write, so a user's events vanish an hour
after their last activity). `GET /audit` `SCAN`s the `audit:*` keyspace and `LRANGE`s each list, returning a JSON map
of user-UUID → events (at most ~10 users, since the user table is capped). No password: the app connects to
`REDIS_ADDR` with no credentials, gated by the network policy.

**Cross-repo image bump.** The audit feature lives in the `pi5-k8s-sample-app` repo and ships as a new GHCR image tag.
After that image is published, bump `app.image` in `sample_user_manager/values.yaml` to the new tag (the manifests
pin an exact tag). Until then the running image lacks `/audit`.

## Verify

```bash
# Charts render (local)
helm dependency update argo_apps/platform/charts/03_redis_operator
helm template argo_apps/platform/charts/03_redis_operator --include-crds | grep -cE '^kind: (CustomResourceDefinition|StorageClass)'   # 6 = 4 CRDs + 2 StorageClasses (longhorn-redis-persistent/ephemeral)
helm dependency update argo_apps/workloads/charts/sample_user_manager && helm template argo_apps/workloads/charts/sample_user_manager -n sample-user-manager | grep -c '^kind: Redis'   # 2

export KUBECONFIG=secrets/kubeconfig
kubectl -n redis-operator get pods                                        # operator Running
kubectl -n sample-user-manager get redis                                  # redis-cache + redis-sessions
kubectl -n sample-user-manager get pvc -o wide                            # redis-cache=longhorn-redis-ephemeral, redis-sessions=longhorn-redis-persistent
kubectl -n longhorn-system get volumes.longhorn.io                        # each Redis volume: 2 replicas
kubectl get vmservicescrape -A | grep -i redis                            # metrics wired into VictoriaMetrics
```

Smoke test: drive a user create/delete (via the `sample-user-signup` command flow the manager consumes), then
`curl https://sample-user-manager.app.example.com/audit` → events grouped by UUID; confirm the 1h TTL with
`kubectl -n sample-user-manager exec sample-user-manager-redis-cache-0 -- redis-cli TTL audit:<uuid>` (entries self-expire).
