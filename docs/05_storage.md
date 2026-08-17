# Storage & database

One storage layer and a database operator, all pure-GitOps wave-2 leaves with no imperative script. Each needs
one host prerequisite the README states: a dedicated filesystem, bind-mounted into the kubelet with `rshared`.

| Layer | Classes | Replicates at | Backs |
|---|---|---|---|
| [Longhorn](#longhorn) | `longhorn-r2-ephemeral`, `longhorn-r2-ephemeral-local`, `longhorn-r2-retained-with-backups` | the volume | everything: Postgres, RabbitMQ, Redis, the monitoring stores, ntfy |

There is **no default StorageClass**. Every PVC names one, or it stays `Pending`.

Per-node disk layout on the cluster this was developed against, carved by its node tooling: 64 GiB for the OS,
then a dedicated data volume taking the whole remainder.

## Why everything is on Longhorn, including the apps that replicate themselves

Postgres has streaming replication and RabbitMQ has Raft quorum queues, so replicating the block device under
them is redundant work. Node-local storage is nonetheless **not** used, and the reason is recovery, not
performance.

A node-local PV is pinned to one machine. Replace or wipe that machine and the PVC stays `Bound`, node-affine,
and pointing at an empty directory. Nothing resolves that on its own: an empty volume and a corrupt one look
identical from the outside, so no operator will delete a PVC that might hold the last copy of something. The pod
crashloops until a human deletes it by hand.

- CNPG: `pg_controldata: exit status 1`, forever.
- RabbitMQ: `Ra could not create its data directory`, forever.

The cost is not the deleting, which a script can do. It is the **noticing**, which nothing bounds. Until someone
looks, a 3-broker RabbitMQ runs at 2/3 with no spare, and a second machine loss drops it below majority and stops
accepting writes. A single-instance Postgres needs a full S3 restore, two git commits and a password roll.

On Longhorn the volume is not tied to the dead machine, so the pod reattaches on a survivor and comes back by
itself. Measured by unplugging a machine's ethernet: both databases were serving again ~190s later, unattended,
against 402s when [the dead-node watcher](13_node_loss.md) was suppressed and forever under node-local
storage. Timings and the split-brain result are in [13_node_loss.md](13_node_loss.md).

The price is latency, and it is small: Postgres commit p50 6.02 to 7.50 ms, RabbitMQ confirm p99 9.4 to 18.4 ms
with a local replica. Both land inside what RDS Multi-AZ, Cloud SQL HA, SQS and Pub/Sub deliver, so the numbers
we give up are ones a managed service would not have given us either. Full tables in
[12_storage_bench.md](12_storage_bench.md).

## Longhorn

Distributed block storage that replicates each volume across nodes, on the dedicated XFS `longhorn` user volume
mounted at `/var/mnt/storage`.

Chart: `argo_apps/platform/charts/02_longhorn/`.

### V1 data engine, not V2/SPDK

V2 (SPDK) has a known stuck-I/O bug on ARM64 + NVMe with 2+ cores, which is exactly the Pi 5. V1 is also lighter
on low-power nodes. Revisit if upstream fixes it.

### Host prerequisites

Set up outside this repo, and listed in the README: `iscsid` and `fstrim` on every node, 4K kernel pages (XFS
will not mount on 16K), and the dedicated data volume. Longhorn adds one thing, a kubelet bind-mount. On the
Talos cluster this was developed against that looks like:

```yaml
machine:
  kubelet:
    extraMounts:
      - destination: /var/mnt/storage
        type: bind
        source: /var/mnt/storage
        options: [ bind, rshared, rw ]
```

A containerized kubelet does not auto-propagate host mounts into itself, so without the bind Longhorn's pods
see an empty directory. `rshared` is required so per-replica sub-mounts propagate back to the host. If your
kubelet runs on the host rather than in a container, the mount just has to exist and be shared.

Your node config is the source of truth, so any rebuild gets it. On a live cluster apply the equivalent per
node BEFORE the Longhorn app syncs, or the manager pods come up with every node's disk unschedulable.

### Values worth calling out

| Value | Why |
|---|---|
| `defaultDataPath: /var/mnt/storage` | the dedicated user volume, not the ephemeral `/var/lib/longhorn` |
| `defaultReplicaCount: 2` | with `replicaSoftAntiAffinity` at its default `false`, so hard anti-affinity, one replica per node |
| `persistence.defaultClass: false` | no cluster-default class; a PVC that omits one stays `Pending` |
| `storageMinimalAvailablePercentage: 15` | headroom on the Pi NVMes; do not schedule onto a disk under 15% free |
| `preUpgradeChecker.jobEnabled: false` | that Helm pre-upgrade hook Job can stall an ArgoCD sync waiting on completion |

Why 2 replicas and not one per node: 2 survives the single node loss we design for AND leaves at least one spare
node to rebuild the lost replica onto. Raising it to the node count leaves no spare under hard anti-affinity, so
a volume stays degraded until the dead node returns.

Adding a node does not move existing replicas. `replica-auto-balance` is at its default `disabled`, so a new
node stays empty of replicas until new volumes are created or something rebuilds. That is usually what you want;
`replica-auto-balance: best-effort` spreads them over time if the concentration bothers you.

### The three StorageClasses

Rendered by `templates/storageclasses.yaml`, all `numberOfReplicas: 2`.

| Class | reclaimPolicy | dataLocality | S3 backup | Use for |
|---|---|---|---|---|
| `longhorn-r2-ephemeral` | Delete | disabled | none | the general-purpose tier |
| `longhorn-r2-ephemeral-local` | Delete | best-effort | none | small volumes where write latency matters: RabbitMQ |
| `longhorn-r2-retained-with-backups` | Retain | disabled | daily + weekly | precious data with no app-level backup (sqlite, config). No consumer yet |

The `-with-backups` class adds off-cluster S3 backups via `recurringJobSelector`; see
[10_backups.md](10_backups.md).

**`dataLocality: best-effort`** keeps one of the two replicas on whichever node the pod runs on, so reads and
half the write path stay on that SSD. Worth 31% off RabbitMQ's confirm p99, and only 4% for Postgres, because a
durable Postgres write has to reach both replicas either way. The catch is that Longhorn drags a full local copy
along on every reschedule, so it is right for a queue whose consumers keep it near-empty and wrong for a database
that can grow: it would pull the whole thing across 1GbE on every failover.

**Sizes are ceilings, not reservations.** Longhorn is thin, so a volume occupies only what has been written to
it. What the spec size does consume is Longhorn's per-node *scheduling* budget, which counts the full number, and
it is what the >90%-full alert measures against. So set a real ceiling, not a generous one.

A weekly `filesystem-trim` RecurringJob (`templates/recurringjobs.yaml`) returns blocks the filesystem has freed,
which is what keeps a thin volume thin. It reaches every volume through Longhorn's `default` group: a volume with
no recurring job of its own is put there automatically. Chosen over mounting with `discard`, which would put
reclaim inline in the write path on a consumer NVMe whose tail latency is already the weak point. It reclaims
real space for RabbitMQ, whose segments are deleted once consumed, and very little for Postgres, which reuses
pages internally and recycles WAL by rename.

A StorageClass's `parameters` are **immutable**. Adding a key to a class that already exists means deleting the
class by hand first; ArgoCD will otherwise report the sync failure forever.

**Why there is no plain Retain class.** Every stateful app stamps `deletionProtection`
(`Prune=false,Delete=false`) on the CR or PVC owning its storage, so it is already immune to the accidental
case: a prune cannot delete the object, restoring the files brings it back with zero loss, and nothing is ever
`Released`. Given that, `Retain` protects nothing a deliberate deletion did not mean and only leaks orphaned
PVs. So everything uses a Delete class and accepts that regretting a deliberate delete costs that store's backup
RPO. The one exception is `longhorn-r2-retained-with-backups`, for data with no app-level backup at all, which is
also the restore target in `recover_longhorn_from_s3.sh`.

### Operational notes

- Privileged Pod Security: Talos enforces `baseline`, so the Application stamps
  `pod-security.kubernetes.io/enforce: privileged` on `longhorn-system` via `managedNamespaceMetadata`.
- `ServerSideApply`, because the CRDs blow the client-side last-applied-annotation limit.
- `metrics.serviceMonitor.enabled: true` feeds `longhorn_*` to the stack, driving the `longhorn-health` Grafana
  alerts: manager-down, node NotReady, disk-unschedulable, node-storage over 85%, volume degraded or faulted,
  volume near-full. See [06_monitoring.md](06_monitoring.md).
- If a Longhorn-managed field flaps `OutOfSync` after first sync (it mutates its own StorageClass or a webhook
  config), add a targeted `ignoreDifferences` rather than fighting `selfHeal`.
- Deliberately deleting the app or its CRDs destroys the volumes. Back up before any teardown.

### Verify

```bash
talosctl -n 192.168.10.201 read /proc/mounts | grep storage    # /var/mnt/storage present (after the patch)
kubectl -n longhorn-system get pods                            # manager on all 3 nodes + CSI Running
kubectl -n longhorn-system get nodes.longhorn.io -o wide       # each node's disk Schedulable
kubectl get storageclass                                       # the three longhorn-r2-* classes, NO default
kubectl -n longhorn-system get recurringjob                    # filesystem-trim-weekly (+ the backup jobs)
```

Smoke test: apply a 1Gi PVC with `storageClassName: longhorn-r2-ephemeral` plus a pod, confirm it goes `Bound`
and the volume shows 2 healthy replicas on two distinct nodes.

## CloudNativePG

[CNPG](https://cloudnative-pg.io) reconciles a declarative `Cluster` CR into an HA Postgres: primary plus
streaming replicas, with failover, rolling updates and metrics. Two apps, split across the two trees so operator
and database land in dependency order (see [`02_gitops.md`](02_gitops.md)):

| App | Tree | What |
|-----|------|------|
| `cnpg-operator` (`platform/charts/02_cnpg_operator`) | platform, wave 2 | the controller + its CRDs, an independent leaf |
| `sample-user-manager` (`workloads/charts/sample_user_manager`) | workloads, no wave | two Postgres `Cluster`s on the `longhorn-r2-ephemeral` class |

Workloads carry no `sync-wave`. The root-of-roots creates the workloads tree about 5s after the platform tree
with no health gate, so a `Cluster` CR applied before its CRD registers fails its sync and retries until the
operator lands. See [`02_gitops.md`](02_gitops.md).

Versions: the operator dep `cnpg/cloudnative-pg` in `02_cnpg_operator/Chart.yaml`; the `Cluster` comes via the
shared `pg-cluster` wrapper (`lib/helm/pg-cluster`), which renders the CNPG CRs directly with no upstream chart
and pins the `ghcr.io/cloudnative-pg/postgresql` image itself. Postgres only, no postgis. Multi-arch incl. arm64.

A workload declares `pg-cluster` as an **aliased** `file://` dependency, once per database, so the alias is the
values key and its knobs sit flat under it.

### Storage and what a node loss costs

`longhorn-r2-ephemeral`, `dataLocality: disabled`. Not the `-local` variant: it would buy 4% and pay by hauling
the whole database across 1GbE on every failover. Reasoning for Longhorn at all is
[above](#why-everything-is-on-longhorn-including-the-apps-that-replicate-themselves).

So there are now two independent layers of redundancy, and each covers a different failure:

| Layer | Covers |
|---|---|
| Postgres replication (`highAvailability: true`) | the primary dying: a standby is already caught up and gets promoted, measured at ~97s of write unavailability |
| Longhorn's 2 replicas | the volume's node dying: the volume reattaches elsewhere with its data intact |

Which means a machine loss is uneventful either way:

- `highAvailability: true`: 3 instances, one per node. One dies, a standby is promoted, writes continue. The
  third instance has nowhere to go while only 3 machines exist, so it stays Pending until the machine returns.
- `highAvailability: false`: the single instance moves to a survivor with its volume and restarts there. Crash
  recovery replays WAL, which is what a `kill -9` on any Postgres does. No S3 restore.

### Operator values

`crds.create: true`, `monitoring.podMonitorEnabled: true`, modest `resources` (it only reconciles), and
`INHERITED_LABELS: alert-criticality` so the label reaches the Postgres pods for the outage alerts.

The operator pod carries a pod-scoped `CiliumNetworkPolicy`: in from vmagent metrics, the apiserver webhook and
the kubelet probe; out to DNS, the apiserver, each instance's instance-manager, and the barman-cloud plugin. See
[01_networking.md](01_networking.md).

### Cluster values

Most of the tree is pre-baked in the `pg-cluster` wrapper. A workload sets only these:

| Knob | Required | Notes |
|---|---|---|
| `name` | yes | used verbatim: the Cluster, its `<name>-rw`/`-ro`/`-r` Services, the `<name>-app` Secret |
| `postgresVersion` | yes | a MAJOR, and a key into the wrapper's pinned image map; changing it is an upgrade, see below |
| `highAvailability` | yes | one bool: true = 3 instances + synchronous `any 1` + PDB + switchover, false = 1 instance, no sync, PDB off, in-place restart |
| `size` | yes | per-instance disk CEILING; thin, so it reserves nothing, but it does spend Longhorn's scheduling budget |
| `resources` | yes | per-instance, no default; forced choice on a Pi |
| `allowedClients` | yes | who may open 5432; also drives the client-side egress policy |
| `deletionProtection` | yes | one bool, no default; the only thing between a stray prune and gone data |
| `alertCritical` | no | stamps `alert-criticality`, so a crashloop pages critical rather than warning |

Wrapper-baked, worth knowing:

- `affinity.topologyKey: kubernetes.io/hostname` plus `podAntiAffinityType: required`. The chart default spreads
  by `topology.kubernetes.io/zone`, but bare Pi nodes carry no zone label, so every instance could land on one
  node. `required` refuses to place two on one node rather than merely preferring not to, so two instances can
  never share a machine and a machine loss can never take two at once. The price: with 3 machines the third
  instance has nowhere to schedule while one is down, and it waits rather than doubling up.
- `postgresql.synchronous: {method: any, number: 1, dataDurability: required}`, only when `highAvailability`. A
  commit waits for one of the two standbys to flush it, so a promoted standby can never be missing a transaction
  the application was told had committed. `required` means that if no standby can acknowledge, writes STALL
  rather than silently degrading to asynchronous, which is the whole point: `preferred` would quietly reopen the
  hole. With 3 instances, `any 1` of two standbys still acknowledges while one node is drained, which is what
  makes a rolling Talos upgrade safe. Measured cost: about 2 ms on commit p99.
- One bool, not three knobs: 3 instances and synchronous replication are exactly the same case, since 1 instance
  has no standby to be synchronous with. 2 instances and more than 3 are out of scope.
- `postgresql.parameters` sized for the Pi 5s, overridable per workload.
- `initdb: { database: app, owner: app }`. The operator auto-generates the owner's credentials into the
  `<name>-app` Secret, so no sealed secret is needed.
- The chart's own CNPG alert rules are disabled: `vmalert` is off, so a VMRule would never fire. The CNPG backup
  and operational alerts are Grafana rules instead. See [10_backups.md](10_backups.md).

### Major version upgrade

Bump `postgresVersion` to the next major and merge. That is the whole change: the operator sees a higher major in
`imageName` and runs an offline in-place `pg_upgrade --link` itself, and the chart rotates the backup catalog to
`<name>-pg<major>` in the same render, which is what keeps the old one restorable.

What it costs, before you start:

- Full downtime for the database, replicas included, for as long as `pg_upgrade` takes. A few minutes for a small
  DB; re-cloning replicas afterwards is the slow part on a large one.
- No PITR across the boundary. The pre-upgrade catalog can only restore to a pre-upgrade point, forever.
- Extensions are yours to check. The operator does not touch them.
- Only between images on the same OS distribution, so trixie to trixie. `files/postgres-images.yaml` only ever
  holds one distribution, so this is a constraint on editing that file, not on a bump.

```bash
# 1. rehearse on a throwaway clone first, which reads the catalog and archives nothing
make restore-cnpg   # --mode side --source <cluster>, then patch its imageName to the new major by hand

# 2. real thing: merge the postgresVersion bump, then watch
kubectl -n <ns> get job -l cnpg.io/cluster=<cluster> -w      # <primary>-major-upgrade
kubectl -n <ns> get cluster <cluster> -o jsonpath='{.status.pgDataImageInfo}{"\n"}'   # majorVersion is the proof

# 3. extensions, if pg_upgrade wrote a script for them
kubectl -n <ns> exec <primary> -c postgres -- ls /var/lib/postgresql/data/pgdata/update_extensions.sql
kubectl -n <ns> exec -i <primary> -c postgres -- psql -U postgres -d app -f <that path>

# 4. statistics: pg_upgrade carries none over, so the first queries plan on nothing
kubectl -n <ns> exec <primary> -c postgres -- psql -U postgres -d app -c 'ANALYZE'

# 5. base backup into the NEW prefix, before the 1h grace on cnpg-no-recoverable-backup runs out
kubectl -n <ns> apply -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: {name: <cluster>-postupgrade, namespace: <ns>}
spec:
  cluster: {name: <cluster>}
  method: plugin
  pluginConfiguration: {name: barman-cloud.cloudnative-pg.io}
EOF
```

Rollback splits on whether it worked:

- Job still failing: put `postgresVersion` back. The operator deletes the job and starts on the old major again,
  the catalog follows it back to the old prefix, and the data was never modified.
- Already succeeded: `--link` left the old directory sharing inodes with the new one, so it is not safe to run
  again. Go back by restore instead, `restore.enabled: true` with `restore.serverName: <cluster>-pg<old major>`.

### Reclaim & durability

`longhorn-r2-ephemeral` is `reclaimPolicy: Delete`. Data safety does not rest on Retain: the DB unit is protected from a
GitOps prune by orphan-not-delete (`Prune=false,Delete=false` on the Cluster plus its ObjectStore,
ScheduledBackup, PodMonitor, NetworkPolicy and S3-creds SealedSecret). Removing a workload from git leaves its
`Cluster` and PVCs running, and restoring the files re-adopts them with no data movement.

Two durability tiers:

1. **In-cluster**: Postgres replication across the instances, Longhorn's 2 volume replicas under them, plus
   orphan-not-delete.
2. **Off-cluster**: S3 backups, continuous WAL archiving plus daily base backups via the
   `cnpg/plugin-barman-cloud` plugin, for real PITR and total-loss recovery. Turned on from `.env` by
   `10b_cnpg_backup.sh`. See [10_backups.md](10_backups.md).

Neither namespace needs privileged PSA: controller and Postgres pods run non-root (uid 26). Both apps use SSA,
because the CRDs and the `Cluster` CR blow the client-side annotation limit.

### Verify

```bash
helm dependency build argo_apps/platform/charts/02_cnpg_operator
export KUBECONFIG=secrets/kubeconfig
kubectl -n cnpg-system rollout status deploy/cnpg-operator-cloudnative-pg   # operator Healthy (platform)
kubectl -n sample-user-manager get pods -o wide                             # 3 instances Running, distinct nodes
kubectl -n sample-user-manager get pvc -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName  # longhorn-r2-*
kubectl -n sample-user-manager exec sample-user-manager-db-1 -- \
  psql -U postgres -tAc 'show synchronous_standby_names'                   # non-empty on the HA cluster
kubectl get vmpodscrape -A | grep -i cnpg                                   # metrics wired into VictoriaMetrics
```

Smoke test: delete the primary pod (`sample-user-manager-db-1`) and watch CNPG promote a standby, then heal
back to 3. The `app` role's credentials live in the auto-generated `sample-user-manager-db-app` Secret; connect
via the `sample-user-manager-db-rw` Service.
