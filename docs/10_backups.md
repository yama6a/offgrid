# Off-cluster backups to S3

This step backs up CNPG Postgres, Redis, Longhorn volumes, VictoriaMetrics and VictoriaLogs to one S3 bucket.
CNPG is CloudNativePG, the Postgres operator.

Without it, all durability is in the cluster:

- Postgres replicates across its instances.
- Longhorn keeps 2 replicas of every volume under them.
- A database whose manifests leave git keeps running, orphaned rather than deleted. See
  [05_storage.md](05_storage.md).

That survives the loss of one machine. It does not survive a bad `DROP`, data corruption, the loss of every
replica of a volume, or a full rebuild. The S3 tier covers those cases.

For Postgres, every CNPG cluster sends its WAL continuously and a base backup daily to S3. WAL is the write-ahead
log, the stream of every change Postgres makes. The Barman Cloud plugin does the upload. It is a CNPG-I plugin,
the CNPG interface for add-ons. The result is point-in-time recovery (PITR) over a window of about 180 days.

Terraform creates the bucket. It is the only Terraform in the repo. The bucket has one prefix per consumer, and all
consumers share the bucket and one IAM writer. Each prefix has its own lifecycle rule.

| Piece | Where | What |
|---|---|---|
| the bucket and IAM | `terraform/` | one S3 bucket, a lifecycle rule per prefix, encryption at rest, a public-access block, and a scoped IAM writer. The state is local and gitignored, because it holds the IAM secret |
| the plugin | `argo_apps/platform/{apps,charts}/03_barman_cloud_plugin` (wave 3) | the `ObjectStore` CRD, the Barman Cloud plugin Deployment, Service and RBAC, and its cert-manager mTLS certificates, in `cnpg-system`. Upstream ships no Helm chart, so the chart vendors the release manifest |
| backups per cluster | `lib/helm/pg-cluster` | every CNPG cluster gets WAL archiving, a daily `ScheduledBackup` and its own `ObjectStore`. The first-party chart renders all three. Static wiring is in the templates. Per-deployment values are in `files/backup.yaml` |
| wiring scripts | `lib/shell/10a_s3_backup_bucket.sh`, `10b_cnpg_backup.sh` | `10a` runs Terraform. `10b` writes the bucket, region, RPO and the sealed writer credentials into `files/backup.yaml` |
| recovery | `restore.enabled` in the chart, or `recover_cnpg_from_s3.sh` | two paths, each to the latest point or to a PITR timestamp. The chart knob rebuilds the cluster in place under its own name. The script starts an unmanaged side cluster to check or read from |

## WAL plus base backups

A physical Postgres backup has two parts, and both must work:

- **Continuous WAL archiving.** Postgres writes WAL in 16 MB segments. Each segment goes to S3 when it closes.
  This gives PITR and an RPO near zero. RPO is the recovery point objective, the most recent data a failure can
  lose. This part is easy to get wrong.
- **Base backups.** A periodic full copy of the data directory. Here, one per day, taken from a standby.

A base backup plus the WAL after it restores the database to any point after that backup.

A stalled archiver also puts the running database at risk. When WAL cannot ship, `pg_wal` fills the volume. The
primary then goes read-only or crashes. So the WAL-archive alert is `critical`.

## Decisions

- **The Barman Cloud plugin, not the in-tree integration.** CNPG deprecated the in-tree `barmanObjectStore` in
  favour of the CNPG-I plugin. So `pg-cluster` templates the plugin path directly: the `ObjectStore` CR, the
  WAL-archiver entry in the Cluster's `.spec.plugins[]`, and the `ScheduledBackup`.
- **arm64.** The CNPG operand images and the plugin sidecar image both ship multi-arch manifests with
  `linux/arm64`. So they run on the Pi 5 nodes.
- **RPO of 15 minutes.** `archiveTimeout` in `files/backup.yaml` comes from `CNPG_BACKUP_RPO` in `.env`.
  - It forces a WAL segment switch, and so an upload, at least every 15 minutes. A failed primary loses at most
    that much data.
  - It only matters when writes are low but not zero. A busy database fills segments and uploads them sooner. A
    database with no writes makes no WAL and uploads nothing, which is correct.
  - A lower RPO means more WAL objects, each smaller.
- **A daily base backup, from a standby.** The `ScheduledBackup` runs at 02:00. It sets no `target`, because the
  CNPG default is `prefer-standby`: the most up-to-date replica, or the primary if no replica is ready. This keeps
  the backup IO off the primary.
- **Storage class: Standard, then Glacier Instant Retrieval, then expiry.**
  - Barman sets no storage class, so objects land in S3 Standard.
  - The lifecycle moves them straight to Glacier Instant Retrieval (Glacier IR), not to Standard-IA. A lifecycle
    cannot move objects to Standard-IA before 30 days. Standard-IA also bills at least 128 KB per object and
    charges per GB read. Both penalise the many small WAL objects.
  - `S3_BACKUP_TRANSITION_DAYS` and `S3_BACKUP_RETENTION_DAYS` in `.env` set the ages.
  - Glacier bills at least 90 days of storage per object. At the defaults, an object stays 150 days in Glacier IR,
    so no early-delete fee applies.
- **Barman retention equals the S3 expiry.** The `ObjectStore` CRD needs a non-empty duration. The chart always
  writes the field, and an empty value renders as `null`, which the API rejects. So `retentionPolicy` equals the
  S3 expiry. At that age, Barman deletes whole backup sets with their WAL from its own catalog. The S3 expiry at
  the same age is the backstop. With both ages equal, neither one deletes an object the other still needs.
- **Encryption on the bucket, with AWS-managed keys.** Barman also asks for AES256 on upload, so the two agree.
  There are no KMS keys to manage.
- **A scoped IAM writer from Terraform. `.env` holds only the deployer credentials.**
  - Terraform creates an IAM writer scoped to the bucket and outputs its access key.
  - `10b_cnpg_backup.sh` reads that output and seals it into the cluster.
  - The deployer credentials that run Terraform have more power. They never enter the cluster.
  - Bare-metal Talos has no instance role, so the writer uses static keys. They are sealed, and never in `.env`
    or git.
- **One bucket, with a prefix per namespace and cluster.**
  - `destinationPath` is `s3://<bucket>/cnpg/<namespace>/`. Barman appends the cluster's `serverName`, which
    `pg-cluster` sets to `<clusterName>-pg<major>`.
  - So a database lands in `cnpg/<namespace>/<clusterName>-pg<major>/{wals,base}/`.
  - Cluster names only need to be unique per namespace, which `validate.yaml` enforces. The namespace in the path
    prevents collisions across namespaces.
- **The Postgres major is in the prefix, so a major upgrade leaves the old catalog alone.**
  - `pg_upgrade` resets the timeline to 1 and creates a new system ID. With a shared prefix, the new cluster
    would overwrite WAL segments the old base backups need. PITR also cannot cross a major version.
  - So a change to `postgresVersion` starts a new catalog by itself.
  - `restore.serverName` can still read the old catalog. The `cnpg/` lifecycle rule expires it like any other
    object.
  - The upgrade runbook is in [05_storage.md](05_storage.md).
- **The plugin has a network policy.** Its Deployment in `cnpg-system` has a pod-scoped `CiliumNetworkPolicy`:
  - Ingress on `:9090` for CNPG-I gRPC from the operator, plus the kubelet TCP probe.
  - Egress to DNS, the API server, and S3 on `world:443`. The plugin reads the backup catalog and the recovery
    window from S3.
  - The sidecar in each Postgres instance uploads to S3 itself, under the `pg-cluster` network policy. It talks
    to its instance manager over localhost and never calls this Service. So there is no rule from the instances
    to `:9090`, on purpose. See [01_networking.md](01_networking.md).

## Terraform

The state is local and gitignored. It holds the generated IAM secret key, and the repo is public.
`.terraform.lock.hcl` is committed, because it is a provider pin, not a secret. There is no `.tfvars` file. The
wrapper script passes every value as `TF_VAR_*` and the `AWS_*` provider variables, so no secret file lands on
disk.

```sh
make s3-backup-bucket     # 10a apply:   create or update the bucket, lifecycle and IAM writer (idempotent)
make s3-backup-wipe       # 10a wipe:    delete all backups, keep the bucket and IAM (a rebuild runs this)
make s3-backup-destroy    # 10a destroy: empty the bucket, then terraform destroy it and the IAM writer
```

The bucket sets `force_destroy = false`, so a bare `terraform destroy` refuses a bucket that holds objects. So
`destroy` empties the bucket first, after you type a confirmation. Nothing deletes backups by accident.

`main.tf` has one lifecycle rule per consumer prefix, because each needs a different retention:

- **`cnpg/`, `redis/` and `vm/`** move to Glacier IR, then expire. Each object stands alone: WAL and base sets,
  whole RDB dumps, whole daily exports. So expiry by age is safe, and S3 owns retention.
- **`longhorn/`** has no transition and no expiry, only a cleanup of aborted multipart uploads. Longhorn backups
  are incremental chains of deduplicated blocks. A newer backup uses blocks from older ones. Expiry by age would
  delete blocks still in use and corrupt restores. The `retain` count on Longhorn's RecurringJobs is the only
  thing that deletes. So Longhorn backups needed a Terraform change, and Redis and CNPG did not.

### The deployer IAM credentials

`AWS_DEPLOY_ACCESS_KEY_ID` and `AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET` in `.env` are a deployer identity. Only
Terraform and the wipe and destroy commands use it. It is never sealed into the cluster. It manages exactly one
bucket and one IAM user.

Create an IAM user, attach the policy below, and put its access key in `.env`. Replace the bucket name with your
`S3_BACKUP_BUCKET` and the account ID with your own. The writer user is named `<BUCKET>-writer`, to match
`terraform/main.tf`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageBackupBucket",
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::my-cluster-backups",
        "arn:aws:s3:::my-cluster-backups/*"
      ]
    },
    {
      "Sid": "ManageBackupWriterUser",
      "Effect": "Allow",
      "Action": [
        "iam:CreateUser",
        "iam:DeleteUser",
        "iam:GetUser",
        "iam:TagUser",
        "iam:UntagUser",
        "iam:ListUserTags",
        "iam:CreateAccessKey",
        "iam:DeleteAccessKey",
        "iam:ListAccessKeys",
        "iam:GetAccessKeyLastUsed",
        "iam:PutUserPolicy",
        "iam:DeleteUserPolicy",
        "iam:GetUserPolicy",
        "iam:ListUserPolicies",
        "iam:ListAttachedUserPolicies",
        "iam:ListGroupsForUser",
        "iam:RemoveUserFromGroup"
      ],
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:user/my-cluster-backups-writer"
    },
    {
      "Sid": "ProviderIdentity",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    }
  ]
}
```

- **`s3:*` covers only this one bucket.** On refresh, Terraform reads many bucket sub-resources. The broad action
  keeps one missing `s3:GetBucket*` or `s3:PutBucket*` from breaking that. Replace it with explicit actions if
  you prefer.
- **The IAM statement covers only the one writer user** that Terraform creates.
- **The two group actions are required**, although the user is in no group. To delete an IAM user, the AWS
  provider first removes it from its groups, so it always lists them. Without `iam:ListGroupsForUser`, `destroy`
  deletes 7 of the 8 resources and then fails on the user with `AccessDenied ... iam:ListGroupsForUser`. The user
  stays in Terraform state, and the next `apply` adopts it. But the teardown reports a failure.

The writer identity that Terraform creates, and that `10b` seals into the cluster, has much less power. It has
only `s3:ListBucket`, `GetObject`, `PutObject` and `DeleteObject` on the bucket. See `terraform/main.tf`.

## The plugin (`03_barman_cloud_plugin`, wave 3)

The plugin ships only manifests and Kustomize, with no Helm chart. So this wrapper vendors the pinned release
manifest word for word into `templates/`. The manifest has no Go-template braces, so Helm passes it through
unchanged. There is no dependency to pin, no `Chart.lock` and no `.tgz`. The version is the chart's `appVersion`
plus the image tag. To update it, follow that chart's `README.md`.

The plugin is on wave 3 and must live in `cnpg-system`. It needs two wave-2 apps:

- cert-manager, for its mTLS Issuer and Certificates.
- The CNPG operator, which discovers the plugin through its Service.

## Turning backups on

```sh
# .env: set the deployer credentials and the bucket. An empty AWS_DEPLOY_ACCESS_KEY_ID keeps backups off.
#   AWS_REGION, S3_BACKUP_BUCKET, AWS_DEPLOY_ACCESS_KEY_ID, AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET
make s3-backup-bucket        # 10a: Terraform. Bucket, lifecycle and IAM writer
make configure-cnpg-backup   # 10b: bucket, region and RPO into pg-cluster files/backup.yaml. Seals the writer once
git add -A && git commit && git push   # Argo CD applies the plugin, each ObjectStore and ScheduledBackup, the creds
```

`10b` edits only the shared `lib/helm/pg-cluster/files/backup.yaml`. It writes the values `bucket`, `region`,
`retentionPolicy` and `archiveTimeout`. It also seals the writer credentials once, with cluster-wide scope. The
static wiring is in the templates, not in this file: the plugin, the provider, the bucket path, WAL and data
compression, and the daily schedule.

`backupsEnabled` is true by default in `values.yaml`. So a filled-in `files/backup.yaml` is the opt-in:

- As soon as `10b` writes `bucket`, every CNPG cluster in every workload gets backups.
- Each instance creates its own `<name>-backup-s3` SealedSecret and credentials Secret from the one sealed value.
- A new Postgres workload needs nothing extra here.

The repo usually seals with `strict` scope. Here it uses cluster-wide scope, so one ciphertext unseals under any
name in any namespace. Each instance reuses the same ciphertext under its own secret name. So several databases
in one namespace never collide, and no instance has to own a shared secret. This is acceptable because every
CNPG workload uses the same S3 writer.

`DANGEROUS_bootstrap_cluster.sh` runs `10a` and `10b` when the deployer key is set. A failure there does not stop
the bootstrap. So a full bootstrap runs `terraform apply` and seals the credentials without a manual step.

A rebuild runs `10a wipe`. It deletes the old backups and keeps the bucket and IAM, so the new clusters start a
clean history. A rebuild does not re-seal, because the restored key already decrypts the committed secret. It
does not run `terraform destroy`. Only `make s3-backup-destroy` removes the bucket.

## Monitoring

Grafana-provisioned rules alert on backup health. They are the only alerts that fire, because `vmalert` and
Alertmanager are off. No chart `PrometheusRule` covers backups, to avoid inert copies. `lib/helm/pg-cluster`
emits no rules, so the upstream CNPG rules never enter the cluster.

The rules are in the Grafana `backups` group:

| Rule | Severity | Fires when |
|---|---|---|
| `cnpg-wal-archive-failing` | critical | `cnpg_collector_pg_wal_archive_status{value="ready"} > 0` for 15 minutes. WAL segments wait for upload |
| `cnpg-backup-too-old` | warning | the last good base backup is more than 36h old |
| `cnpg-no-recoverable-backup` | critical | a database has no recovery point in its catalog |
| `redis-backup-stale` | warning | more than 36h since the last good Redis backup Job |
| `redis-no-recoverable-backup` | critical | a Redis instance has no usable dump in S3 |
| `longhorn-backup-failed` | warning | a volume's backup is in the Error state |
| `longhorn-backup-stale` | warning | more than 48h since a volume's last backup |
| `vm-backup-stale` | warning | more than 36h since the last good VM/VL backup Job |

- **Act on `cnpg-wal-archive-failing` first.** A stalled archiver fills `pg_wal`, and a full `pg_wal` turns the
  primary read-only.
- **`cnpg-backup-too-old` reads `cnpg_backup_last_success_seconds`** from `05_orphan_exporter`. CNPG's own
  `cnpg_collector_last_available_backup_timestamp` stays at 0 under the plugin, so an alert on it could never
  fire.
- **The two recoverability rules** read `cnpg_backup_recoverable` and `redis_backup_recoverable`. They are the
  only rules that catch an empty catalog behind healthy backup jobs.
- **The Redis and VM/VL rules use the CronJob name** from kube-state-metrics. It does not export arbitrary pod or
  job labels, but it always exports the name. Raise the Redis threshold if you set a slower schedule.
- **A silently stopped Longhorn RecurringJob** leaves no Error state. `longhorn-backup-stale` is the only signal.
- **The stale rules add `> 0`** to the timestamp, so they stay quiet before the first backup.
- **A failed backup Job** fires `job-failed` in the `workload-anomalies` group. That rule covers every Job in the
  cluster, so no backup has its own failed-job rule. The Redis Job's stdout names the failed instance.

Check each metric and label name against the live cluster when you change a rule. A wrong name gives NoData, and
NoData reads as OK. It never gives a false alert, but it never gives a true one either.

## Redis RDB backups

Durable Redis instances back up to S3 as periodic RDB dumps. RDB is the Redis snapshot file format. They use the
same bucket, writer and lifecycle, under the `redis/` prefix.

One central platform app does this: `07_redis_backup`, on wave 7, in namespace `redis-backup`.

- A single CronJob finds every durable instance in the cluster by label.
- It dumps each one with `redis-cli --rdb` and uploads the dump.
- So there is one sealed secret in one namespace, and no list per namespace.
- The cost: one schedule for all instances, and alerts per Job, not per instance. The Job's stdout names the
  failed instance, and that output lands in VictoriaLogs.

[09_redis.md](09_redis.md), under "Off-cluster backups: RDB to S3", has the full mechanism, the
`make configure-redis-backup` runbook and `make restore-redis`. Barman manages CNPG retention. Redis relies only
on the S3 lifecycle for expiry.

## Longhorn volume backups

Selected Longhorn volumes back up under the `longhorn/` prefix. This is for workloads that keep state on a Longhorn
PVC and have no backup of their own: sqlite files, config directories, generic app data.

A workload opts in by its StorageClass. `02_longhorn` ships three classes:

| Class | Reclaim policy | Backed up to S3 |
|---|---|---|
| `longhorn-r2-retained-with-backups` | Retain | yes |
| `longhorn-r2-ephemeral` | Delete | no |
| `longhorn-r2-ephemeral-local` | Delete | no |

No workload uses the backed-up class yet.

The other stateful apps are on a class without Longhorn backups, on purpose. Each has a better logical path:

| Store | Covered by |
|---|---|
| CNPG Postgres | its own WAL and base backups to `cnpg/`. These give PITR and are consistent for the app |
| Redis (durable) | RDB dumps to `redis/` |
| VictoriaMetrics, VictoriaLogs | native exports to `vm/` |
| RabbitMQ | nothing, on purpose. The data is messages in flight, and the running quorum gives HA |
| ntfy | nothing yet. It is the first candidate for the backed-up class |

A logical dump is consistent for the app. For a large store that changes often, it also costs much less than a
block-level backup.

Longhorn uses its native backup, not a central CronJob like Redis:

- Redis is a network service. One central Job can dump each instance over the network.
- A Longhorn PVC is an RWO block device, attached to a single node, with no network read interface. The only way
  to read one for backup is Longhorn's own backup API.

So Longhorn uses its built-in backup target, `RecurringJob`s, and a `recurringJobSelector` on the StorageClass.
All of this lives in the existing `02_longhorn` app on wave 2. There is no separate backup app. Native backup is
incremental and deduplicated, which suits a home uplink. It is crash-consistent, and it works for any content
without per-app dump logic.

The classes always exist. The two backup `RecurringJob`s render only `{{- if backupTarget }}`. So no backup runs
until `10d_longhorn_backup.sh` sets the target. An empty value means off, as for CNPG and Redis. The
`filesystem-trim` job always renders, because it needs no S3 and every volume needs it.

The pieces, all under `argo_apps/platform/charts/02_longhorn/`:

- **`values.yaml` `defaultBackupStore`:** `backupTarget` (`s3://<bucket>@<region>/longhorn/`) and
  `backupTargetCredentialSecret`. The script fills both.
- **`templates/recurringjobs.yaml`:**
  - `backup-daily`: 03:00 UTC, keeps 7. In the `backup` group.
  - `backup-weekly`: Sunday 04:00 UTC, keeps 8, about 2 months. In the `backup` group.
  - No snapshot job, because local snapshots use scarce Pi NVMe space.
  - `filesystem-trim-weekly` is not a backup. It returns blocks the filesystem has freed to the SSD, which keeps
    a thin volume thin. It reaches every volume through Longhorn's `default` group. A volume with no recurring
    job of its own joins `default` automatically. A StorageClass's `parameters` cannot change, so a selector on a
    live class means deleting the class first.
- **`templates/storageclasses.yaml`:** the three classes. The `-with-backups` class has a `recurringJobSelector`
  for the `backup` group, so every volume it creates gets both backup jobs. That selector also keeps those
  volumes out of `default`. Add `trim` to it when the class gets its first volume.
- **`templates/backup-s3-sealedsecret.yaml`:** written by `10d`. It holds the sealed `longhorn-backup-s3` in
  `longhorn-system`, with the keys `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. Longhorn's S3 target expects
  those names.

Longhorn owns this retention, not S3. The `longhorn/` prefix has no lifecycle rule. Only the `retain` counts on
the RecurringJobs delete anything. Longhorn prunes old backups and the blocks they no longer use.

So this doc has three retention models:

| Consumer | Object shape | Who expires |
|---|---|---|
| CNPG | WAL and base sets | Barman, with an equal S3 expiry as backstop |
| Redis, VM/VL | dumps and daily exports that each stand alone | the S3 lifecycle |
| Longhorn | incremental, deduplicated chains | Longhorn's `retain`. S3 must not expire them |

A Longhorn backup is crash-consistent, like a power cut. That is fine for sqlite, whose journal survives power
loss. An app that needs a consistent backup should dump itself to a backed-up volume, as CNPG and Redis do.

### Turning Longhorn backups on

```sh
make s3-backup-bucket           # 10a: Terraform (idempotent). Sets the lifecycle rule per prefix
make configure-longhorn-backup  # 10d: backup target into 02_longhorn values, creds sealed into longhorn-system
git add -A && git commit && git push   # Argo CD applies backupTarget, the creds, the classes and RecurringJobs
# check:
kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.status.available}{"\n"}'  # true
kubectl -n longhorn-system get recurringjobs.longhorn.io      # backup-daily, backup-weekly, filesystem-trim-weekly
kubectl get storageclass | grep longhorn-                     # ephemeral, ephemeral-local, retained-with-backups
```

### Restore

`make restore-longhorn` restores a volume from S3. The CSI snapshotter sidecar is off in this cluster
(`csi.snapshotterReplicaCount: 0`). So the Kubernetes `VolumeSnapshot` restore path does not work.

The script uses Longhorn's native path instead:

1. It lists the `BackupVolume`s.
2. It picks a `Backup`, the latest or a named one. It reads the exact `fromBackup` URL from the backup's
   `.status.url`.
3. It creates a Longhorn `Volume` CR with `spec.fromBackup`, plus a static PV and PVC in the target namespace.

The script never touches the source backups or a live volume, and it refuses to overwrite. Afterwards, point
your workload at the restored PVC.

```sh
make restore-longhorn   # interactive: lists BackupVolumes, asks for the volume and the target namespace
# or without prompts:
bash lib/shell/recover_longhorn_from_s3.sh --volume pvc-xxxx --backup latest --target-ns myns --name myns-data-restore --apply
```

Recovery of the whole cluster:

1. Run `make restore-secrets-key` (step 03), so the committed `longhorn-backup-s3` decrypts.
2. Let the platform sync. Longhorn's `default` BackupTarget becomes `available`. Within the `pollInterval`, it
   finds the `BackupVolume`s in S3.
3. Run `make restore-longhorn` for each volume you want back.

Redis restores from its RDB dumps. The monitoring volumes restore from their VM/VL exports. Everything else on
Longhorn comes back empty. Every path here needs the sealed-secrets key, which lives outside the repo. Without
it, the S3 credentials cannot decrypt, and the backups are out of reach.

## VictoriaMetrics and VictoriaLogs backups

VictoriaMetrics and VictoriaLogs (VM/VL) back up under the `vm/` prefix. Both stores use `longhorn-r2-ephemeral`.
`deletionProtection` on their CRs covers an accidental prune. It does not cover the loss of both replicas, the
cluster or the site. A logical export closes that gap, and it is consistent for the app.

One central platform app does this: `08_vm_backup`, on wave 8, in namespace `monitoring`. A single daily CronJob
streams both stores to S3 and needs no PVC access.

It uses export and import, not `vmbackup`:

- `vmbackup` is open source, but it needs file access to the store's data directory. That is an RWO Longhorn PVC,
  already attached to the running pod. A separate Job cannot mount it too.
- The operator's `VMSingle` and `VLSingle` specs have no supported field for a general sidecar.
- The operator's automated `vmBackup` sidecar uses `vmbackupmanager`, which is Enterprise-only.
- So the Job uses the HTTP export and import API. VictoriaMetrics documents this free path for migration and
  backup. It needs no volume access, and it has the same central-CronJob shape as the Redis backup.

Each run at 01:00 UTC backs up only the previous full UTC day:

- **Metrics:** `GET /api/v1/export/native?match[]={__name__!=""}&start&end`, in one request. Gzipped to
  `s3://<bucket>/vm/metrics/<YYYYMMDD>.native.gz`.
- **Logs:** `GET /select/logsql/query?query=_time:[start,end)`, in 24 requests, one per UTC hour. Gzipped to
  `s3://<bucket>/vm/logs/<YYYYMMDD>T<HH>.jsonl.gz`.

The logs export runs per hour because of size:

- A day of logs is about 1.4 GB raw. An hour is about 60 MB.
- On an arm64 node, gzip is slower than vlsingle streams the data. A full day keeps the response open past
  vlsingle's `-search.maxQueryDuration`, the hard limit per query.
- At that limit, vlsingle closes the stream after it has already sent a 200. The S3 object then holds a
  truncated day.
- The `timeout=` URL argument does not raise that limit, although its name suggests it. Only the flag does.
  `05_victoria_logs` sets it to `5m` for headroom. One hour takes about 1 to 2 seconds.
- The keys are flat, not nested in a folder per day. So they still sort by time in one `aws s3 ls`, and the
  restore script depends on that.

The pieces, all under `argo_apps/platform/charts/08_vm_backup/`, plus a network-policy change on each store:

- **`values.yaml`:**
  - `bucket` and `region`, filled by `10e_vm_backup.sh`. Empty means the feature is off and nothing renders.
  - `prefix: vm/`.
  - `schedule` at 01:00 UTC, away from the jobs at 02:00 and 03:00.
  - The Service URLs of the two stores.
- **`templates/cronjob.yaml`:** one container, `alpine/k8s`, for curl, aws-cli and gzip. It streams each dump with
  `curl | gzip | aws s3 cp -` and uses no local disk. If an export or an upload fails, the Job deletes the partial
  object and fails, so the alert fires.
- **`templates/networkpolicy.yaml`:** allows egress only, to DNS, S3 and the two stores. The ingress allowlist of
  each store adds `app.kubernetes.io/name: vm-backup`, so this pod gets in.
- **`templates/vm-backup-s3-sealedsecret.yaml`:** written by `10e`. It holds the sealed `vm-backup-s3` in
  `monitoring`.

S3 owns this retention, the same model as Redis. Each daily slice stands alone, so expiry by age drops the oldest
days.

The Job exports one day at a time, not the whole store. A full export's peak memory grows with the data, and in
the end it runs the store out of memory. A one-day window keeps peak memory flat. The cost: a full recovery
replays every daily slice, not one file.

A failed run leaves a gap for that day. To fill it, run the Job again with `DAY` set. This works while the day
is still inside the store's retention:

```sh
kubectl -n monitoring create job --from=cronjob/vm-backup backfill-20260829 --dry-run=client -o json \
  | jq '.spec.template.spec.containers[0].env += [{"name":"DAY","value":"20260829"}]' \
  | kubectl apply -f -
kubectl -n monitoring logs job/backfill-20260829 -f
```

One limit remains. The VictoriaLogs JSONL round trip may not keep stream fields exactly, because the import
derives stream labels again.

### Turning VM/VL backups on

```sh
make s3-backup-bucket       # 10a: Terraform (idempotent). Adds the vm/ lifecycle rule
make configure-vm-backup    # 10e: bucket and region into 08_vm_backup values, creds sealed into monitoring
git add -A && git commit && git push   # Argo CD applies the app (wave 8) and the sealed creds
# check:
kubectl -n monitoring create job --from=cronjob/vm-backup vm-backup-manual
kubectl -n monitoring logs job/vm-backup-manual -f
aws s3 ls s3://$S3_BACKUP_BUCKET/vm/ --recursive     # 1x vm/metrics/<day>.native.gz, 24x vm/logs/<day>T<hh>.jsonl.gz
```

### Restore

`make restore-vm` streams a chosen export into the `/import` endpoint of the live store. It does this through a
temporary pod in `monitoring`:

- The pod reuses the sealed credentials and the `vm-backup` ingress allowlist.
- A break-glass egress network policy lets it reach S3 and the store.
- `/import` merges and deletes nothing. For a clean recovery, point it at a new or empty store.

```sh
make restore-vm   # interactive: asks for the kind (metrics|logs) and the target (all|latest|<s3-key>)
# or without prompts. `all` replays every daily slice (full recovery), `latest` only the newest day:
bash lib/shell/recover_vm_from_s3.sh --kind metrics --target all --apply
```

Recovery of the whole cluster:

1. Run `make restore-secrets-key` (step 03).
2. Let the platform sync. The stores come up empty.
3. Run `make restore-vm` for each kind to fill them.

The same key dependency applies as for every other backup here.

## Recovery paths

Durability has two layers. Only the second has a recovery step:

- **In the cluster, nothing to run.**
  - Synchronous streaming replication across the Postgres instances.
  - Longhorn's 2 volume replicas under each instance.
  - Orphan instead of delete. `Prune=false,Delete=false` is set on the whole database unit. When its manifests
    leave git, Argo CD does not delete the `Cluster`. It keeps running unmanaged, and restoring the files in git
    re-adopts it. `05_orphan_exporter` and the `orphan` alert group make that state visible.
- **Off the cluster, in S3.** Barman Cloud, with continuous WAL and a daily base backup. This is for real data
  loss: a dropped table, a bad migration, or the loss of every replica of a volume at once. The loss of a machine
  does not need it, because the volume reattaches on a surviving node ([13_node_loss.md](13_node_loss.md)).

Pick the path by what is wrong:

| Symptom | What to do |
|---|---|
| The database runs, but the app stays OutOfSync | Restore the workload's files in git and push. Argo CD re-adopts it. No data moves |
| The `Cluster` is gone and you want it back under its own name | `make restore-cnpg`, mode `in-place` |
| The database is fine. You want to check a backup, read old rows, or test a PITR target | `make restore-cnpg`, mode `side` |
| You rebuilt the whole cluster | `make restore-secrets-key` first, so the sealed S3 credentials decrypt. Then mode `in-place` per database |
| A machine died or was replaced | Nothing here, and nothing to delete. The volume reattaches on a surviving node and Postgres replays WAL. A promoted standby replaces an HA primary. See [13_node_loss.md](13_node_loss.md) |
| Every replica of one volume is gone (`faulted`) | `make restore-cnpg` for a database. `make restore-longhorn` for a volume on the backed-up class |

### `make restore-cnpg`

`lib/shell/recover_cnpg_from_s3.sh` is the runbook as a script. It asks for a mode, a namespace and a database
name. In both modes it then:

1. Lists every catalog it can see.
2. Checks the Secret with the S3 credentials.
3. Proves that a completed base backup exists. It checks the ObjectStore status, and it also lists S3 with the
   deployer credentials.

The last check matters most. WAL alone gives no recovery point. The S3 listing also catches a changed
`destinationPath` that left the old catalog behind at a different prefix.

**Mode `side`** applies one throwaway single-instance `Cluster` named `<db>-restore`. It reads the same catalog,
at the latest point or at a PITR timestamp. It does not archive WAL and is not a GitOps object. Connect to it at
`<name>-rw.<ns>`, and delete it when you are done. It refuses to overwrite an existing cluster.

**Mode `in-place`** drives the chart's `restore` and `deletionProtection` knobs. So it spans your commits, and it
is resumable: run it, push what it changed, and run it again. It prints its current phase each time.

1. **Enable.** It finds the workload chart and the alias that own the database. It sets
   `<alias>.restore.enabled: true`, and `targetTime` for PITR. It sets `deletionProtection` to false and prints
   the commit to make. If the live `Cluster` is healthy, it asks first, because the restore rewinds it to the
   catalog. If the `Cluster` is broken or absent, it just continues.
2. **Delete and wait.** It waits until the live `Cluster` has `cnpg.io/skipEmptyWalArchiveCheck`. That annotation
   proves Argo CD has synced the restore. It then deletes the `Cluster`, and Argo CD recreates it with
   `bootstrap.recovery`. The script watches the base-backup download, the WAL replay, the promotion and the
   replica join. The operator runs the recovery Job once and never retries it. So the script offers to delete a
   failed attempt. That is the normal way to resume after you fix the cause.
3. **Check and finish.** It prints `cnpg status`, every restored table with its live row count, the new timeline,
   and whether the restored database is backed up again. It offers to restart every workload that uses the new
   `<db>-app` Secret. It then removes `restore`, sets `deletionProtection: true`, and prints the final commit.

Between phases, you run the `git add`, `commit` and `push` it prints. No script here runs git.

Phase 2 must not delete a `Cluster` that the restore has already rebuilt. A re-run would wipe a good recovery. It
tells the two apart like this:

- While the `-full-recovery` bootstrap Job exists, the `Cluster` is the rebuilt one.
- After CNPG deletes that Job, a `Cluster` newer than the commit that enabled the restore is the rebuilt one.

Those two events can be under a minute apart. So `--yes` cannot delete a `Cluster` that serves traffic. The
script always asks for that one, whatever the timestamps say. A broken `Cluster` is not ambiguous, so `--yes`
still works for it.

When the script fails, these three facts help:

- **A restore always starts a new timeline** and writes WAL into the same prefix. The plugin's pre-flight
  `barman-cloud-check-wal-archive` would then stop with `Expected empty archive`. So the chart sets
  `cnpg.io/skipEmptyWalArchiveCheck: enabled` when it recovers from its own catalog. It does not set it when
  `restore.serverName` names a different source, because there the check protects you.
- **Deleting a `Cluster` also deletes its `<db>-app` Secret**, so CNPG generates a new password. The chart's
  recovery block sets `database: app` and `owner: app`, so CNPG updates the role. The apps that use it still need
  a restart.
- **Turning `restore` off again changes nothing** in the running cluster, because CNPG reads `spec.bootstrap`
  only once. If you left it on, a future re-create would restore from the catalog instead of running `initdb`.

### Deleting a database on purpose

Use two commits, never `kubectl delete`:

1. Set `deletionProtection: false` for that instance and push. This removes the sync options that protect it.
2. Remove its values block and its `Chart.yaml` alias, and push. The prune now deletes everything, PVCs included.

Never leave a database on `deletionProtection: false`.

### Rebuild vs reset, and why a rebuild wipes the backups

A rebuild is a deliberate fresh start of the platform. It empties the S3 bucket with `10a wipe`, and keeps the
bucket and IAM. It does not touch the nodes. To wipe the Longhorn volumes, reset the machines with your node
tooling's `make reset-cluster` before the rebuild. A rebuild on nodes that were not reset delivers the platform
onto the existing volumes.

The rebuild must wipe the backups. The rebuilt clusters have the same names, so they would reuse the old backup
path. Barman refuses to mix a new Postgres system ID into a server's existing data. `cnpg-wal-archive-failing`
would then fire forever. An empty bucket lets the new clusters start a clean history.

So a rebuild deletes your backups. If you want the old data, restore it before you rebuild, or do not rebuild.
To recover specific data without a rebuild, run `make restore-cnpg` against the live bucket.

### Recreating one cluster

This has the same problem as a rebuild. Say you delete and recreate one `Cluster` under the same name, for
example to change its storage class, which cannot change in place. The new `initdb` creates a new system ID. The
catalog still holds the old one, and Barman refuses:

```
WAL archive check failed for server <name>: Expected empty archive
```

`ContinuousArchiving` becomes `False` and stays there. The database serves normally and nothing else looks wrong,
so check that condition after every recreate.

`restore.enabled` does not fix this. A permanent `cnpg.io/skipEmptyWalArchiveCheck` does not fix it either. It
only turns off the guard against two system IDs in one catalog.

Empty that one server's prefix, not the whole bucket:

```bash
aws s3 rm --recursive "s3://<bucket>/cnpg/<namespace>/<cluster>-pg<major>/"
kubectl -n <ns> delete backups.postgresql.cnpg.io --all   # they point at objects that are now gone
kubectl -n <ns> exec <primary> -c postgres -- psql -U postgres -tAc 'select pg_switch_wal()'
```

Archiving recovers within a minute. Then take a base backup at once with a `Backup` CR that sets
`method: plugin`. Do not wait for the 02:00 schedule: until a base backup completes, there is no restore point.

A base backup is not restorable at the moment it reports `completed`. Recovery needs the WAL segment that holds
the backup-end record. That segment reaches S3 only after `archive_timeout` (15 minutes) or when it fills. A
restore before then fails with `WAL ends before end of online backup`, and retries until the segment lands. To
restore at once, force the switch:

```bash
kubectl -n <ns> exec <primary> -c postgres -- psql -U postgres -tAc 'select pg_switch_wal()'
```

To remove the bucket, run `make s3-backup-destroy` on its own. It empties the bucket, then runs `terraform
destroy` on the bucket and the IAM writer. Nothing runs it for you. Wiping the nodes does not touch S3. It wipes
only node state.

## Check end to end

1. **Bucket.** `aws s3api get-bucket-lifecycle-configuration --bucket <bucket>` shows one rule per prefix.
   Encryption is on, public access is blocked, and the IAM writer is scoped to the bucket. A second
   `make s3-backup-bucket` changes nothing.
2. **Plugin synced.** The platform is Healthy, `kubectl get crd objectstores.barmancloud.cnpg.io` finds the CRD,
   and the `barman-cloud` Deployment in `cnpg-system` is Ready.
3. **WAL archiving live.** This check matters most.
   - The Cluster's `ContinuousArchiving` condition is `True`.
   - Objects appear under `s3://<bucket>/cnpg/<ns>/<cluster>-pg<major>/wals/`.
   - The daily base backup runs on a standby pod.
   - Read the recovery point from the ObjectStore, not the Cluster. Under the plugin,
     `Cluster.status.firstRecoverabilityPoint` stays empty, even with a completed base backup in S3.
   - `05_orphan_exporter` reads the ObjectStore. It publishes `cnpg_backup_recoverable`,
     `cnpg_backup_last_success_seconds` and `cnpg_backup_first_recoverability_seconds`.
   - `cnpg-backup-too-old` alerts on `cnpg_backup_last_success_seconds`. CNPG's own
     `cnpg_collector_last_available_backup_timestamp` stays at 0 here, so an alert on it could never fire.
   - The Backups panels on the `cnpg` dashboard use the same two metrics. See
     [06_monitoring.md](06_monitoring.md).
   - Under the plugin, there are no `backups.postgresql.cnpg.io` objects to list. A runbook step that lists
     them always comes back empty.

   ```bash
   kubectl -n <ns> get objectstores.barmancloud.cnpg.io -o \
     jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.serverRecoveryWindow}{"\n"}{end}'
   ```
4. **RPO.** `SELECT pg_switch_wal();` on the primary creates a new object under `wals/` within seconds.
   `SHOW archive_timeout;` returns `15min`.
5. **Restore drill.**
   - Run `make restore-cnpg`, mode `side`, target `latest`. The side cluster becomes Healthy from S3 and serves
     data. Delete it afterwards.
   - Repeat with a PITR `targetTime`.
   - For a full drill, delete the database and bring it back with the same script in mode `in-place`.
   - Check that `cnpg_backup_recoverable` reads 1 per database. It is the only signal that catches an empty
     catalog behind healthy WAL archiving.
6. **Alerts.** Check the metric name and label against `/metrics`. Then break archiving so
   `cnpg-wal-archive-failing` fires, for example by revoking the IAM key for a short time. Undo the change and
   check that the alert clears.

Always write `backups.postgresql.cnpg.io` in full when you list them. Longhorn also has a `Backup` kind, and it
takes the short name. So a bare `kubectl get backup` reports `not found` for a CNPG backup that exists.

## Why we render the ObjectStore ourselves

The upstream `cnpg/cluster` chart marks the `ObjectStore` as a Helm `pre-install,pre-upgrade,pre-rollback` hook.
Argo CD turns that into a PreSync hook, which it does not track as a resource. Argo CD creates the hook once and
can delete it later without creating it again. Then:

- WAL archiving stops.
- The CNPG cluster stays `Ready=False` with `ContinuousArchivingFailing: ObjectStore ... not found`.
- The sync of the whole workload blocks behind the unready cluster.

On one rebuild, S3 got 3 objects and then nothing for about an hour. The failure does not heal by itself.

So `pg-cluster` renders the CNPG CRs itself, and does not wrap the upstream chart. Its
`templates/objectstore.yaml` gives the `ObjectStore` the annotation `argocd.argoproj.io/sync-wave: "-1"`. The
`ObjectStore` is a normal, tracked resource, applied just before the Cluster. No Helm hook is involved.

Wrapping the upstream chart would also mean a hand-patched `charts/cluster-*.tgz` in git. Renovate's
`helmUpdateSubChartArchives` re-vendors that archive unpatched on every upstream bump. Rendering the CR directly
leaves no archive to patch.

The upstream issue is <https://github.com/cloudnative-pg/charts/issues/964>. It proposes a
`backups.objectStore.helmHook` opt-out and an annotations knob for the ObjectStore only. If it lands,
`pg-cluster` could wrap the official chart again, with `helmHook: false` and the sync-wave annotation. That also
needs an acceptable answer to how a dependency behind `file://` gets vendored. Until then, keep rendering
directly.
