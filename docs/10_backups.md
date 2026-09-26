# Off-cluster backups to S3

The cluster backs up CNPG Postgres, Redis, Longhorn volumes, VictoriaMetrics and VictoriaLogs to one S3 bucket.
CNPG is CloudNativePG, the Postgres operator. Procedures are in the [backups runbook](runbooks/10_backups.md).

In-cluster durability survives the loss of one machine:

- Postgres replicates across its instances.
- Longhorn keeps 2 replicas of every volume.
- A database whose manifests leave git keeps running, orphaned and not deleted. See [05_storage.md](05_storage.md).

It does not survive a bad `DROP`, data corruption, the loss of every replica of a volume, or a full rebuild. The
S3 tier covers those cases.

| Piece | Where | What |
|---|---|---|
| bucket and IAM | `terraform/` | one bucket, a lifecycle rule per prefix, encryption at rest, and a scoped IAM writer. The only Terraform in the repo |
| plugin | `03_barman_cloud_plugin` (wave 3) | the Barman Cloud plugin that uploads Postgres WAL and base backups. Vendored release manifest, see that chart's README |
| Postgres backups | `lib/helm/pg-cluster` | every CNPG cluster gets WAL archiving, a daily `ScheduledBackup` and its own `ObjectStore` |
| Redis backups | `07_redis_backup` | one CronJob that dumps every durable instance. See [09_redis.md](09_redis.md) |
| volume backups | `02_longhorn` | Longhorn's native backup for volumes on the backed-up StorageClass |
| metrics and logs | `08_vm_backup` | one CronJob that exports yesterday from each store |
| wiring | `lib/shell/10a` to `10e` | `10a` runs Terraform. `10b` to `10e` write each consumer's values and seal the writer credentials |

## Postgres: WAL plus a daily base backup

Every CNPG cluster ships its WAL to S3 continuously and takes a base backup daily. WAL is the write-ahead log, the
stream of every change Postgres makes. A base backup plus the WAL after it restores to any point after that
backup. This is point-in-time recovery (PITR), over a window of about 180 days.

- **The Barman Cloud plugin, not the in-tree integration.** CNPG deprecated the in-tree `barmanObjectStore` in
  favour of the plugin. CNPG-I is the CNPG interface for add-ons.
- **RPO of 15 minutes.** RPO is the recovery point objective, the most recent data a failure can lose.
  `CNPG_BACKUP_RPO` in `.env` sets `archiveTimeout`, which forces an upload at least that often. It matters only
  under low write load. A busy database fills 16 MB segments sooner, and an idle one has nothing to lose. A lower
  RPO means more, smaller WAL objects.
- **A stalled archiver is critical, not a backup problem.** Unshipped WAL fills `pg_wal`, and a full `pg_wal`
  makes the primary read-only. So `cnpg-wal-archive-failing` pages.
- **The daily base backup runs on a standby.** The `ScheduledBackup` sets no `target`, so CNPG's default
  `prefer-standby` applies. The backup IO stays off the primary.
- **One prefix per namespace, cluster and major:** `cnpg/<namespace>/<cluster>-pg<major>/`. The namespace
  prevents collisions between clusters of the same name. The major is there because `pg_upgrade` starts a new
  system ID and timeline, which would overwrite WAL the old base backups need. A major upgrade therefore starts a
  new catalog by itself, and `restore.serverName` can still read the old one.
- **Barman retention equals the S3 expiry.** The `ObjectStore` needs a non-empty retention. With both ages equal,
  neither deletes an object the other still needs. Barman deletes whole backup sets, and S3 expiry is the backstop.
- **pg-cluster renders the `ObjectStore` itself.** See [below](#why-pg-cluster-renders-the-objectstore).

## Shared bucket and credentials

- **One bucket, one prefix per consumer:** `cnpg/`, `redis/`, `longhorn/`, `vm/`. Each prefix gets its own
  lifecycle rule, because the consumers need different retention.
- **Standard, then Glacier Instant Retrieval, then expiry.** Glacier IR, not Standard-IA, because IA bills at
  least 128 KB per object and charges per GB read. Both penalise many small WAL objects. At the defaults an
  object stays 150 days in Glacier IR, past its 90-day minimum, so no early-delete fee applies.
- **Encryption with AWS-managed keys.** There are no KMS keys to manage.
- **Two IAM identities.** The deployer credentials in `.env` run Terraform and never enter the cluster.
  Terraform creates a writer with only list, get, put and delete on the bucket. The `10*` scripts seal that
  writer's key into the cluster. Bare-metal nodes have no instance role, so the writer uses static keys.
- **Terraform state is local and gitignored.** It holds the writer's secret key, and the repo is public. The
  wrapper passes every value as an environment variable, so no secret file lands on disk.
- **The CNPG credentials are sealed cluster-wide.** The repo usually seals with `strict` scope. Here one
  ciphertext unseals under any name in any namespace, so every database gets its own Secret with no shared owner.
  This is acceptable because every database uses the same writer.
- **A filled-in backup overlay is the opt-in.** Once `10b` writes `bucket` into `pg-cluster/files/backup.yaml`,
  every CNPG cluster in every workload backs up. A new Postgres workload needs nothing extra.

Three retention models share the bucket:

| Consumer | Object shape | Who expires |
|---|---|---|
| CNPG | WAL and base backup sets | Barman, with an equal S3 expiry as backstop |
| Redis, VictoriaMetrics, VictoriaLogs | dumps and daily exports that each stand alone | the S3 lifecycle |
| Longhorn | incremental, deduplicated block chains | Longhorn's RecurringJob `retain`. S3 must never expire them |

## Redis

One central CronJob, `07_redis_backup`, finds every durable instance by label and uploads an RDB dump of each.
RDB is the Redis snapshot format. One sealed secret in one namespace replaces a secret per workload. The cost is
one schedule for all instances, and alerts per Job, not per instance. Details are in [09_redis.md](09_redis.md).

## Longhorn volumes

This is for workloads that keep state on a Longhorn PVC and have no backup of their own: sqlite files, config
directories. A workload opts in by its StorageClass. Only `longhorn-r2-retained-with-backups` backs up. No
workload uses it yet.

The other stateful apps use a class without backups, on purpose:

| Store | Covered by |
|---|---|
| CNPG Postgres | its own WAL and base backups. Consistent for the app, and PITR |
| Redis (durable) | RDB dumps |
| VictoriaMetrics, VictoriaLogs | daily exports |
| RabbitMQ | nothing. The data is messages in flight, and the quorum gives HA |
| ntfy | nothing yet. It is the first candidate for the backed-up class |

A logical dump is consistent for the app, and for a large, busy store it costs much less than a block backup.

- **Native Longhorn backup, not a central CronJob.** A Longhorn PVC is an RWO block device on one node, with no
  network read interface. Only Longhorn's own backup can read it. It is incremental and deduplicated, which suits
  a home uplink, and it needs no per-app dump logic.
- **Crash-consistent, like a power cut.** That is fine for sqlite, whose journal survives power loss. An app that
  needs a consistent backup should dump itself to a backed-up volume.
- **The CSI snapshotter is off**, so a restore uses Longhorn's `Volume.spec.fromBackup` and not a Kubernetes
  `VolumeSnapshot`.

## VictoriaMetrics and VictoriaLogs

`deletionProtection` on the store CRs covers an accidental prune. It does not cover the loss of both replicas,
the cluster or the site. A daily logical export to `vm/` closes that gap.

- **HTTP export and import, not `vmbackup`.** `vmbackup` needs file access to the store's RWO volume, which the
  running pod already holds. The operator has no general sidecar field, and its `vmbackupmanager` is
  Enterprise-only. Export and import is the documented free path, and it needs no volume access.
- **One UTC day per run, not the whole store.** A full export's peak memory grows with the data until it runs the
  store out of memory. A one-day window keeps it flat. The cost: a full recovery replays every daily slice.
- **Known limit.** The VictoriaLogs JSONL round trip may not keep stream fields exactly, because the import derives
  stream labels again.

## Monitoring

Grafana rules in the `backups` group alert on backup health. `pg-cluster` emits no `PrometheusRule`.

- **Recoverability, not only job success.** `cnpg_backup_recoverable` and `redis_backup_recoverable` catch an empty
  catalog behind healthy jobs, for example after a `destinationPath` change. `05_orphan_exporter` publishes both.
- **CNPG's own backup timestamp is useless here.** It stays at 0 under the plugin, so `cnpg-backup-too-old` reads
  the exporter's `cnpg_backup_last_success_seconds` instead.
- **A silently stopped Longhorn RecurringJob** leaves no Error state. `longhorn-backup-stale` is the only signal.
- **A failed backup Job** fires the cluster-wide `job-failed` rule. No backup has its own failed-job rule.

A wrong metric or label name gives NoData, which reads as OK. Check names against the live cluster when you change
a rule.

## Recovery model

- **In the cluster, nothing to run.** Postgres replication, Longhorn replicas, and orphan-instead-of-delete. A
  lost machine needs no restore, because the volume reattaches on a survivor. See
  [13_node_loss.md](13_node_loss.md).
- **From S3, for real data loss.** A dropped table, a bad migration, or every replica of a volume gone.
- **Restores are GitOps.** `make restore-cnpg` in-place mode drives the chart's `restore` and
  `deletionProtection` knobs, and you commit between its phases. No script runs git. So the recovered state is
  what git says, and Argo CD does not fight it.
- **Every restore needs the sealed-secrets key**, which lives outside the repo. Without it the S3 credentials do
  not decrypt, and the backups are out of reach.

### A rebuild wipes the backups

A rebuild is a deliberate fresh start of the platform. It empties the bucket and keeps the bucket and IAM. The
rebuilt clusters have the same names, so they would reuse the old paths. Barman refuses to mix a new Postgres
system ID into an existing catalog, and `cnpg-wal-archive-failing` would fire forever. An empty bucket gives the
new clusters a clean history.

So restore the data you want before you rebuild. To recover data without a rebuild, restore against the live
bucket. Recreating one cluster under the same name hits the same check, and the runbook has the fix.

## Why pg-cluster renders the ObjectStore

The upstream `cnpg/cluster` chart makes the `ObjectStore` a Helm `pre-install,pre-upgrade` hook. Argo CD turns
that into a PreSync hook, which it does not track. It can delete the hook and never create it again. WAL
archiving then stops, the cluster stays `Ready=False`, and the whole workload's sync blocks. It does not heal.

So `pg-cluster` renders the CNPG resources itself. The `ObjectStore` is a normal tracked resource on sync wave
-1, applied just before the Cluster. Wrapping the upstream chart would also need a hand-patched `.tgz` in git,
which Renovate re-vendors unpatched on every bump.

Upstream issue <https://github.com/cloudnative-pg/charts/issues/964> proposes a `helmHook` opt-out. If it lands,
`pg-cluster` could wrap the official chart again.
