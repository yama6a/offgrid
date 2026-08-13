# Off-cluster backups, CNPG Postgres + Redis + Longhorn + VM/VL to S3

Until now durability was entirely in-cluster: Postgres replication across the instances, Longhorn's 2 volume
replicas under them, plus orphan-not-delete ([05_storage.md](05_storage.md)). That survives a machine loss
unaided, but not a bad `DROP`, data corruption, losing every replica of a volume, or a full rebuild.

This step adds the off-cluster tier: continuous WAL archiving plus daily base backups from every CloudNativePG
cluster to S3, via the Barman Cloud CNPG-I plugin, giving point-in-time recovery and a roughly 180-day window.

The bucket is created by Terraform, the repo's only Terraform, and is deliberately general-purpose. Four consumers,
one prefix each, all sharing the same bucket and IAM writer. The lifecycle is PER-PREFIX, not bucket-wide.

| Piece | Where | What |
|---|---|---|
| the bucket + IAM | `terraform/` | one S3 bucket, a per-prefix lifecycle, encryption at rest, public-access block, and a scoped IAM writer. Local state, gitignored, since it holds the IAM secret |
| the plugin | `argo_apps/platform/{apps,charts}/03_barman_cloud_plugin` (wave 3) | the `ObjectStore` CRD plus the Barman Cloud plugin Deployment, Service, RBAC and its cert-manager mTLS certs, in `cnpg-system`. A vendored release manifest, since there is no upstream Helm chart |
| per-cluster backups | `lib/helm/pg-cluster` | every CNPG cluster inherits WAL archiving, a daily `ScheduledBackup` and its own `ObjectStore`, all rendered by the first-party chart. Static wiring hardcoded in the templates; per-deployment facts in `files/backup.yaml` |
| wiring scripts | `lib/shell/10a_s3_backup_bucket.sh`, `10b_cnpg_backup.sh` | 13 runs Terraform; 14 writes bucket, region and RPO plus the cluster-wide sealed writer creds into `files/backup.yaml` |
| recovery | `restore.enabled` in the chart, or `recover_cnpg_from_s3.sh` | two paths, latest or PITR. The chart knob rebuilds the cluster IN PLACE under its own name; the script bootstraps an unmanaged side cluster to verify or read from |

## The mental model: WAL plus base, not a snapshot

A physical Postgres backup is two things that must BOTH work:

- Continuous WAL archiving: every 16 MB WAL segment shipped to S3 as it closes. This is what gives point-in-time
  recovery and a near-zero RPO, and it is the part that is easy to under-think.
- Base backups: periodic full copies of the data dir. Here, daily, taken from a standby.

Base backup plus the WAL since it equals a restore to any point in between.

A stalled archiver is a LIVENESS risk, not just a recovery gap: if WAL cannot ship, `pg_wal` fills the volume and
the primary goes read-only or crashes. That is why the WAL-archive alert is `critical`.

## Decisions

- The Barman Cloud PLUGIN, not the in-tree integration. CNPG deprecated the in-tree `barmanObjectStore` in favour
  of the CNPG-I plugin, so `pg-cluster` templates the plugin path directly: the `ObjectStore` CR, the Cluster's
  `.spec.plugins[]` WAL-archiver entry, and the `ScheduledBackup`.
- arm64. Both the CNPG operand images and the plugin sidecar image ship multi-arch manifests including
  `linux/arm64`, so they run on the Pi 5s. The usual Pi gate.
- RPO 15 min. `archiveTimeout` in `files/backup.yaml`, from `.env`'s `CNPG_BACKUP_RPO`, forces a WAL segment switch
  and therefore an archive at most every 15 min, so a primary failure loses at most that much. It only BINDS in the
  low-but-nonzero write regime: a busy DB fills segments and archives faster, and a DB with no writes at all
  produces no WAL and archives nothing, correctly. Lowering the RPO means more, smaller WAL objects.
- Daily base backup, from a standby. `ScheduledBackup` at 02:00. No `target` is set because CNPG's default is
  already `prefer-standby`, running on the most up-to-date replica and falling back to the primary. Exactly what we
  want, so the base-backup IO stays off the primary.
- Storage class: land in Standard, transition to Glacier Instant Retrieval, then expire. Objects are written as S3
  Standard, since Barman sets no storage class. We deliberately do NOT use Standard-IA: a lifecycle cannot
  transition to IA before 30d anyway, and IA's 128 KB minimum billable size plus per-GB retrieval fees punish the
  churny, often tiny WAL objects. Straight to Glacier IR instead. The ages are `.env`-configurable via
  `S3_BACKUP_TRANSITION_DAYS` and `S3_BACKUP_RETENTION_DAYS`. Note the interplay with Glacier's 90-day minimum
  storage duration: at the defaults, objects spend 150d in Glacier IR, well past the minimum, so no early-delete
  penalty.
- Retention: Barman's window aligned to the S3 lifecycle. The `ObjectStore` CRD requires a non-empty duration and
  the chart always emits the field, so leaving it unset is not possible; an empty value renders as `null` and the
  API rejects it. So `retentionPolicy` is set EQUAL to the S3 expiry. Barman prunes its own catalog coherently at
  that age, whole backup sets plus their WAL, and the S3 lifecycle expiry at the same age is the backstop. Keeping
  the two equal avoids the failure mode where one deletes objects the other still references.
- Encryption: bucket-side with AWS-managed keys, and Barman also requests AES256 on upload, so the two agree. No
  KMS keys to manage.
- Credentials: Terraform makes a scoped IAM user, and `.env` holds only the deployer creds. Terraform provisions a
  dedicated bucket-scoped IAM writer and exposes its access key as an output; `10b_cnpg_backup.sh` reads that output
  and seals it into the cluster. The powerful deployer creds that run Terraform never enter the cluster. On
  bare-metal Talos there is no instance role, so it is static keys, sealed and never in `.env` or git.
- One bucket, namespace plus cluster prefix. `destinationPath: s3://<bucket>/cnpg/<namespace>/`, and Barman appends
  each cluster's `serverName`, so clusters land in their own `cnpg/<namespace>/<clusterName>/{wals,base}/`. The
  namespace in the path makes it collision-proof on per-namespace name uniqueness alone, which `validate.yaml`
  enforces, so there is no global-uniqueness requirement.
- The plugin is network-policed. Its Deployment in `cnpg-system` carries a pod-scoped `CiliumNetworkPolicy`:
  ingress on `:9090` for the CNPG-I gRPC from the operator, plus the kubelet TCP probe; egress to DNS, the API
  server, and S3 on `world:443` for backup-catalog and recovery-window reads. The instance SIDECAR does its own S3
  upload, allowed by the `pg-cluster` netpol, and talks to its instance-manager over localhost, so it does NOT dial
  this central Service and there is deliberately no instance-to-`:9090` rule. See
  [01_networking.md](01_networking.md).

## Terraform

State is local and gitignored, because it holds the generated IAM secret key and the repo is public.
`.terraform.lock.hcl` IS committed, being a provider pin rather than a secret. No `.tfvars`: the wrapper script
passes everything via `TF_VAR_*` plus the `AWS_*` provider env, so no secret file lands on disk.

```sh
make s3-backup-bucket     # 13 apply  : create/update the bucket + lifecycle + IAM writer (idempotent)
make s3-backup-wipe       # 13 wipe   : delete ALL backups, KEEP the bucket + IAM (what a rebuild does)
make s3-backup-destroy    # 13 destroy: empty the bucket THEN terraform-destroy it + the IAM writer
```

The bucket is `force_destroy = false`, so a bare `terraform destroy` refuses a non-empty bucket. That is why
`destroy` empties it first, as an explicit typed-confirmed act, and nothing deletes backups by accident.

Per-prefix lifecycle, not bucket-wide. `main.tf` has one rule per consumer prefix because they need different
retention:

- `cnpg/`, `redis/` and `vm/` tier to Glacier IR then expire. Their objects are self-contained (WAL and base sets,
  whole RDB dumps, whole daily exports), so age-expiry is safe and S3 owns retention.
- `longhorn/` gets NO transition and NO expiration, only an aborted-multipart cleanup. Longhorn backups are
  incremental, deduplicated block chains, so a newer backup references older blocks and an age-based expiry would
  delete still-referenced blocks and corrupt restores. Longhorn's own RecurringJob `retain` is the sole deleter.
  This is why enabling Longhorn backups needed a Terraform change, where redis and CNPG did not.

### The deployer IAM credentials

`.env`'s `AWS_DEPLOY_ACCESS_KEY_ID` and `AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET` are a DEPLOYER identity used only by
Terraform and the wipe/destroy CLI. Never sealed into the cluster. It needs to manage exactly one bucket and one
IAM user.

Create an IAM user, attach the policy below, and put its access key in `.env`. Replace the bucket name with your
`S3_BACKUP_BUCKET` and the account id with your own; the writer user is named `<BUCKET>-writer` to match
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

`s3:*` is scoped to the single bucket rather than account-wide. The broad verb keeps Terraform's many bucket
sub-resource reads on refresh from tripping over one missing `s3:GetBucket*` or `s3:PutBucket*`; tighten to explicit
actions if you prefer. The IAM statement is scoped to the one writer user Terraform creates.

The two group actions look wrong for a user that is in no group, and they are not optional: deleting an IAM user
makes the AWS provider clear group memberships first, so it lists them whether there are any or not. Without
`iam:ListGroupsForUser` a `destroy` gets 7 of the 8 resources and then fails on the user with
`AccessDenied ... iam:ListGroupsForUser`, leaving it orphaned. Harmless, since the user stays in Terraform state
and the next `apply` adopts it, but the teardown reports failure.

The WRITER identity Terraform then provisions, and which 14 seals into the cluster, is far narrower: just
`s3:ListBucket` plus `GetObject`, `PutObject` and `DeleteObject` on the bucket. See `terraform/main.tf`.

## The plugin (`03_barman_cloud_plugin`, wave 3)

The plugin ships no Helm chart, only manifests and Kustomize, so unlike every other app the wrapper vendors the
pinned release manifest VERBATIM into `templates/`. It carries no Go-template braces, so Helm passes it through.
There is no dependency to pin, no `Chart.lock` and no vendored `.tgz`. The version lives in the chart's
`appVersion` plus the image tag; re-vendor via that chart's `README.md`.

Wave 3 because it needs cert-manager (wave 2, for its mTLS Issuer and Certificates) and the CNPG operator (wave 2,
to discover the plugin Service), and it must live in `cnpg-system`.

## Turning backups on

```sh
# .env: set the deployer creds + bucket. Empty AWS_DEPLOY_ACCESS_KEY_ID means backups stay OFF (13/14 no-op).
#   AWS_REGION, S3_BACKUP_BUCKET, AWS_DEPLOY_ACCESS_KEY_ID, AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET
make s3-backup-bucket        # 13: Terraform, bucket + lifecycle + IAM writer
make configure-cnpg-backup   # 14: bucket/region/RPO into pg-cluster files/backup.yaml + seal writer creds ONCE
git add -A && git commit && git push   # ArgoCD applies the plugin + each ObjectStore/ScheduledBackup + sealed creds
```

`14` edits only the SHARED `lib/helm/pg-cluster/files/backup.yaml`: the scalars (`bucket`, `region`,
`retentionPolicy`, `archiveTimeout`) plus the writer creds, sealed ONCE cluster-wide. The static wiring (plugin,
provider, bucket path, WAL and data compression, the daily cron) is hardcoded in the templates, not the overlay.

`backupsEnabled` defaults true in `values.yaml`, so a POPULATED overlay is the opt-in: the moment `14` fills in
`bucket`, EVERY CNPG cluster in every workload gets backups, and each instance stamps its OWN `<name>-backup-s3`
SealedSecret and creds Secret from that one blob. Adding a Postgres workload needs nothing extra here.

Cluster-wide seal scope, rather than the repo's usual `strict`, is the deliberate trade that lets one ciphertext
unseal into any name in any namespace. That is exactly what lets every instance reuse the same blob under its own
per-instance secret name, so N DBs in one namespace never collide and there is no shared secret to elect an owner
for. Accepted because it is the same S3 writer for all CNPG workloads.

`10a` and `10b` are wired best-effort into `DANGEROUS_bootstrap_cluster.sh`, guarded on the deployer key, so a
full bootstrap runs `terraform apply` and seals automatically. A REBUILD runs `10a wipe`, discarding the old
backups while keeping the bucket and IAM so the fresh clusters start a clean history. It does NOT re-seal, since
the restored key already decrypts the committed secret, and does NOT `terraform destroy`. Only
`make s3-backup-destroy` tears the bucket down.

## Monitoring

Backup health is alerted by Grafana-provisioned rules, the only path that fires, since `vmalert` and Alertmanager
are off. No chart `PrometheusRule` defines these, to avoid inert duplicates: `lib/helm/pg-cluster` emits none at
all, so the upstream CNPG rules never enter the cluster.

CNPG, in the Grafana `backups` group:

- `cnpg-wal-archive-failing` (critical): `cnpg_collector_pg_wal_archive_status{value="ready"} > 0` for 15 min, so
  WAL segments are piling up unarchived. Act on this one first: a stalled archiver fills `pg_wal`, and a full
  `pg_wal` turns the primary read-only.
- `cnpg-backup-too-old` (warning): last successful base backup more than 36h old. Guarded with `> 0` because the
  `cnpg_collector_last_available_backup_timestamp` metric is deprecated and may stay 0 under the plugin. If so,
  this alert simply will not fire and we lean on the WAL alert plus `kubectl cnpg status`.

Redis, keyed on the CronJob NAME via kube-state-metrics, since arbitrary pod and job labels are not exported but
the name always is:

- `redis-backup-failed` (warning): the central backup Job failed, meaning one or more instances failed to dump or
  upload. The job's stdout says which.
- `redis-backup-stale` (warning): more than 36h since the last success, guarded `> 0` so it stays quiet before the
  first one. Raise it if you set a slower schedule.

Longhorn, off Longhorn's own metrics since its ServiceMonitor is on:

- `longhorn-backup-failed` (warning): a volume's backup is in Error state.
- `longhorn-backup-stale` (warning): more than 48h since the last backup, guarded `> 0`. A silently stopped
  RecurringJob produces no Error state, so this is the only signal.

VM/VL: `vm-backup-failed` and `vm-backup-stale`, same shape as Redis.

Plus the per-unit recoverability rules, which are the only ones that catch an empty catalog sitting behind healthy
machinery: `cnpg_backup_recoverable` and `redis_backup_recoverable`, both critical.

Verify the exact metric and label names against the live cluster at apply time. A wrong name yields NoData, which
reads as OK: silent, never a false alert, but also never a true one.

## Redis RDB backups

Durable Redis instances back up to S3 as periodic RDB dumps, reusing this bucket, writer and lifecycle under the
`redis/` prefix.

One central platform app does it, `07_redis_backup` (wave 7, ns `redis-backup`): a single CronJob discovers every
durable instance cluster-wide by label, dumps each with `redis-cli --rdb`, and uploads. So there is one sealed
secret in one namespace and no per-namespace list. The trade is a single global schedule and job-level alerting,
with the failing instance named in the job's stdout, which lands in VictoriaLogs.

Full mechanism, the `make configure-redis-backup` runbook, and `make restore-redis` are in
[09_redis.md](09_redis.md), under "Off-cluster backups: RDB to S3". Unlike CNPG, whose retention Barman manages,
Redis relies entirely on the bucket's S3 lifecycle for expiry.

## Longhorn volume backups

Selected Longhorn volumes back up under the `longhorn/` prefix. This is for workloads that keep state on a Longhorn
PVC with no backup mechanism of their own: sqlite files, config dirs, generic app data.

Opt-in per volume via the StorageClass. Of the three classes `02_longhorn` ships, only
`longhorn-r2-retained-with-backups` (reclaim Retain) is backed up off cluster; `longhorn-r2-ephemeral` and
`longhorn-r2-ephemeral-local` (both reclaim Delete) are not. A workload opts in simply by naming that class. It
has no consumer yet.

Everything else is deliberately NOT Longhorn-backed-up, because each has a better logical path:

| On a non-backed-up class | Covered instead by |
|---|---|
| CNPG Postgres | its own WAL + base to `cnpg/`, which is point-in-time and app-consistent |
| Redis (durable) | RDB dumps to `redis/` |
| VictoriaMetrics, VictoriaLogs | native exports to `vm/` |
| RabbitMQ | nothing, on purpose: the data is in-flight messages, and HA is the running quorum |
| ntfy | nothing yet; it is the obvious first candidate for the backed-up class |

A logical dump is app-consistent and far cheaper than block-level backup of a large, churny store.

Native Longhorn backup, not a central CronJob, unlike Redis. Redis is a network service, so its backup is one
central job that dumps each instance over the network. Longhorn PVCs are RWO block devices attached to a single
node with no network pull interface, so the only way to read one for backup IS Longhorn's own backup API.

So Longhorn uses its built-in backup target plus `RecurringJob`s plus a StorageClass `recurringJobSelector`, all
configured inside the existing `02_longhorn` app at wave 2. There is deliberately no separate backup app. Native
backup is also incremental and deduplicated, which is cheap on a home uplink, crash-consistent, and
content-agnostic with no per-app dump logic.

The classes always exist. The two BACKUP `RecurringJob`s render only `{{- if backupTarget }}`, so no backup runs
until `10d_longhorn_backup.sh` sets the target: the same empty-means-off contract as CNPG and Redis. The
`filesystem-trim` job is unconditional, since it needs no S3 and every volume wants it.

Pieces, all under `argo_apps/platform/charts/02_longhorn/`:

- `values.yaml` `defaultBackupStore`: `backupTarget` (`s3://<bucket>@<region>/longhorn/`) plus
  `backupTargetCredentialSecret`, filled by the script.
- `templates/recurringjobs.yaml`: `backup-daily` (03:00 UTC, retain 7) and `backup-weekly` (Sun 04:00 UTC,
  retain 8, about 2 months), both in the `backup` group. No snapshot job, because local snapshots cost scarce Pi
  NVMe. Plus `filesystem-trim-weekly`, which is not a backup at all: it hands blocks a filesystem has freed back
  to the SSD, which is what keeps a thin volume thin. It reaches every volume through Longhorn's `default` group,
  because a volume with no recurring job of its own lands there automatically, and because a StorageClass's
  `parameters` are immutable so adding a selector to a live class means deleting the class first.
- `templates/storageclasses.yaml`: the three classes. The `-with-backups` one carries a `recurringJobSelector` for
  the `backup` group, so every volume it provisions gets both backup tiers automatically. Having a selector at all
  is also what keeps those volumes OUT of `default`, so add `trim` there too if it ever gains a consumer.
- `templates/backup-s3-sealedsecret.yaml`: the sealed `longhorn-backup-s3` with keys `AWS_ACCESS_KEY_ID` and
  `AWS_SECRET_ACCESS_KEY`, the names Longhorn's S3 target expects, in `longhorn-system`.

Retention is Longhorn's, not S3's. The `longhorn/` prefix is lifecycle-exempt, so the RecurringJob `retain` counts
are the only thing that deletes anything: Longhorn prunes old backups and the blocks they no longer reference.

That makes three retention models in this doc:

| Consumer | Object shape | Who expires |
|---|---|---|
| CNPG | WAL and base sets | Barman, with an aligned S3 expiry as backstop |
| Redis, VM/VL | self-contained dumps and daily exports | S3 lifecycle |
| Longhorn | incremental dedup chains | Longhorn's `retain`. S3 must NOT expire |

Consistency is crash-consistent, like pulling the power cord. Fine for sqlite, whose journal survives power loss. A
future app needing app-consistency should dump itself to a backed-up volume, the way CNPG and Redis do.

### Turning Longhorn backups on

```sh
make s3-backup-bucket           # 13: Terraform (idempotent), also splits the lifecycle per-prefix
make configure-longhorn-backup  # 16: backup target into 02_longhorn values + seal creds into longhorn-system
git add -A && git commit && git push   # ArgoCD applies backupTarget + creds + the classes + RecurringJobs
# verify:
kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.status.available}{"\n"}'  # true
kubectl -n longhorn-system get recurringjobs.longhorn.io      # backup-daily + backup-weekly (+ filesystem-trim-weekly)
kubectl get storageclass | grep longhorn-                     # ephemeral, ephemeral-local, retained-with-backups
```

### Restore

`make restore-longhorn` restores a volume from S3. This cluster runs with the CSI snapshotter sidecar DISABLED
(`csi.snapshotterReplicaCount: 0`), so the Kubernetes `VolumeSnapshot` restore path is unavailable.

The script uses Longhorn's native path instead: it discovers `BackupVolume`s, picks a `Backup` (latest or named,
reading the exact `fromBackup` URL off its `.status.url`), then creates a Longhorn `Volume` CR with
`spec.fromBackup` plus a static PV and PVC in the target namespace. Non-destructive: it never touches the source
backups or a live volume, and refuses to overwrite. Then point your workload at the restored PVC.

```sh
make restore-longhorn   # interactive: lists BackupVolumes, prompts for volume + target namespace
# or non-interactive:
bash lib/shell/recover_longhorn_from_s3.sh --volume pvc-xxxx --backup latest --target-ns myns --name myns-data-restore --apply
```

Full-cluster recovery ordering:

1. `make restore-secrets-key` (06), so the committed `longhorn-backup-s3` decrypts.
2. Let the platform sync. Longhorn's `default` BackupTarget goes `available` and auto-discovers the
   `BackupVolume`s from S3 within the `pollInterval`.
3. `make restore-longhorn` per volume you want back.

Redis restores from its RDB dumps and the monitoring volumes from their VM/VL exports; both otherwise rebuild
empty. As with everything here, the whole path hinges on the off-repo sealed-secrets key: without it the S3 creds
cannot decrypt and the backups are unreachable.

## VictoriaMetrics and VictoriaLogs backups

Both stores back up under the `vm/` prefix. They sit on `longhorn-r2-ephemeral`, and `deletionProtection` on their
CRs covers an accidental prune but NOT a total loss of both replicas, the cluster, or the site. This closes that
gap with an app-consistent logical export, done by one central platform app, `08_vm_backup` (wave 8, ns
`monitoring`): a single daily CronJob streams both stores to S3 with no PVC access needed.

Why export and import rather than `vmbackup`: the obvious tool is open-source but needs FILESYSTEM access to the
store's data dir, an RWO Longhorn PVC already attached to the running pod, which a separate job cannot co-mount.
The operator's `VMSingle`/`VLSingle` spec has no supported general sidecar field, and the operator's automated
`vmBackup` sidecar uses `vmbackupmanager`, which is Enterprise-only. So we take the FOSS route VictoriaMetrics
itself documents for migration and backup, the HTTP export/import API, which needs no volume access and mirrors the
Redis central-CronJob shape.

Each 01:00 run backs up only the PREVIOUS full UTC day, a bounded daily slice, one file per day:

- metrics: `GET /api/v1/export/native?match[]={__name__!=""}&start&end`, gzipped to
  `s3://<bucket>/vm/metrics/<YYYYMMDD>.native.gz`
- logs: `GET /select/logsql/query?query=_time:[start,end)`, gzipped to `s3://<bucket>/vm/logs/<YYYYMMDD>.jsonl.gz`

Pieces, all under `argo_apps/platform/charts/08_vm_backup/` plus two netpol edits on the stores:

- `values.yaml`: `bucket` and `region` filled by `10e_vm_backup.sh` (empty means the feature is off and nothing
  renders), `prefix: vm/`, the `schedule` at 01:00 UTC to offset from the 02:00 and 03:00 crowd, and the two store
  Service URLs.
- `templates/cronjob.yaml`: one container (`alpine/k8s`, for curl, aws-cli and gzip) that streams each dump with
  `curl | gzip | aws s3 cp -` and no local disk. A failed export OR upload deletes the partial object and fails the
  Job so the alert fires.
- `templates/networkpolicy.yaml`: egress-only lockdown to DNS, S3 and the two stores. The stores' own ingress
  allowlists each add `app.kubernetes.io/name: vm-backup` so this pod is admitted.
- `templates/vm-backup-s3-sealedsecret.yaml`: the sealed `vm-backup-s3` in `monitoring`.

Retention is S3's, the same model as Redis: each daily slice is self-contained, so age-expiry just drops the oldest
days.

Why daily slices rather than one full dump: a full-store export's peak memory grows with the dataset and eventually
OOMs the store, which it did. A fixed one-day window keeps peak memory flat forever. Trade-off: a full recovery
replays EVERY slice, not one file.

Two caveats. A gap day from a failed run leaves a hole unless you re-run for that day. And the VictoriaLogs JSONL
round-trip is best-effort on stream-field fidelity, because stream labels are re-derived on import.

### Turning VM/VL backups on

```sh
make s3-backup-bucket       # 13: Terraform (idempotent), adds the vm/ lifecycle rule
make configure-vm-backup    # 17: bucket/region into 08_vm_backup values + seal creds into monitoring
git add -A && git commit && git push   # ArgoCD applies the app (wave 8) + the sealed creds
# verify:
kubectl -n monitoring create job --from=cronjob/vm-backup vm-backup-manual
kubectl -n monitoring logs job/vm-backup-manual -f
aws s3 ls s3://$S3_BACKUP_BUCKET/vm/ --recursive     # vm/metrics/*.native.gz + vm/logs/*.jsonl.gz
```

### Restore

`make restore-vm` streams a chosen export back into the LIVE store's `/import` endpoint via a temporary pod in
`monitoring`, reusing the sealed creds and the `vm-backup` ingress allowlist, with a break-glass egress netpol
letting it reach S3 and the store. Non-destructive, because `/import` MERGES, so for a clean recovery point it at a
fresh or empty store.

```sh
make restore-vm   # interactive: prompts for kind (metrics|logs) + target (all|latest|<s3-key>)
# or non-interactive. `all` replays every daily slice (full recovery), `latest` just the newest day:
bash lib/shell/recover_vm_from_s3.sh --kind metrics --target all --apply
```

Full-cluster recovery ordering: `make restore-secrets-key` (06), let the platform sync so the stores come up empty,
then `make restore-vm` for each kind to backfill. Same key dependency as every other backup here.

## Recovery paths

Durability is two layers, and only the second has a recovery step:

- In-cluster, nothing to run: synchronous streaming replication across the instances, Longhorn's 2 volume
  replicas under each of them, plus orphan-not-delete. Manifests leaving
  git do NOT delete the `Cluster`, thanks to `Prune=false,Delete=false` on the whole DB unit, so it keeps running
  unmanaged and restoring the files re-adopts it. `05_orphan_exporter` plus the `orphan` alert group make that
  state loud.
- Off-cluster in S3: Barman Cloud, continuous WAL plus a daily base, for real data loss: a dropped table, a bad
  migration, or losing every replica of a volume at once. Losing a MACHINE no longer needs it, since the volume
  reattaches on a survivor ([13_node_loss.md](13_node_loss.md)).

Pick by what is actually wrong:

| Symptom | What to do |
|---|---|
| DB still running, app permanently OutOfSync | Restore the workload's files in git and push. Argo re-adopts it, no data moves |
| `Cluster` is GONE and you want it back as itself | `make restore-cnpg`, mode in-place |
| DB is fine; verify a backup, read old rows, test a PITR target | `make restore-cnpg`, mode side |
| Whole cluster rebuilt | `make restore-secrets-key` first, so the sealed S3 creds decrypt, then mode in-place per DB |
| A machine died or was replaced | Nothing here, and nothing to delete. The volume reattaches on a survivor and Postgres replays WAL; an HA primary is replaced by a promoted standby: [13_node_loss.md](13_node_loss.md) |
| Every replica of one volume is gone (`faulted`) | `make restore-cnpg` for a database; `make restore-longhorn` for a volume on the backed-up class |

### `make restore-cnpg`

`lib/shell/recover_cnpg_from_s3.sh` is the runbook, executable. It asks for a mode, namespace and database name,
then in both modes lists every catalog it can see, checks the S3 creds Secret, and proves a COMPLETED base backup
exists, both from the ObjectStore status and independently by listing S3 with the deployer creds.

That last check is the one that matters: WAL alone has no recovery point, and it is what catches a
`destinationPath` change having orphaned the old catalog at a different prefix.

Mode `side` applies one throwaway single-instance `Cluster` named `<db>-restore` reading the same catalog, latest or
a PITR timestamp. It does not archive WAL and is not a GitOps object. Data at `<name>-rw.<ns>`; delete it when done.
Refuses to overwrite an existing cluster.

Mode `in-place` drives the chart's `restore` and `deletionProtection` knobs, so it spans your commits and is
RESUMABLE: run it, push what it edited, run it again. It prints its phase every time.

1. Enable. Finds the workload chart and alias owning the DB, sets `<alias>.restore.enabled: true` plus `targetTime`
   for PITR, drops `deletionProtection` to false, and prints the commit. A HEALTHY live `Cluster` gets a
   confirmation prompt first, since continuing rewinds it to the catalog; a broken or absent one just proceeds.
2. Delete and wait. Refuses until the live `Cluster` carries `cnpg.io/skipEmptyWalArchiveCheck`, which is what
   proves ArgoCD has synced the restore render, then deletes it so ArgoCD recreates it already carrying
   `bootstrap.recovery`. Watches the base-backup pull, WAL replay, promotion and the replica join. The recovery job
   is one-shot and the operator never retries it, so a failed attempt is offered for deletion. That is the normal
   way to resume after fixing anything.
3. Verify and finish. Prints `cnpg status`, every restored table with its live row count, the new timeline, and
   whether the restored DB is backed up again. Offers to roll every workload referencing the regenerated
   `<db>-app` Secret. Then removes `restore`, sets `deletionProtection: true`, and prints the final commit.

Between phases you run the `git add/commit/push` it prints. No script here runs git.

Phase 2 has to tell the `Cluster` it must delete from the one the restore already rebuilt, or a re-run would wipe a
good recovery. It uses the `-full-recovery` bootstrap job while that exists, and afterwards the `Cluster` being
newer than the commit that enabled the restore, since CNPG deletes the job once the recovery lands. Those can be
under a minute apart, so `--yes` cannot delete a `Cluster` that is SERVING: that one always asks, whichever way it
read the clocks. A broken `Cluster` is unambiguous and stays automatable.

Three facts the script relies on, worth knowing when it goes sideways:

- A restore always lands on a NEW timeline and re-archives into the same prefix, so the plugin's pre-flight
  `barman-cloud-check-wal-archive` would abort with `Expected empty archive`. The chart stamps
  `cnpg.io/skipEmptyWalArchiveCheck: enabled` when recovering from its own catalog, and deliberately not when
  `restore.serverName` names a different source, where the check is protective.
- Deleting a `Cluster` takes its `<db>-app` Secret with it, so the password is REGENERATED. The chart's recovery
  block sets `database: app` and `owner: app` so CNPG realigns the role, but consumers still need a restart.
- Turning `restore` back off is inert, since `spec.bootstrap` is never re-read. Leaving it on would make a future
  re-create silently restore instead of running `initdb`.

### Deleting a database on purpose

Two commits, never `kubectl delete`:

1. Set `deletionProtection: false` for that instance and push, which drops the sync-options.
2. Remove its values block and `Chart.yaml` alias and push. The prune now cascades, PVCs included.

Never leave a DB sitting on `false`.

### Rebuild vs reset, and why rebuild wipes the backups

A REBUILD is a deliberate full fresh start. It empties the S3 bucket via `10a wipe`, keeping the bucket and
IAM. It does NOT touch the nodes: wiping the Longhorn volumes means resetting Talos, which is the OS repo's
`make reset-cluster`, run before this. A rebuild on un-reset nodes redelivers the platform onto the existing
volumes.

Wiping the backups is required for correctness, not a side effect. The rebuilt, same-named clusters would
otherwise inherit the old backup path, and Barman refuses to mix a new Postgres systemID into an existing server's
data, so the `cnpg-wal-archive-failing` alert would fire forever. Emptying the bucket lets the fresh clusters start
a clean history.

So a rebuild DISCARDS your backups. If you want the old data, restore it BEFORE rebuilding, or do not rebuild. To
recover specific data without a rebuild, use `make restore-cnpg` against the live bucket.

### Recreating ONE cluster hits the same wall

Deleting and recreating a single `Cluster` under the same name, e.g. to change its storage class, which is
immutable, gives it a new `initdb` systemID against a catalog that still holds the old one. Barman refuses:

```
WAL archive check failed for server <name>: Expected empty archive
```

`ContinuousArchiving` goes `False` and stays there. The database serves fine and nothing else looks wrong, so
check that condition after any recreate. `restore.enabled` is NOT the fix, and neither is stamping
`cnpg.io/skipEmptyWalArchiveCheck` permanently: that only silences the guard against mixing two systemIDs in one
catalog.

Empty just that server's prefix, not the whole bucket:

```bash
aws s3 rm --recursive "s3://<bucket>/cnpg/<namespace>/<cluster>/"
kubectl -n <ns> delete backups.postgresql.cnpg.io --all   # they point at objects that are now gone
kubectl -n <ns> exec <primary> -c postgres -- psql -U postgres -tAc 'select pg_switch_wal()'
```

Archiving recovers within a minute. Then take a base backup at once, with a `Backup` CR using `method: plugin`,
rather than waiting for the 02:00 schedule: until one completes there is no restore point at all.

A base backup is not restorable the moment it reports `completed`. Recovery needs the WAL segment holding the
backup-end record, and that only reaches S3 after `archive_timeout` (15 min) or a segment fill, so a restore
attempted before then dies on `WAL ends before end of online backup` and retries until the segment lands. To
restore immediately, force the switch:

```bash
kubectl -n <ns> exec <primary> -c postgres -- psql -U postgres -tAc 'select pg_switch_wal()'
```

Tearing the bucket down is a separate, explicit act: `make s3-backup-destroy` empties it AND `terraform
destroy`s it plus the IAM writer. Nothing calls that for you, and the OS repo's `make reset-cluster` knows
nothing about S3: it wipes node state only.

## Verify end to end

1. Bucket: `aws s3api get-bucket-lifecycle-configuration --bucket <bucket>` shows the per-prefix rules, encryption
   is on, public access is blocked, and the IAM writer is scoped to the bucket. `make s3-backup-bucket` again is a
   no-op.
2. Plugin synced: platform Healthy, `kubectl get crd objectstores.barmancloud.cnpg.io`, and the `barman-cloud`
   Deployment Ready in `cnpg-system`.
3. WAL archiving live, the check that matters most: the Cluster's `ContinuousArchiving` condition is `True` and
   objects appear under `s3://<bucket>/cnpg/<ns>/<cluster>/wals/`. The daily base backup runs on a standby pod.
   Read the recovery point off the OBJECTSTORE, not the Cluster: under the plugin
   `Cluster.status.firstRecoverabilityPoint` stays permanently empty even with a completed base backup in S3.
   Everything downstream follows from that. `05_orphan_exporter` reads the ObjectStore and publishes
   `cnpg_backup_recoverable`, `cnpg_backup_last_success_seconds` and `cnpg_backup_first_recoverability_seconds`;
   `cnpg-backup-too-old` alerts on the second of those, because CNPG's own
   `cnpg_collector_last_available_backup_timestamp` is flat 0 here and an alert on it can never fire; and the
   `cnpg` dashboard's Backups panels are rewritten onto the same two (see
   [06_monitoring.md](06_monitoring.md)). There are also no `backups.postgresql.cnpg.io` objects to list under
   the plugin, so a runbook step that says `kubectl get backup` will always come back empty.

   ```bash
   kubectl -n <ns> get objectstores.barmancloud.cnpg.io -o \
     jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.serverRecoveryWindow}{"\n"}{end}'
   ```
4. RPO: `SELECT pg_switch_wal();` on the primary produces a new object under `wals/` within seconds, and `SHOW
   archive_timeout;` reads `15min`.
5. Restore drill: `make restore-cnpg`, mode `side`, target `latest`. It reaches Healthy from S3 and serves data;
   delete it after. Repeat with a PITR `targetTime`. A full in-place drill, deleting the DB and bringing it back, is
   the same script in mode `in-place`. Also check `cnpg_backup_recoverable` reads 1 per DB: it is the only signal
   that catches an empty catalog sitting behind healthy WAL archiving.
6. Alerts: confirm the metric name and label against `/metrics`, then break archiving (for example revoke the IAM
   key briefly) so `cnpg-wal-archive-failing` fires, and restore so it clears.

Spell out `backups.postgresql.cnpg.io` in full whenever you list them. Longhorn ships a `Backup` kind too, and it
wins the short name, so a bare `kubectl get backup` reports `not found` for a CNPG backup that is right there.

## Why we render the ObjectStore ourselves

The upstream `cnpg/cluster` chart annotates the `ObjectStore` as a Helm `pre-install,pre-upgrade,pre-rollback`
hook. Under ArgoCD that makes it an EPHEMERAL PreSync hook rather than a tracked resource.

ArgoCD created it once, it was removed, and it never came back: WAL archiving stopped, the CNPG cluster stuck
`Ready=False` with `ContinuousArchivingFailing: ObjectStore ... not found`, and the whole workload's sync wedged
behind the unready cluster. Verified on a rebuild: 3 stale S3 objects, then nothing for about an hour. A hard
break, not a blip.

That is why `pg-cluster` renders the CNPG CRs directly instead of wrapping the upstream chart. Our
`templates/objectstore.yaml` annotates the `ObjectStore` with `argocd.argoproj.io/sync-wave: "-1"`, a normal
persistent resource applied just before the Cluster, with no Helm hook anywhere.

Previously this required a hand-PATCHED vendored `charts/cluster-*.tgz`, which Renovate's
`helmUpdateSubChartArchives` would silently re-vendor pristine and clobber on any upstream bump. Rendering the CR
ourselves removes the vendored tarball entirely, so there is nothing to patch and nothing for Renovate to clobber.

Upstreamed as <https://github.com/cloudnative-pg/charts/issues/964>, proposing a `backups.objectStore.helmHook`
opt-out plus an ObjectStore-only annotations knob. If that lands, `pg-cluster` could go back to wrapping the
official chart with `helmHook: false` plus the sync-wave annotation, but only if the
transitive-dep-behind-`file://` vendoring problem is also acceptable then. Otherwise keep rendering directly.
