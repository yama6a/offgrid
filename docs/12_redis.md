# 12: Redis, per-workload caches via the OpsTree operator

Same shape as [Postgres](08_storage.md#cloudnativepg): an operator installed once as platform infrastructure, plus
a reusable shared chart a workload instantiates one or more times. There is no single shared Redis, unlike the one
shared RabbitMQ broker in [11_messaging.md](11_messaging.md): each workload owns its own instances, private and
unshared.

| Piece | Where | What |
|-------|-------|------|
| the operator | `argo_apps/platform/{apps,charts}/03_redis_operator` (wave 3) | wraps the OpsTree `ot-helm/redis-operator` chart: the controller plus its `Redis`/`RedisReplication`/`RedisCluster`/`RedisSentinel` CRDs |
| the reusable chart | `lib/helm/redis-instance/` (`type: application`) | renders ONE standalone `Redis` CR, its `ServiceMonitor`, and a default-deny `CiliumNetworkPolicy`. Consumed via an aliased `file://` dependency, one alias per instance, like `pg-cluster` |
| sample usage | `argo_apps/workloads/charts/sample_user_manager` | two instances showing both modes: `redis-cache` (the audit-log demo, ephemeral) and `redis-sessions` (durable, provisioned but never dialled) |

The Longhorn class every instance uses (`longhorn-r2-ephemeral`, 2-replica, reclaim Delete) is shipped by
`02_longhorn`, not here. See [08_storage.md](08_storage.md).

Why OpsTree (`ot-container-kit/redis-operator`): mature, CNCF-adjacent, a plain CRD, and its operator plus
`quay.io/opstree/redis` images are multi-arch including arm64. That last part is the Pi-5 gate, see the exporter
caveat below.

We run standalone single-instance Redis (`kind: Redis`): one pod, one PVC, deliberately no HA, replication,
sentinel or cluster. Durable instances do get off-cluster S3 backups. On a node loss the pod reschedules and
Longhorn reattaches the volume, so there is a brief availability gap.

## The operator (`03_redis_operator`, wave 3)

The app ships the operator only, no StorageClasses. It runs in its own `redis-operator` namespace and watches all
namespaces (cluster RBAC scope, the chart default), so it reconciles per-workload `Redis` CRs wherever they land.
A CR applied before the operator is up just fails its sync and retries. Automated `prune` + `selfHeal`,
`CreateNamespace=true`, `ServerSideApply=true` because the CRDs are large.

Wave 3, not 2: the operator needs only the CNI, so it would be a wave-2 independent leaf like `cnpg-operator`. It
stays at 3 purely to avoid renumbering, since the prefix is treated as stable. Invisible in practice, because
redis workloads are post-platform and need Longhorn (wave 2) anyway.

Values worth calling out, under `redis-operator:`:

- `redisOperator.webhook: false`. The admission webhook only guards the master-slave anti-affinity feature of
  `RedisReplication`, which we do not use. Off means there is no webhook serving-cert to manage at all, so no
  cert-manager dependency, and the chart's webhook templates render to nothing.
- `redisOperator.metrics.enabled: true` exposes the controller's `/metrics` on :8080. No PodMonitor is shipped,
  because the upstream chart has no toggle and the signal that matters is the per-instance redis-exporter. The
  endpoint is just left live for a future PodMonitor.
- `resources` trimmed from the chart's 500m/500Mi default to a Pi-modest 25m/128Mi request and 250m/256Mi limit.
  Fully specified rather than memory-only, because Helm deep-merges the map and an omitted key would silently
  inherit 500m.

The CRDs ship in the chart's `crds/` dir, and ArgoCD renders Helm with `--include-crds`, so they apply on sync.

## The reusable chart (`lib/helm/redis-instance`)

A first-party `type: application` chart. It templates the `Redis` CR itself, with no upstream dependency, hence no
`Chart.lock` and no vendored `charts/*.tgz`. The CRD comes from the operator. Every `lib/helm/` shared chart
follows this shape. It renders the `Redis` CR, a `ServiceMonitor`, a `CiliumNetworkPolicy`, and a `validate.yaml`
that hard-fails on a missing required knob.

One or more Redis is just one or more aliases:

```yaml
# Chart.yaml
- { name: redis-instance, alias: redis-cache,    version: "*", repository: "file://../../../../lib/helm/redis-instance" }
- { name: redis-instance, alias: redis-sessions, version: "*", repository: "file://../../../../lib/helm/redis-instance" }
```

```yaml
# values.yaml: the required knobs, plus an optional initialFixedDiskSize
redis-cache:
  name: sample-user-manager-redis-cache   # also the Service DNS clients dial
  # renovate: datasource=docker depName=quay.io/opstree/redis
  redisVersion: "v8.6.2"                  # REQUIRED: Redis server version, owned per-workload
  persistence: false                      # REQUIRED, no default. See the table below
  deletionProtection: true                # REQUIRED
  resources: { requests: { cpu: 25m, memory: 64Mi }, limits: { memory: 96Mi } }
  allowedClients: [ { matchLabels: { app: sample-user-manager } } ]   # same-ns only, so no namespace key
  # initialFixedDiskSize: 2Gi   # optional; default 1Gi; create-time only, see "Resizing an instance"
```

Everything a workload should not decide is hardcoded in `templates/redis.yaml`, in one place, updated for every
instance at once: the image repo, the redis-exporter's full ref, non-root uid/gid 1000, `maxmemory` at 80% of the
memory limit so Redis cannot OOM its cgroup, and no-auth. The storage class and AOF follow `persistence`.

The server image tag is the one exception, a per-workload knob (`redisVersion`), so each workload owns its Redis
version. The full knob list lives in `lib/helm/redis-instance/values.yaml`.

## Storage and persistence

A standalone `Redis` is one PVC, always on `longhorn-r2-ephemeral` (`numberOfReplicas: 2` so even a cache survives
a node loss, `reclaimPolicy: Delete`). That is a shared generic Longhorn tier from `02_longhorn`, not a
Redis-specific class. See [08_storage.md](08_storage.md).

`persistence` does NOT pick a class. Reclaim policy stopped being a safety knob once `deletionProtection` arrived:
an accidental prune cannot delete the instance at all (restore the files, zero loss), and an intentional delete
falls back to the S3 dump with its RPO window. A Retain class would add nothing to either case and would leak
orphaned `Released` PVs on every deliberate delete.

What `persistence` actually drives:

| `persistence` | AOF | S3 RDB backup | For |
|---|---|---|---|
| `true` | on (`appendfsync everysec`, so ~1s worst-case loss on a hard crash) | enrolled daily, via the `redis-backup.raspi-cluster/enabled` label | durable data |
| `false` | off, RDB snapshots only | not enrolled | disposable caches |

Deletion protection is the real prune guard, not the reclaim policy. `deletionProtection` (REQUIRED bool, no
default, independent of `persistence`) stamps `argocd.argoproj.io/sync-options: Prune=false,Delete=false` on the
Redis CR and its ext-config ConfigMap, ServiceMonitor and NetworkPolicy. Manifests leaving git ORPHAN a running
instance rather than deleting it, and restoring them re-adopts it: no outage, no PV rebind. Keep it `true` in
steady state for every instance, caches included.

The orphan then shows up as a permanently-OutOfSync app (`argocd-health.yaml`) or, if the whole app is gone, via
`orphaned_redis_instance` from `05_orphan_exporter`. Client-egress policies are deliberately NOT protected: they
are trivially re-rendered and the client pods get pruned with the workload anyway.

AOF, persistent instances only. `templates/configmap.yaml` renders an extra-config ConfigMap
(`<name>-ext-config`, wired via the CR's `redisConfig.additionalRedisConfig`) setting `appendonly yes` and
`appendfsync everysec`. On restart the instance replays its append-only log, so at most ~1s of writes is lost on a
hard crash rather than everything back to the last RDB snapshot. AOF and RDB both land on the PVC (`dir=/data`).
Ephemeral instances skip the ConfigMap and run RDB-only: still restart-persistent via the snapshot, just not
crash-durable, and the volume is discarded on delete.

`maxmemory` and eviction, both modes. `maxMemoryPercentOfLimit: 80` sets `maxmemory` to 80% of the container
memory limit. The ~20% headroom covers the persistence fork's copy-on-write (every page mutated during an RDB or
AOF rewrite is copied) plus non-dataset overhead (client and AOF buffers, jemalloc fragmentation), so the kernel
does not OOM-kill the pod. Eviction stays the Redis default `noeviction`: at the cap, writes FAIL rather than
silently dropping data.

Active defrag on, both modes. jemalloc never returns freed memory to the allocator, so a high-churn workload
leaves `used_memory_rss` inflated and `mem_fragmentation_ratio` climbing. The cache RPUSHes per-UUID audit entries
with a 1h TTL, which is constant allocate and free. `activedefrag yes` lets Redis compact live. The upstream
trigger defaults never fire on a Pi-sized instance (`active-defrag-ignore-bytes 100mb` is far above a ~77Mi
maxmemory), so we lower them to `ignore-bytes 16mb` and `threshold-lower 15%`.

Size the disk against memory, not the dataset. `noeviction` lets the keyspace grow to `maxmemory`, roughly 80% of
the memory limit, and that whole dataset is persisted (RDB about 1x, plus AOF up to about 2x during a rewrite), so
budget the PVC at roughly 2x the memory limit. If the disk fills, `stop-writes-on-bgsave-error` (the Redis
default) halts writes, the same safe-but-degraded failure as hitting `maxmemory`. So `initialFixedDiskSize`
(default 1Gi) and `resources.limits.memory` are linked: bump both together. The 1Gi default comfortably covers the
small instances typical here, since a 96Mi limit leaves about 10x headroom.

Deliberately out of scope: HA. A single standalone pod means a node loss is a brief availability gap until the pod
reschedules and re-attaches its volume. A workload needing more would use a `RedisReplication` or `RedisSentinel`
variant, not added for now.

## Off-cluster backups: RDB to S3

Durable instances are backed up to S3 as periodic RDB dumps. Ephemeral instances never are, being regenerable by
definition.

One central platform app does it for the whole cluster, `07_redis_backup` (wave 7, ns `redis-backup`), rather than
a per-instance CronJob. That means one sealed secret in one namespace and no per-namespace list. The price is a
single global schedule and job-level rather than per-instance alerting. It shares the S3 bucket and IAM writer
with CNPG; see [13_backups.md](13_backups.md) for the bucket, Terraform and creds.

How it works:

- Discovery, not a list. The `redis-instance` chart stamps `redis-backup.raspi-cluster/enabled: "true"` on the
  `Redis` CR of every durable instance. The job's `list` container (`kubectl get redis -A -l ...`, via a read-only
  cluster-wide ClusterRole) finds them all, so a durable instance added anywhere is picked up.
- Dump. For each, `redis-cli --rdb` against the instance's Service on `:6379`. That is a replication full-sync, so
  an app-consistent point-in-time RDB with no PVC or AOF-file access and no auth, the network policy being the
  gate. It continues past a single instance's failure so partial success still uploads. The dump image need not
  match the server major, since `--rdb` only streams bytes.
- Upload. `aws s3 cp` each dump to `s3://<bucket>/redis/<namespace>/<name>/<UTC>.rdb`, creds from the single
  sealed `redis-backup-s3` secret (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`), encrypted at rest by the bucket.
  Retention and tiering are the bucket's lifecycle. The job exits non-zero if any instance failed, so the Job
  fails and the alert fires; which instance is in the job's stdout, which lands in VictoriaLogs.
- Network. The job's CiliumNetworkPolicy allows egress to the kube-apiserver for discovery, DNS, `:6379`
  cluster-wide, and S3 on `:443`. Each durable instance's own policy hardcodes an inbound allow from the
  `redis-backup` namespace.

Turning it on is one action: `make configure-redis-backup` (step 15) reads the Terraform writer creds, writes
`bucket` and `region` once into the app's `values.yaml`, and seals `redis-backup-s3` into the `redis-backup`
namespace. Commit and push. An empty `AWS_DEPLOY_ACCESS_KEY_ID` in `.env` means the step no-ops and the CronJob
does not render, per the repo's empty-means-off contract. The bootstrap orchestrator runs step 15 automatically,
so a fresh cluster comes up with backups on. The schedule lives in the app's `values.yaml`, default daily at
02:00 UTC.

Monitoring is three Grafana alerts: `redis-backup-failed` and `redis-backup-stale` (job-level, warning) plus
`redis-no-recoverable-backup` (per instance, critical). Only the last catches a single instance silently going
unbacked or a dump that uploaded empty. See [13_backups.md](13_backups.md).

### Restore from S3

`make restore-redis` is the runbook, and it is executable: `lib/shell/recover_redis_from_s3.sh`, flags
`--namespace --instance [--target latest|<N>|<s3-key>] [--apply]`, prompting for whatever is missing. It resolves
what git declares against what the cluster has, prints that state, then runs three phases: get an instance to
restore into, pick a dump and replay it, re-protect. Run it and read what it prints; the phases are not repeated
here.

Pick by symptom:

| Symptom | What to do |
|---|---|
| Instance running, data wrong or gone (bad write, corruption, a rewind) | `make restore-redis` |
| Instance gone, its alias STILL in git (node or PVC loss, cluster rebuild) | `make restore-redis`. Phase 1 waits for Argo to rebuild it empty, then loads the dump |
| Instance gone AND removed from git (a deliberate two-commit delete) | Put back its values block AND its `Chart.yaml` alias, push, then `make restore-redis`. The alias cannot be recovered from `values.yaml` alone, which is the one thing the script cannot do for you |
| Instance running, app permanently OutOfSync | Restore the files in git. Argo re-adopts it, no data moves, nothing to run |

Two things the script cannot tell you at runtime:

- Why replication. The dump is replayed by making the target a `REPLICAOF` of a throwaway seed pod, not by
  swapping the PVC (which fights the operator and the AOF) or by `redis-rdb-tools` (unmaintained, fragile on new
  RDB versions). A full resync carries every type, TTL and score exactly. The offline path is possible but not
  scripted.
- The operator may reconcile the `Redis` CR mid-restore. The manual `REPLICAOF` holds long enough to sync; re-run
  if it races.

Per-instance backup health is `redis_backup_recoverable`. The job-level alerts cannot see one instance silently
going unbacked.

## Resizing an instance

`initialFixedDiskSize` is exactly that: the size the volume is born at, and editing it later does nothing to a
running instance.

The size lives in the operator-managed StatefulSet's `volumeClaimTemplate`, which Kubernetes treats as immutable
and which only governs newly-created PVCs. The OpsTree operator does not reconcile PVC expansion either; its only
response to a storage change is to recreate the StatefulSet, which re-adopts the same PVC at its old size. So a
changed value just sits there, the operator's reconcile may error, the pod keeps its original disk, and nothing is
rebooted or wiped. Unlike CNPG in this repo, where changing the storage size IS reconciled, so do not carry that
intuition over.

To grow a live instance, expand the PVC directly. Both redis classes set `allowVolumeExpansion: true`, so Longhorn
grows the volume and ext4 filesystem online, with no reboot and no data loss:

```bash
kubectl -n <ns> get pvc                                   # find the instance's PVC (STS-owned)
kubectl -n <ns> patch pvc <pvc> --type merge \
  -p '{"spec":{"resources":{"requests":{"storage":"5Gi"}}}}'
```

`selfHeal` will not revert this: ArgoCD does not manage the STS-owned PVC, and the operator never shrinks it. Bump
`initialFixedDiskSize` in git to match, so a from-scratch reprovision creates the volume at the new size rather
than the old one and then needing re-expansion. To have the git change itself drive the expansion you would wire
an ArgoCD PreSync hook Job that patches the PVC. Not done here; the manual patch is simpler for a homelab.

Decreasing is not possible in place. Kubernetes only allows `requests.storage` to grow and the API server rejects
any shrink outright, Longhorn included, so the "reduce below what is already on disk" case never gets evaluated.
That guard is what stops a filesystem being truncated under live data.

To shrink, or for any change the in-place path cannot do, migrate to a fresh instance. Provision a second Redis by
adding another alias, sized as you want, copy the data across while both run, cut the app over, then delete the
old alias:

```bash
# per-key move between two standalone instances (preserves TTLs; MIGRATE is atomic per key):
kubectl -n <ns> exec <old-pod> -- sh -c '
  redis-cli --scan | while read k; do
    redis-cli MIGRATE <new-svc> 6379 "$k" 0 5000 COPY REPLACE
  done'
```

`--scan` avoids blocking like `KEYS *`, and `COPY` leaves the source intact for rollback, so drop it once
verified. For a large dataset prefer a streaming tool such as `redis-shake`. Then repoint the app (`app.redises[0]`
to the new instance's `name`, so `REDIS_ADDR` follows), sync, confirm, and delete the old alias per the next
section. Because our data is regenerable audit logs with a 1h TTL, starting fresh on a new instance is often
simpler than migrating at all.

## Deleting an instance (two commits)

`deletionProtection: true` means removing an alias from git ORPHANS the instance, which keeps running unmanaged,
and leaves the app permanently OutOfSync. Deleting is deliberately two steps, pure GitOps, no `kubectl delete`:

1. Set `deletionProtection: false` on that alias. Commit, push, let ArgoCD sync. The data is untouched, but THE
   POD DOES RESTART: the operator copies the CR's annotations onto its StatefulSet pod template, so adding or
   removing the sync-options rolls it. AOF on the PVC carries the data across, measured at about 20s with no loss.
   Unlike CNPG, where the same flip is inert.
2. Remove the alias, meaning its values block and its `Chart.yaml` dependency entry. Commit and push. The next
   sync prunes it for real and the PVC goes with it. Its volume then obeys the class reclaim policy, which is
   Delete, so it is gone for good and the off-cluster S3 dump is the only copy left.

Never leave an instance sitting on `false`. That is a transient state between those two commits, not a config
choice. Same flow as CNPG, see [13_backups.md](13_backups.md).

## Security: no password, gated by network policy

Redis runs without `requirepass`. Access is enforced entirely at the network layer by each instance's default-deny
`CiliumNetworkPolicy`: only the owning workload's pods (`allowedClients`) may open `:6379`, plus the operator for
reconcile and vmagent for metrics. Instances are ClusterIP-only and never exposed via ingress.

The operator pod carries its own default-deny policy too
(`03_redis_operator/templates/networkpolicy.yaml`): kubelet health probe in; DNS, API server, and egress to any
managed Redis on `:6379` out. That last one is cross-namespace via `matchExpressions` with ns-Exists, because the
empty `{}` selector is same-namespace-only in Cilium. See [04_networking.md](04_networking.md).

Why not a password? The repo's [secrets bright line](06_secrets.md) is: never commit cluster-mintable secrets.
Sealed Secrets are for externally-sourced, human-supplied credentials like the OAuth client secret. A Redis
password is cluster-mintable, so it would want the CNPG or RabbitMQ route, where the operator generates it and the
app reads it via `secretKeyRef` with nothing in git. But the OpsTree operator does not auto-generate one, and a
Helm-generated "sticky random" password is unreliable under ArgoCD: its repo-server renders with `helm template`,
where the `lookup` function returns nothing, so the password regenerates on every sync and churns.

That leaves two clean options, and we take the first:

1. No password plus `CiliumNetworkPolicy`, chosen. Network-RBAC. Nothing to commit or generate; the policy is the
   access control. For a cache only its own workload can reach, never exposed, that is enough.
2. A committed SealedSecret, not wired. To add `requirepass`, drop a `redisSecret: { name, key }` into
   `templates/redis.yaml` pointing at a SealedSecret. Deliberately a small chart edit rather than a per-workload
   knob: the default is no password, and keeping auth out of values keeps the workload interface small.

Netpol rollout is audit-first, like every netpol here: put the redis endpoints in Cilium `PolicyAuditMode`, watch
`hubble observe --verdict DROPPED,AUDIT` while the pod starts, the operator reconciles, a client connects and
vmagent scrapes, and only enforce once clean. That is also the safety net for the pod-label selector (`app:
<name>`): if the operator ever relabels its pods, audit mode surfaces it before enforcement could leave an
instance unprotected.

## Monitoring

Each instance enables the redis-exporter sidecar and ships a `ServiceMonitor` selecting that instance's
operator-created Service (`app: <name>, redis_setup_type: standalone, role: standalone`, port `redis-exporter`).
The VM operator auto-converts it to a `VMServiceScrape` and vmagent discovers it cluster-wide
(`selectAllByDefault`), so it wires into VictoriaMetrics with no extra config. See
[09_monitoring.md](09_monitoring.md).

Those `redis_*` metrics feed the `redis-health` group (`05_grafana/files/alerts/redis-health.yaml`):

- `redis-down`, dynamic severity: critical for an `alertCritical` instance, warning otherwise.
- Memory vs `maxmemory`, warning above 90% and critical above 98%. `noeviction` means writes fail near the cap
  rather than evicting.
- Rejected connections, and nearing `maxclients`.
- RDB and AOF last-save failures.
- Fragmentation, gated on the instance being over 50% full (`redis_memory_used_bytes / redis_memory_max_bytes >
  0.5`). On a near-empty tiny instance the fixed RSS floor of code pages, jemalloc arenas and buffers dwarfs the
  dataset and inflates `mem_fragmentation_ratio` past 1.5 with no real fragmentation. The fill floor drops that
  false positive and scales to any instance size.

Separate from the two backup-job alerts in the `backups` group. A crashlooping or down instance is also caught by
the platform `container-waiting-fatal` and `statefulset-not-available` outage rules, off the same
`alert-criticality` label.

arm64 exporter caveat: the OpsTree `redis` chart's default exporter tag (`quay.io/opstree/redis-exporter`) is
amd64-only and will not run on the Pi 5. The `redis-instance` chart pins a recent multi-arch tag instead. Verify
arm64 via the quay v2 manifest-list API before bumping. The redis and operator images are multi-arch.

## The sample: audit-log cache and `GET /audit`

`sample_user_manager` provisions two instances to show both multiplicity and both persistence modes:

- `redis-cache`, dialled, `persistence: false`. The audit-log cache is treated as ephemeral for the demo, since
  its data is 1h-TTL and regenerable.
- `redis-sessions`, `persistence: true`, durable. Provisioned, monitored and reachable, but never dialled. The
  Redis equivalent of the extra-Postgres demo.

App wiring mirrors Postgres: one flat `app.redises` list with no primary/extra split. `redises[0]` is aliased to
the bare `REDIS_ADDR` the manager dials; every entry also gets a cosmetic `REDIS_<NAME>_ADDR`. Egress is not
listed in the app netpol, because each instance's chart renders a client-egress CNP from its own `allowedClients`,
the single source of truth for the app-to-Redis edge.

The manager binary ([`pi5-k8s-sample-app`](https://github.com/yama6a/pi5-k8s-sample-app), `internal/audit`) emits an
`AuditLog` on every user create or delete, broadcast on the `user-audit-logger` fanout. It also stores each event
in `redis-cache` with `RPUSH audit:<uuid>` plus `EXPIRE 1h`, refreshed per write, so a user's events vanish an hour
after their last activity. `GET /audit` `SCAN`s the `audit:*` keyspace, `LRANGE`s each list, and returns a JSON
map of user-UUID to events. At most about 10 users, since the user table is capped. No password: the app connects
to `REDIS_ADDR` with no credentials, gated by the network policy.

Cross-repo image bump: the audit feature lives in the `pi5-k8s-sample-app` repo and ships as a new GHCR image tag.
After that image is published, bump `app.image` in `sample_user_manager/values.yaml`, since the manifests pin an
exact tag. Until then the running image lacks `/audit`.

## Verify

```bash
# Charts render (local)
helm dependency update argo_apps/platform/charts/03_redis_operator
helm template argo_apps/platform/charts/03_redis_operator --include-crds | grep -cE '^kind: CustomResourceDefinition'   # 4 CRDs
helm template argo_apps/workloads/charts/sample_user_manager -n sample-user-manager | grep -c '^kind: Redis'   # 2

export KUBECONFIG=secrets/kubeconfig
kubectl -n redis-operator get pods                                        # operator Running
kubectl -n sample-user-manager get redis                                  # redis-cache + redis-sessions
kubectl -n sample-user-manager get pvc -o wide                            # both on longhorn-r2-ephemeral
kubectl -n longhorn-system get volumes.longhorn.io                        # each Redis volume: 2 replicas
kubectl get vmservicescrape -A | grep -i redis                            # metrics wired into VictoriaMetrics
```

Smoke test: drive a user create and delete via the `sample-user-signup` command flow the manager consumes, then
`curl https://sample-user-manager.app.example.com/audit` for events grouped by UUID. Confirm the 1h TTL with
`kubectl -n sample-user-manager exec sample-user-manager-redis-cache-0 -- redis-cli TTL audit:<uuid>`.
