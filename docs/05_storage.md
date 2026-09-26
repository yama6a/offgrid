# Storage and database

Procedures are in [runbooks/05_storage.md](runbooks/05_storage.md).

| Layer | Classes | Replicates at | Backs |
|---|---|---|---|
| [Longhorn](#longhorn) | `longhorn-r2-ephemeral`, `longhorn-r2-ephemeral-local`, `longhorn-r2-retained-with-backups` | the volume | everything: Postgres, RabbitMQ, Redis, the monitoring stores, ntfy |
| [External NFS](#external-nfs) | none, static PVs | nothing, the server does | storage that already exists off-cluster: a NAS share, a media library |
| [CloudNativePG](#cloudnativepg) | on Longhorn | Postgres streaming replication | every Postgres database |

There is no default StorageClass. A PVC that names no class stays `Pending` and never lands on Longhorn by accident.

## Why everything is on Longhorn, including the apps that replicate themselves

Postgres has streaming replication and RabbitMQ has Raft quorum queues. So replicating the block device under them
is redundant work. Node-local storage is still not used, and the reason is recovery, not performance.

A node-local PV is pinned to one machine. Replace or wipe that machine, and the PVC stays `Bound` to an empty
directory. No operator deletes a PVC that might hold the last copy of something, so the pod crashloops until a person
deletes the PVC by hand. Until someone notices:

- a 3-broker RabbitMQ runs at 2 of 3 with no spare. A second machine loss stops writes.
- a single-instance Postgres needs a full S3 restore, two git commits and a password roll.

On Longhorn the volume is not tied to the dead machine. The pod reattaches on a surviving node by itself. Measured
by unplugging one machine's ethernet:

| Setup | Both databases serving again after |
|---|---|
| Longhorn | ~190s, unattended |
| node-local storage | never |

The price is latency, and it is small. Both numbers are with a local replica:

| Metric | Node-local | Longhorn |
|---|---|---|
| Postgres commit p50 | 6.02 ms | 7.50 ms |
| RabbitMQ confirm p99 | 9.4 ms | 18.4 ms |

Both land inside what RDS Multi-AZ, Cloud SQL HA, SQS and Pub/Sub deliver. Details are in
[12_storage_bench.md](12_storage_bench.md) and [13_node_loss.md](13_node_loss.md).

## Longhorn

Longhorn is distributed block storage. It replicates each volume across nodes, on a dedicated data volume per node.
Chart: `argo_apps/platform/charts/02_longhorn/`.

- **V1 data engine, not V2 (SPDK)**: V2 has a known stuck-I/O bug on ARM64 with NVMe and 2 or more cores. The Pi 5
  matches all three. V1 is also lighter on low-power nodes.
- **2 replicas per volume**: survives the loss of one node and leaves a spare node to rebuild on.

### The three StorageClasses

| Class | reclaimPolicy | dataLocality | S3 backup | Use for |
|---|---|---|---|---|
| `longhorn-r2-ephemeral` | Delete | disabled | none | the general-purpose tier |
| `longhorn-r2-ephemeral-local` | Delete | best-effort | none | small volumes where write latency matters: RabbitMQ |
| `longhorn-r2-retained-with-backups` | Retain | disabled | daily and weekly | data with no app-level backup (sqlite, config). No consumer yet |

S3 backups are in [10_backups.md](10_backups.md).

`dataLocality: best-effort` keeps one replica on the node that runs the pod.

- It takes 31% off the RabbitMQ confirm p99, and only 4% off Postgres. A durable Postgres write reaches both
  replicas either way.
- The cost: Longhorn pulls a full local copy along on every reschedule.
- So it suits a queue that its consumers keep near-empty. A database that grows would cross 1GbE in full on every
  failover.

A weekly trim job returns freed blocks, so thin volumes stay thin. It replaces the `discard` mount option, which would
put reclaim inline in the write path of a consumer NVMe whose tail latency is already the weak point.

### Why there is no plain Retain class

- Every stateful app sets `deletionProtection` (`Prune=false,Delete=false`) on the CR or PVC that owns its storage.
- So a GitOps prune cannot delete the volume. Restoring the files re-adopts it with no data loss.
- `Retain` would then protect only against a deliberate delete, and leak orphaned PVs.
- Regretting a deliberate delete costs the backup RPO of that store.
- The one Retain class is for data with no app-level backup. It is also the restore target of
  `recover_longhorn_from_s3.sh`.

### RWX is a PVC choice, not a class

The PVC sets the access mode. `ReadWriteMany` against any class gets an RWX volume. A class that pinned RWX would force
NFS on single-writer volumes too.

RWX has a cost. Longhorn serves it through one nfs-ganesha share-manager pod per volume:

- **Single point of failure per volume**: `rwxVolumeFastFailover` shortens the outage but does not remove it.
- **Two network hops**: consumer to share-manager, then share-manager to replicas. Use RWX when sharing is the point.
- **No `-local` class**: `dataLocality` follows the share-manager pod, not the consumers, so it buys nothing.

## External NFS

For data that already lives on an NFS server and that the cluster does not own: a NAS share, a media library, an
archive that somebody else fills. Longhorn is for data the cluster creates.

`lib/helm/nfs-volume/` renders one static PV and its pre-bound PVC per export. A workload uses it as a `file://`
dependency. Mount options, capacity and reclaim behaviour are explained in its
[`values.yaml`](../lib/helm/nfs-volume/values.yaml).

### Why the in-tree plugin and not csi-driver-nfs

`csi-driver-nfs` adds dynamic provisioning, snapshots and class-level mount options. None of that applies here.

- Dynamic provisioning creates a fresh `pvc-<uuid>` directory per claim. The point here is to mount a directory that
  already exists.
- For static PVs the driver costs a DaemonSet and a controller for what the kubelet does for free.

The in-tree NFS plugin is frozen, not deprecated. Kubernetes plans no CSI migration for it. A later switch means
rewriting the PV and restarting the pods, and the data stays where it is.

### No monitoring

Nothing in the monitoring stack knows an NFS volume exists, so no alert fires when the server disappears. A blackbox
TCP probe on port 2049 of the server is the cheapest fix. `05_blackbox_exporter` takes any target.

## CloudNativePG

[CNPG](https://cloudnative-pg.io) turns a declarative `Cluster` CR into an HA Postgres: a primary and streaming
replicas, with failover, rolling updates and metrics.

| App | Tree | What |
|-----|------|------|
| `cnpg-operator` (`platform/charts/02_cnpg_operator`) | platform, wave 2 | the controller and its CRDs |
| each workload chart | workloads | its databases, through `lib/helm/pg-cluster` |

A workload declares `pg-cluster` as an aliased `file://` dependency, once per database. The chart renders the CNPG
CRs directly, with no upstream chart, and pins the Postgres image itself. Its knobs are in
[`values.yaml`](../lib/helm/pg-cluster/values.yaml).

### What a node loss costs

Databases use `longhorn-r2-ephemeral`, not the `-local` class. `-local` would buy 4% and move the whole database
across 1GbE on every failover.

Two layers of redundancy cover different failures:

| Layer | Covers |
|---|---|
| Postgres replication (`highAvailability: true`) | the primary dying. A caught-up standby is promoted. Measured: ~97s of write unavailability |
| Longhorn's 2 replicas | the node of the volume dying. The volume reattaches elsewhere with its data |

- **`highAvailability: true`**: 3 instances, one per node. One dies, a standby is promoted, writes continue.
- **`highAvailability: false`**: the single instance moves to a surviving node with its volume and replays WAL. No
  S3 restore.

### Design choices in `pg-cluster`

- **One bool, not three knobs**: 3 instances and synchronous replication always go together. 1 instance has no
  standby to be synchronous with. 2 instances, and more than 3, are out of scope.
- **Synchronous `any 1` with `dataDurability: required`**: a promoted standby never misses an acknowledged commit.
  With no standby to acknowledge, writes stall instead of going asynchronous. Cost: about 2 ms on commit p99.
- **Required anti-affinity by hostname**: a machine loss never takes two instances. With 3 machines and one down, the
  third instance waits Pending instead of doubling up.
- **Generated credentials**: the operator writes the `app` role into the `<name>-app` Secret, so no sealed secret is
  needed.
- **Postgres only**: no postgis image.

### Major version upgrade

A bump of `postgresVersion` is the whole change. The operator runs an offline in-place `pg_upgrade --link`, and the
chart moves the backup catalog to `<name>-pg<major>`, so the old catalog stays restorable.

The costs:

- **Downtime**: the whole database is down while `pg_upgrade` runs. On a large one, re-cloning the replicas is the
  slow part.
- **No PITR across the boundary**: the old catalog restores only to a point before the upgrade.
- **Extensions**: yours to check.
- **Same OS distribution only**: `files/postgres-images.yaml` holds one distribution.

### Reclaim and durability

The databases use a Delete class. Data safety rests on two tiers, not on Retain:

1. **In-cluster**: Postgres replication, the 2 Longhorn replicas under it, and `deletionProtection`, which leaves the
   `Cluster` and its PVCs running when a workload leaves git.
2. **Off-cluster**: continuous WAL archiving and daily base backups to S3, for PITR and total-loss recovery. See
   [10_backups.md](10_backups.md).
