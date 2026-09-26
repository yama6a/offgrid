# Redis, per-workload caches via the OpsTree operator

Redis has the same shape as [Postgres](05_storage.md#cloudnativepg). An operator is installed once as platform
infrastructure. A reusable shared chart lets a workload create one or more instances. There is no shared Redis.
Each workload owns its own private instances. RabbitMQ is different: one broker serves all workloads, see
[08_messaging.md](08_messaging.md).

| Piece | Where | What |
|-------|-------|------|
| the operator | `argo_apps/platform/{apps,charts}/03_redis_operator` (wave 3) | wraps the OpsTree `ot-helm/redis-operator` chart: the controller and its `Redis`/`RedisReplication`/`RedisCluster`/`RedisSentinel` CRDs |
| the reusable chart | `lib/helm/redis-instance/` (`type: application`) | renders one standalone `Redis` CR, its `ServiceMonitor`, and a default-deny `CiliumNetworkPolicy`. A workload consumes it through an aliased `file://` dependency, one alias per instance, like `pg-cluster` |
| sample usage | `argo_apps/workloads/charts/sample_user_manager` | two instances, one per mode. The manager connects to both: `redis-cache` (the audit-log demo, ephemeral) and `redis-sessions` (the session store, durable) |

Every instance uses the Longhorn class `longhorn-r2-ephemeral` (2 replicas, reclaim `Delete`). `02_longhorn` ships
that class, not this app. See [05_storage.md](05_storage.md).

Why OpsTree (`ot-container-kit/redis-operator`):

- It is mature and close to the CNCF.
- It uses a plain CRD.
- Its operator and `quay.io/opstree/redis` images are multi-arch, including arm64. The Pi 5 needs arm64, see the
  exporter caveat in [Monitoring](#monitoring).

Each instance is a standalone single-instance Redis (`kind: Redis`): one pod and one PVC. There is no HA,
replication, sentinel or cluster, by choice. Durable instances get off-cluster S3 backups. On a node loss the pod
reschedules and Longhorn reattaches the volume, so the instance is unavailable for a short time.

## The operator (`03_redis_operator`, wave 3)

The app ships the operator only, no StorageClasses.

- It runs in its own `redis-operator` namespace.
- It watches all namespaces (cluster RBAC scope, the chart default). So it reconciles per-workload `Redis` CRs in
  any namespace.
- A CR applied before the operator is up fails its sync and retries.
- Sync options: automated `prune` and `selfHeal`, `CreateNamespace=true`, and `ServerSideApply=true` because the
  CRDs are large.

The operator needs only the CNI, so wave 2 would fit, like `cnpg-operator`. It stays at wave 3 because the `NN`
prefix is stable and is not renumbered. This makes no difference in practice. Redis workloads come after the
platform and need Longhorn (wave 2) anyway.

Values under `redis-operator:` that need a reason:

- `redisOperator.webhook: false`. The admission webhook only guards the master-slave anti-affinity feature of
  `RedisReplication`, which this repo does not use. With the webhook off, there is no serving cert to manage and
  no cert-manager dependency. The chart's webhook templates render nothing.
- `redisOperator.metrics.enabled: true` exposes the controller's `/metrics` on `:8080`. No PodMonitor ships,
  because the upstream chart has no toggle for one. The signal that matters is the per-instance redis-exporter.
  The endpoint stays on for a future PodMonitor.
- `resources` is lowered from the chart's 500m/500Mi default to a 10m/60Mi request and a 92Mi memory limit, with
  no CPU limit. The map is fully specified, not memory-only. Helm deep-merges it, so an omitted key would silently
  inherit 500m.

The CRDs ship in the chart's `crds/` directory. Argo CD renders Helm with `--include-crds`, so they apply on sync.

## The reusable chart (`lib/helm/redis-instance`)

A first-party `type: application` chart. It templates the `Redis` CR itself and has no upstream dependency. So it
has no `Chart.lock` and no vendored `charts/*.tgz`. The CRD comes from the operator. Every shared chart in
`lib/helm/` follows this shape. It renders:

- the `Redis` CR.
- a `ServiceMonitor`.
- a `CiliumNetworkPolicy`.
- a `validate.yaml` that fails the render when a required knob is missing.

Each instance is one alias:

```yaml
# Chart.yaml
- { name: redis-instance, alias: redis-cache,    version: "*", repository: "file://../../../../lib/helm/redis-instance" }
- { name: redis-instance, alias: redis-sessions, version: "*", repository: "file://../../../../lib/helm/redis-instance" }
```

```yaml
# values.yaml: the required knobs, and the optional initialFixedDiskSize
redis-cache:
  name: sample-user-manager-redis-cache   # also the Service DNS name clients connect to
  # renovate: datasource=docker depName=quay.io/opstree/redis
  redisVersion: "v8.6.2"                  # REQUIRED: Redis server version, owned per workload
  persistence: false                      # REQUIRED, no default. See the table below
  deletionProtection: true                # REQUIRED
  resources: { requests: { cpu: 25m, memory: 64Mi }, limits: { memory: 96Mi } }
  allowedClients: [ { matchLabels: { app: sample-user-manager } } ]   # same namespace only, so no namespace key
  # initialFixedDiskSize: 2Gi   # optional, default 1Gi, used at creation only. See "Resizing an instance"
```

`templates/redis.yaml` hardcodes everything a workload should not decide. One edit there changes every instance:

- the image repository.
- the full redis-exporter image reference.
- non-root uid and gid 1000.
- `maxmemory` at 80% of the memory limit, so Redis cannot OOM its cgroup.
- no auth.

`persistence` sets AOF and the backup label.

The server image tag is the one exception. It is a per-workload knob (`redisVersion`), so each workload owns its
Redis version. The full knob list is in `lib/helm/redis-instance/values.yaml`.

## Storage and persistence

A standalone `Redis` has one PVC. It is always on `longhorn-r2-ephemeral`:

- `numberOfReplicas: 2`, so even a cache survives a node loss.
- `reclaimPolicy: Delete`.

That class is a generic shared Longhorn tier from `02_longhorn`, not a Redis-specific class. See
[05_storage.md](05_storage.md).

`persistence` does not pick a class. `deletionProtection` guards the data, so the reclaim policy adds no safety:

- An accidental prune cannot delete the instance. Restore the files in git and nothing is lost.
- An intentional delete falls back to the S3 dump, with its RPO window.

A Retain class would add nothing in either case. It would leave an orphaned `Released` PV after every deliberate
delete.

What `persistence` controls:

| `persistence` | AOF | S3 RDB backup | For |
|---|---|---|---|
| `true` | on (`appendfsync everysec`, so about 1s of worst-case loss on a hard crash) | enrolled daily, through the `redis-backup.offgrid/enabled` label | durable data |
| `false` | off, RDB snapshots only | not enrolled | disposable caches |

**Deletion protection** is the real prune guard, not the reclaim policy.

- `deletionProtection` is a required bool with no default. It is independent of `persistence`.
- It stamps `argocd.argoproj.io/sync-options: Prune=false,Delete=false` on the Redis CR, its ext-config
  ConfigMap, its ServiceMonitor and its NetworkPolicy.
- When the manifests leave git, Argo CD orphans the running instance instead of deleting it. Restoring the
  manifests re-adopts it. There is no outage and no PV rebind.
- Keep it `true` in steady state for every instance, caches included.

An orphaned instance then shows up in one of two ways:

- as an app that stays OutOfSync (`argocd-health.yaml`).
- as `orphaned_redis_instance` from `05_orphan_exporter`, if the whole app is gone.

Client-egress policies are not protected, by choice. They are easy to render again, and the client pods get
pruned with the workload anyway.

**AOF**, persistent instances only:

- `templates/configmap.yaml` renders an extra-config ConfigMap, `<name>-ext-config`. The CR's
  `redisConfig.additionalRedisConfig` points at it.
- It sets `appendonly yes` and `appendfsync everysec`.
- On restart the instance replays its append-only log. So a hard crash loses at most about 1s of writes, not
  everything since the last RDB snapshot.
- AOF and RDB files both land on the PVC (`dir=/data`).

Ephemeral instances skip the ConfigMap and run RDB only. They survive a restart through the snapshot, but not a
crash. The volume is discarded on delete.

**`maxmemory` and eviction**, both modes:

- `maxMemoryPercentOfLimit: 80` sets `maxmemory` to 80% of the container memory limit.
- The 20% headroom keeps the kernel from OOM-killing the pod. It covers:
  - copy-on-write during the persistence fork. Every page changed during an RDB save or AOF rewrite is copied.
  - overhead outside the dataset: client and AOF buffers, and jemalloc fragmentation.
- Eviction stays at the Redis default, `noeviction`. At the cap, writes fail. Redis never drops data silently.

**Active defrag**, both modes:

- jemalloc does not return freed memory. So a workload with many allocations and frees leaves `used_memory_rss`
  inflated and `mem_fragmentation_ratio` rising.
- The cache does exactly that. It RPUSHes audit entries per UUID with a 1h TTL.
- `activedefrag yes` lets Redis compact memory while it runs.
- The upstream trigger defaults never fire on a Pi-sized instance. `active-defrag-ignore-bytes 100mb` is far above
  a `maxmemory` of about 77Mi. So the chart lowers them to `ignore-bytes 16mb` and `threshold-lower 15%`.

**Disk size**: size the disk against memory, not against the dataset.

- `noeviction` lets the keyspace grow to `maxmemory`, about 80% of the memory limit.
- Redis persists that whole dataset. RDB takes about 1x, and AOF up to about 2x during a rewrite.
- So budget the PVC at about 2x the memory limit.
- If the disk fills, `stop-writes-on-bgsave-error` (the Redis default) stops writes. This is the same safe but
  degraded failure as hitting `maxmemory`.
- `initialFixedDiskSize` (default 1Gi) and `resources.limits.memory` are linked. Raise both together.
- The 1Gi default covers the small instances here. A 96Mi limit leaves about 10x headroom.

**Out of scope: HA.** A single standalone pod means a node loss makes the instance unavailable for a short time.
It is back once the pod reschedules and reattaches its volume. A workload that needs more would use a
`RedisReplication` or `RedisSentinel` variant. Neither exists in this repo.

## Off-cluster backups: RDB to S3

Durable instances get periodic RDB dumps to S3. Ephemeral instances never do. Their data can be rebuilt by
definition.

One central platform app, `07_redis_backup` (wave 7, namespace `redis-backup`), backs up the whole cluster. There
is no CronJob per instance.

- Benefit: one sealed secret in one namespace, and no list of namespaces.
- Cost: one global schedule, and alerts per job, not per instance.

It shares the S3 bucket and IAM writer with CNPG. See [10_backups.md](10_backups.md) for the bucket, Terraform and
credentials.

How it works:

- **Discovery, not a list.** The `redis-instance` chart stamps `redis-backup.offgrid/enabled: "true"` on the
  `Redis` CR of every durable instance. The job's `list` container runs `kubectl get redis -A -l ...` through a
  read-only ClusterRole. So it finds a durable instance in any namespace.
- **Dump.** For each instance, the job runs `redis-cli --rdb` against the instance's Service on `:6379`.
  - That is a replication full sync. So the dump is an app-consistent point-in-time RDB, with no access to the PVC
    or the AOF file.
  - It needs no auth. The network policy is the gate.
  - The job continues past a failed instance, so a partial success still uploads.
  - The dump image does not need to match the server major version. `--rdb` only streams bytes.
- **Upload.** `aws s3 cp` sends each dump to `s3://<bucket>/redis/<namespace>/<name>/<UTC>.rdb`.
  - Credentials come from the single sealed `redis-backup-s3` secret (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`).
  - The bucket encrypts at rest. Its lifecycle rules handle retention and tiering.
  - The job exits non-zero if any instance failed. So the Job fails and the alert fires. The job's stdout names
    the failed instance, and it lands in VictoriaLogs.
- **Network.** The job's CiliumNetworkPolicy allows egress to the kube-apiserver for discovery, to DNS, to `:6379`
  in any namespace, and to S3 on `:443`. Each durable instance's own policy hardcodes an inbound allow from the
  `redis-backup` namespace.

To turn it on, run `make configure-redis-backup` (step `10c`), then commit and push. The step does three things:

1. It reads the Terraform writer credentials.
2. It writes `bucket` and `region` into the app's `values.yaml`.
3. It seals `redis-backup-s3` into the `redis-backup` namespace.

If `AWS_DEPLOY_ACCESS_KEY_ID` in `.env` is empty, the step does nothing and the CronJob does not render. An empty
value means the feature is off, as everywhere in this repo. `make bootstrap-cluster` runs this step, so a fresh
cluster comes up with backups on. The schedule lives in the app's `values.yaml`. The default is daily at 02:00 UTC.

Grafana alerts for Redis backups:

| Alert | Scope | Severity | Catches |
|---|---|---|---|
| `job-failed` | job | warning | a backup run that exited non-zero. It covers every Job in the cluster |
| `redis-backup-stale` | job | warning | no successful run in 36h |
| `redis-no-recoverable-backup` | instance | critical | one instance with no usable backup, including a dump that uploaded empty |

Only the last one catches a single instance that silently stops being backed up. See
[10_backups.md](10_backups.md).

### Restore from S3

`make restore-redis` is the runbook, and you run it. It calls `lib/shell/recover_redis_from_s3.sh` with the flags
`--namespace --instance [--target latest|<N>|<s3-key>] [--apply]`. It asks for any flag you leave out.

1. It compares what git declares with what the cluster has, and prints that state.
2. It gets an instance to restore into.
3. It picks a dump and replays it.
4. It turns deletion protection back on.

Run it and read what it prints. This doc does not repeat the steps.

Pick by symptom:

| Symptom | What to do |
|---|---|
| Instance running, data wrong or gone (bad write, corruption, a rewind) | `make restore-redis` |
| Instance gone, its alias still in git (node or PVC loss, cluster rebuild) | `make restore-redis`. The script waits for Argo CD to rebuild the empty instance, then loads the dump |
| Instance gone and removed from git (a deliberate two-commit delete) | Put back its values block and its `Chart.yaml` alias, push, then run `make restore-redis`. The script cannot recover the alias from `values.yaml` alone. This is the one step it cannot do for you |
| Instance running, app stays OutOfSync | Restore the files in git. Argo CD re-adopts the instance. No data moves, nothing to run |

Two things the script cannot tell you at runtime:

- **Why replication.** The script makes the target a `REPLICAOF` of a temporary seed pod that holds the dump. A
  full resync carries every type, TTL and score exactly. The script does not use:
  - a PVC swap, which fights the operator and the AOF.
  - `redis-rdb-tools`, which is unmaintained and breaks on new RDB versions.

  An offline restore is possible, but no script does it.
- **The operator can reconcile the `Redis` CR during a restore.** The manual `REPLICAOF` usually holds long
  enough to sync. Run the script again if it races.

`redis_backup_recoverable` is the per-instance backup health metric. The job-level alerts cannot see one instance
that silently stops being backed up.

## Resizing an instance

`initialFixedDiskSize` is the size the volume gets at creation. Changing it later does nothing to a running
instance.

- The size lives in the `volumeClaimTemplate` of the operator-managed StatefulSet. Kubernetes treats it as
  immutable, and it only applies to new PVCs.
- The OpsTree operator does not reconcile PVC expansion. On a storage change it only re-creates the StatefulSet,
  which adopts the same PVC at its old size.
- So a changed value has no effect. The operator's reconcile can error. The pod keeps its original disk, and
  nothing restarts or gets wiped.
- CNPG in this repo does reconcile a storage size change. Redis does not, so do not expect the same behaviour.

To grow a live instance, expand the PVC directly. The class `longhorn-r2-ephemeral` sets
`allowVolumeExpansion: true`. So Longhorn grows the volume and the ext4 filesystem online, with no restart and no
data loss:

```bash
kubectl -n <ns> get pvc                                   # find the instance's PVC (owned by the StatefulSet)
kubectl -n <ns> patch pvc <pvc> --type merge \
  -p '{"spec":{"resources":{"requests":{"storage":"5Gi"}}}}'
```

- `selfHeal` does not revert this. Argo CD does not manage the StatefulSet-owned PVC, and the operator never
  shrinks it.
- Raise `initialFixedDiskSize` in git to match. Then a rebuild from scratch creates the volume at the new size and
  needs no second expansion.
- An Argo CD PreSync hook Job that patches the PVC would let the git change drive the expansion. This repo does
  not have one. The manual patch is simpler for a homelab.

You cannot shrink a PVC in place. Kubernetes only lets `requests.storage` grow, and the API server rejects any
shrink, Longhorn included. That check stops a filesystem from being cut under live data.

To shrink, or for any change the in-place path cannot do, migrate to a new instance:

1. Add another alias with the size you want.
2. Copy the data across while both instances run.
3. Point the app at the new instance.
4. Delete the old alias.

```bash
# per-key move between two standalone instances (keeps TTLs, MIGRATE is atomic per key):
kubectl -n <ns> exec <old-pod> -- sh -c '
  redis-cli --scan | while read k; do
    redis-cli MIGRATE <new-svc> 6379 "$k" 0 5000 COPY REPLACE
  done'
```

- `--scan` does not block the server the way `KEYS *` does.
- `COPY` leaves the source intact for rollback. Drop the source once you have checked the copy.
- For a large dataset, use a streaming tool such as `redis-shake`.
- Then point the app at the new instance: set `app.redises[0]` to the new instance's `name`, so `REDIS_ADDR`
  follows. Sync, check, and delete the old alias as in the next section.

The sample data is audit logs with a 1h TTL that the app regenerates. So starting empty on a new instance is
often simpler than a migration.

## Deleting an instance (two commits)

With `deletionProtection: true`, removing an alias from git orphans the instance. It keeps running without
management, and the app stays OutOfSync. So a delete takes two commits, through GitOps only, with no
`kubectl delete`:

1. Set `deletionProtection: false` on that alias. Commit, push, and let Argo CD sync.
   - The data is untouched, but the pod restarts. The operator copies the CR's annotations onto its StatefulSet
     pod template, so adding or removing the sync-options rolls the pod.
   - AOF on the PVC carries the data across. Measured: about 20s, with no loss.
   - CNPG is different. There the same change does nothing to the pods.
2. Remove the alias: its values block and its `Chart.yaml` dependency entry. Commit and push.
   - The next sync prunes it, and the PVC goes with it.
   - The volume then follows the class reclaim policy, `Delete`. It is gone for good. The off-cluster S3 dump is
     the only copy left.

Never leave an instance on `false`. It is a short state between those two commits, not a config choice. CNPG uses
the same flow, see [10_backups.md](10_backups.md).

## Security: no password, gated by network policy

Redis runs without `requirepass`. Each instance's default-deny `CiliumNetworkPolicy` controls all access at the
network layer. Only these may open `:6379`:

- the owning workload's pods (`allowedClients`).
- the operator, to reconcile.
- vmagent, to scrape metrics.

Instances are ClusterIP only and never exposed through ingress.

The operator pod has its own default-deny policy (`03_redis_operator/templates/networkpolicy.yaml`):

- in: the kubelet health probe.
- out: DNS, the API server, and any managed Redis on `:6379`.

The Redis egress rule crosses namespaces through `matchExpressions` with namespace `Exists`. In Cilium the empty
`{}` selector matches the same namespace only. See [01_networking.md](01_networking.md).

Why no password:

- The repo's [secrets rule](03_secrets.md) is: never commit a secret the cluster can mint itself.
- Sealed Secrets are for credentials a human supplies from outside, such as the OAuth client secret.
- The cluster can mint a Redis password. So it would take the CNPG or RabbitMQ route: the operator generates it,
  and the app reads it through `secretKeyRef`, with nothing in git.
- The OpsTree operator does not generate one.
- A random password generated by Helm does not stay stable under Argo CD. The repo-server renders with
  `helm template`, where the `lookup` function returns nothing. So the password changes on every sync.

Two clean options remain. This repo takes the first:

1. **No password, with a `CiliumNetworkPolicy`.** Chosen. The network policy is the access control, and there is
   nothing to commit or generate. That is enough for a cache that only its own workload can reach and that is
   never exposed.
2. **A committed SealedSecret.** Not wired. To add `requirepass`, add a `redisSecret: { name, key }` to
   `templates/redis.yaml` that points at a SealedSecret. This is a small chart edit, not a per-workload knob, on
   purpose. The default is no password, and keeping auth out of the values keeps the workload interface small.

Roll out the network policy in audit mode first, like every network policy here:

1. Put the redis endpoints in Cilium `PolicyAuditMode`.
2. Run `hubble observe --verdict DROPPED,AUDIT` while the pod starts, the operator reconciles, a client connects
   and vmagent scrapes.
3. Enforce only when the output is clean.

Audit mode also protects the pod-label selector (`app: <name>`). If the operator ever changes its pod labels,
audit mode shows it before enforcement could leave an instance unprotected.

## Monitoring

Each instance turns on the redis-exporter sidecar. It ships a `ServiceMonitor` that selects the instance's
operator-created Service (`app: <name>, redis_setup_type: standalone, role: standalone`, port `redis-exporter`).
The VM operator converts it to a `VMServiceScrape`. vmagent discovers it in any namespace
(`selectAllByDefault`). So it reaches VictoriaMetrics with no extra config. See
[06_monitoring.md](06_monitoring.md).

The `redis_*` metrics feed the `redis-health` group (`05_grafana/files/alerts/redis-health.yaml`):

- `redis-down`, with dynamic severity: critical for an `alertCritical` instance, warning otherwise.
- Memory against `maxmemory`: warning above 90%, critical above 98%. With `noeviction`, writes fail near the cap.
  Redis does not evict.
- Rejected connections, and connections close to `maxclients`.
- RDB and AOF last-save failures.
- Fragmentation, only when the instance is over 50% full
  (`redis_memory_used_bytes / redis_memory_max_bytes > 0.5`).
  - On a small, almost empty instance, the fixed RSS floor dwarfs the dataset. That floor is code pages, jemalloc
    arenas and buffers.
  - It pushes `mem_fragmentation_ratio` above 1.5 with no real fragmentation.
  - The fill floor drops that false positive and works at any instance size.

The backup alerts in the `backups` group are separate. The platform outage rules `container-waiting-fatal` and
`statefulset-not-available` also catch an instance that crashloops or is down. They use the same
`alert-criticality` label.

**arm64 exporter caveat**: the OpsTree `redis` chart's default exporter tag (`quay.io/opstree/redis-exporter`)
is amd64 only and does not run on the Pi 5. So the `redis-instance` chart pins a recent multi-arch tag. Before
you bump it, check for arm64 through the quay v2 manifest-list API. The redis and operator images are
multi-arch.

## The sample: audit-log cache and `GET /audit`

`sample_user_manager` creates two instances. They show that a workload can have several instances, and they show
both persistence modes:

- `redis-cache`, `persistence: false`. The demo treats the audit-log cache as ephemeral. Its data has a 1h TTL
  and the app can regenerate it.
- `redis-sessions`, `persistence: true`, durable. It holds one session hash per user and a `sessions:active` set.
  The data survives a restart and is enrolled in the S3 backup.

App wiring:

- One flat `app.redises` list, with no primary or extra split.
- `redises[0]` maps to the bare `REDIS_ADDR`, and `redises[1]` to `REDIS_SESSIONS_ADDR`. The manager connects to
  these two.
- Every entry also gets a `REDIS_<NAME>_ADDR`. Beyond those two, nothing reads it.
- The app network policy lists no Redis egress. Each instance's chart renders a client-egress CNP from its own
  `allowedClients`. That is the single source for the app-to-Redis path.

The manager binary ([`pi5-k8s-sample-app`](https://github.com/yama6a/pi5-k8s-sample-app), `internal/audit`):

- It emits an `AuditLog` on every user create or delete, and broadcasts it on the `user-audit-logger` fanout.
- It stores each event in `redis-cache` with `RPUSH audit:<uuid>` and `EXPIRE 1h`, refreshed on each write. So a
  user's events disappear an hour after their last activity.
- `GET /audit` runs `SCAN` over the `audit:*` keyspace and `LRANGE` on each list. It returns a JSON map of user
  UUID to events. The user table is capped, so that is at most about 10 users.
- It connects to `REDIS_ADDR` with no credentials. The network policy is the gate.

`internal/session` writes to the second instance on the same two events:

- On create: `HSET session:<uuid>` with `state=active`, and `SADD sessions:active`.
- On eviction: `state=ended`, `SREM`, and a 24h `EXPIRE`. So the keyspace stays bounded under `noeviction`.
- An open session has no TTL. That is why it lives on the durable instance.
- It has no HTTP endpoint. Read it with `redis-cli`.

The audit feature lives in the `pi5-k8s-sample-app` repo and ships as a new GHCR image tag. The manifests pin an
exact tag. So after that image is published, bump `app.image` in `sample_user_manager/values.yaml`. Until then
the running image has no `/audit`.

## Verify

```bash
# Charts render (local)
helm dependency update argo_apps/platform/charts/03_redis_operator
helm template argo_apps/platform/charts/03_redis_operator --include-crds | grep -cE '^kind: CustomResourceDefinition'   # 4 CRDs
helm template argo_apps/workloads/charts/sample_user_manager -n sample-user-manager | grep -c '^kind: Redis'   # 2

export KUBECONFIG=.cache/kubeconfig                                       # the pinned kubeconfig common.sh writes
kubectl -n redis-operator get pods                                        # operator Running
kubectl -n sample-user-manager get redis                                  # redis-cache and redis-sessions
kubectl -n sample-user-manager get pvc -o wide                            # both on longhorn-r2-ephemeral
kubectl -n longhorn-system get volumes.longhorn.io                        # each Redis volume: 2 replicas
kubectl get vmservicescrape -A | grep -i redis                            # metrics reach VictoriaMetrics

# both instances get writes
kubectl -n sample-user-manager exec sample-user-manager-redis-cache-0    -- redis-cli --scan --pattern 'audit:*'
kubectl -n sample-user-manager exec sample-user-manager-redis-sessions-0 -- redis-cli SMEMBERS sessions:active
```

Smoke test:

1. Create and delete a user through the `sample-user-signup` command flow that the manager consumes.
2. Run `curl https://sample-user-manager.app.example.com/audit`. It returns events grouped by UUID.
3. Check the 1h TTL with
   `kubectl -n sample-user-manager exec sample-user-manager-redis-cache-0 -- redis-cli TTL audit:<uuid>`.
