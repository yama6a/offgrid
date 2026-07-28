# 13: Off-cluster backups — CNPG Postgres + Redis + Longhorn to S3

Until now durability was entirely **in-cluster**: Postgres replication across 2 instances + `local-path`
`reclaimPolicy: Retain` ([08_storage.md](08_storage.md)). That survives a node loss, but not a bad `DROP`,
data corruption, losing >1 node, or a full rebuild. This step adds the **off-cluster** tier: continuous WAL
archiving + daily base backups from every CloudNativePG cluster to **S3**, via the current
**Barman Cloud CNPG-I plugin** — giving point-in-time recovery and a ~180-day recovery window.

The S3 bucket is created by **Terraform** (the repo's only Terraform) and is deliberately general-purpose:
CNPG backups land under `cnpg/`, Redis RDB dumps under `redis/`, and Longhorn volume backups under `longhorn/`
(see below). All three reuse the SAME bucket + IAM writer. The S3 lifecycle is **per-prefix**, not bucket-wide —
`cnpg/`+`redis/` tier-and-expire, `longhorn/` never auto-expires (see "Terraform" and "Longhorn volume backups").

Pieces (Terraform is out-of-cluster; the plugin is platform; backups are configured per-cluster via the shared chart):

| Piece                   | Where                                                              | What                                                                                                                                                                                                                                                |
|-------------------------|--------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **the bucket + IAM**    | `terraform/`                                                       | one S3 bucket + a **per-prefix** lifecycle (`cnpg/`+`redis/`: Standard → Glacier IR @30d → expire @180d; `longhorn/`: Standard, never expires), SSE, public-access block, and a scoped IAM writer. Local state (gitignored — holds the IAM secret). |
| **the plugin**          | `argo_apps/platform/{apps,charts}/03_barman_cloud_plugin` (wave 3) | the `ObjectStore` CRD + the Barman Cloud plugin Deployment/Service/RBAC + its cert-manager mTLS certs, in `cnpg-system`. Vendored release manifest (no upstream Helm chart).                                                                        |
| **per-cluster backups** | `lib/helm/pg-cluster`                                              | every CNPG cluster inherits WAL archiving + a daily `ScheduledBackup` + its own `ObjectStore`, all rendered directly by the first-party `pg-cluster` chart (static wiring hardcoded in the templates; per-deployment facts in `files/backup.yaml`).  |
| **wiring scripts**      | `lib/shell/13_s3_backup_bucket.sh`, `14_cnpg_backup.sh`            | 13 runs Terraform; 14 writes the bucket/region/RPO + the cluster-wide sealed writer creds into `lib/helm/pg-cluster/files/backup.yaml`.                                                                                                              |
| **recovery**            | `lib/helm/pg-cluster` `restore.enabled` / `recover_cnpg_from_s3.sh` | two paths, latest or PITR: the chart knob rebuilds the cluster IN PLACE under its own name (GitOps), the script bootstraps an unmanaged side cluster to verify or read from. See "Recovery paths".                                                   |

## The mental model: WAL + base, not a snapshot

A physical Postgres backup is **two things that must both work**:

1. **Continuous WAL archiving** — every 16 MB WAL segment shipped to S3 as it's completed. This is what gives
   PITR and near-zero RPO, and it's the part that's easy to under-think.
2. **Base backups** — periodic full copies of the data dir (here: daily, from a standby).

Base backup + the WAL since it = restore to any point in between. **A stalled archiver is a liveness risk,
not just a DR gap**: if WAL can't ship, `pg_wal` fills the volume and the primary goes read-only / crashes.
That's why the WAL-archive alert below is `critical`.

## Decisions (and the why)

- **Barman Cloud *plugin*, not the in-tree integration.** CNPG deprecated the in-tree `barmanObjectStore` in
  favour of the CNPG-I plugin, so we build on the plugin: `pg-cluster` templates the plugin path directly — the
  `ObjectStore` CR, the Cluster's `.spec.plugins[]` WAL-archiver entry, and the `ScheduledBackup`.
- **ARM64.** Both the CNPG operand images and the plugin **sidecar** image
  (`ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar`) ship multi-arch manifests incl. `linux/arm64` — they
  run on the Pi 5s (the usual Pi gate, cf. the Redis exporter in [12_redis.md](12_redis.md)).
- **RPO 15 min.** `archive_timeout: "15min"` (`files/backup.yaml` `archiveTimeout`, from `.env CNPG_BACKUP_RPO`) forces a WAL
  segment switch — and thus an archive — at most every 15 min, so a primary failure loses ≤15 min of writes.
  It only *binds* in the low-but-nonzero write regime (a busy DB fills segments and archives faster; a truly
  idle DB writes no WAL and archives nothing, correctly). RPO down = more, smaller WAL objects.
- **Daily base backup, from a standby.** `ScheduledBackup` at 02:00. No `target` is set, because CNPG's
  default is already `prefer-standby` (runs on the most up-to-date replica, falling back to the primary) —
  exactly what we want, so the base-backup IO stays off the primary.
- **Storage class: land in Standard → Glacier IR @30d → expire @180d.** Objects are written as S3 **Standard**
  (Barman doesn't set a storage class). We deliberately do **not** use Standard-IA: lifecycle can't transition
  to IA before 30d anyway, and IA's 128 KB min-billable-size + per-GB retrieval fees punish the churny, often
  tiny (compressed near-empty) WAL objects. Straight to Glacier Instant Retrieval at 30d instead. `30`/`180`
  are `.env`-configurable (`S3_BACKUP_TRANSITION_DAYS` / `S3_BACKUP_RETENTION_DAYS`). Note the interplay with
  Glacier's 90-day minimum-storage-duration: 30d→180d means objects spend 150d in Glacier IR, well past the
  minimum, so no early-delete penalty.
- **Retention: Barman's window aligned to the S3 lifecycle.** The `ObjectStore` CRD requires a non-empty
  duration (`^[1-9][0-9]*[dwm]$`) and the chart always emits the field, so leaving it unset isn't possible —
  an empty value renders as `null` and the API rejects it. Instead we set `retentionPolicy` **equal** to the S3
  expiry (`S3_BACKUP_RETENTION_DAYS`d, default `180d`): Barman prunes its own catalog coherently at that age
  (whole backup sets + their WAL), and the S3 lifecycle expiry at the same age is the backstop. Keeping the two
  equal avoids the failure mode where one deletes objects the other still references. (Glacier's 90-day minimum
  is still satisfied — objects transition at 30d and live to 180d.)
- **Encryption:** bucket SSE with AWS-managed keys (SSE-S3 / AES256); Barman also requests AES256 on upload, so
  the two agree. No SSE-KMS to manage.
- **Credentials: Terraform makes a scoped IAM user; `.env` holds only the deployer creds.** Terraform provisions
  a dedicated, bucket-scoped IAM writer and exposes its access key as an output; `14_cnpg_backup.sh` reads that
  output and seals it into the cluster. The powerful deployer creds that run Terraform never enter the cluster.
  On bare-metal Talos there's no instance role, so it's static keys — sealed, never in `.env` or git.
- **One bucket, namespace + cluster prefix.** `destinationPath: s3://<bucket>/cnpg/<namespace>/`; Barman appends
  each cluster's `serverName` (= its `name`), so clusters land in their own `cnpg/<namespace>/<clusterName>/{wals,base}/`.
  The namespace in the path makes it collision-proof on just per-namespace name uniqueness (which validate.yaml
  enforces), so no global-uniqueness requirement. One shared bucket + one sealed creds Secret per DB instance.
  Redis reuses the same bucket + writer under `redis/<namespace>/<instance>/`, but with ONE sealed
  `redis-backup-s3` in a single namespace (its backup runs centrally — see "Redis RDB backups").
- **The plugin is network-policed.** The `barman-cloud` plugin Deployment (cnpg-system) carries its own
  pod-scoped `CiliumNetworkPolicy` (`03_barman_cloud_plugin/templates/networkpolicy.yaml`): ingress `:9090` (the
  CNPG-I gRPC, from the cnpg-operator) + the kubelet TCP probe; egress DNS + the API server + S3 (`world:443`,
  for backup-catalog/recovery-window reads). The instance SIDECAR does its own S3 upload (allowed by the
  `pg-cluster` netpol) and talks to its instance-manager over localhost — it does NOT dial this central Service,
  so there's deliberately no instance→`:9090` rule. See [04_networking.md](04_networking.md).

## Terraform (`terraform/`)

State is **local** and gitignored (it holds the generated IAM secret key; the repo is public);
`.terraform.lock.hcl` **is** committed (provider pin, not sensitive). No `.tfvars` — the wrapper script passes
everything via `TF_VAR_*` + the `AWS_*` provider env, so no secret file lands on disk.

```sh
make s3-backup-bucket     # 13 apply  : create/update the bucket + lifecycle + IAM writer (idempotent)
make s3-backup-wipe       # 13 wipe   : delete ALL backups, KEEP the bucket + IAM (what a rebuild does)
make s3-backup-destroy    # 13 destroy: empty the bucket THEN terraform-destroy it + the IAM writer
```

The bucket is `force_destroy = false`, so a bare `terraform destroy` refuses a non-empty bucket — that's why
`destroy` empties it first (an explicit, typed-confirmed act) and nothing deletes backups by accident.

**Per-prefix lifecycle (not bucket-wide).** `main.tf` has three lifecycle rules, one per consumer prefix, because
they need different retention. `cnpg/` and `redis/` both tier to Glacier IR @`transition_days` and expire
@`retention_days` — their objects are self-contained (WAL/base sets, whole RDB dumps), so age-expiry is safe and S3
owns retention. `longhorn/` gets **no transition and no expiration** (only an aborted-multipart cleanup): Longhorn
backups are incremental, deduplicated block chains, so a newer backup references older blocks — an age-based expiry
would delete still-referenced blocks and corrupt restores. Longhorn's own RecurringJob `retain` is the sole deleter
for `longhorn/`. This is why enabling Longhorn backups needed a Terraform change (redis/CNPG did not).

### The deployer IAM credentials (`.env`)

`.env`'s `AWS_DEPLOY_ACCESS_KEY_ID` / `AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET` are a **deployer** identity used
ONLY by Terraform + the wipe/destroy CLI — never sealed into the cluster. It needs to manage exactly one bucket
and one IAM user. Create an IAM user, attach the policy below (replace `<BUCKET>` with your `S3_BACKUP_BUCKET`
and `<ACCOUNT_ID>` with your 12-digit AWS account id — the writer user is named `<BUCKET>-writer` to match
`terraform/main.tf`), and put its access key in `.env`:

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
        "iam:ListAttachedUserPolicies"
      ],
      "Resource": "arn:aws:iam::123456789012:user/my-cluster-backups-writer"
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

`s3:*` is scoped to the single bucket (not account-wide): the broad verb keeps Terraform's ~20 bucket
sub-resource reads on refresh from tripping over one missing `s3:GetBucket*`/`s3:PutBucket*` — tighten to
explicit actions if you prefer. The IAM statement is scoped to the one writer user Terraform creates. The
**writer** identity Terraform then provisions (and 14 seals into the cluster) is far narrower — just
`s3:ListBucket` + `GetObject`/`PutObject`/`DeleteObject` on the bucket (see `terraform/main.tf`).

## The plugin (`03_barman_cloud_plugin`, wave 3)

The plugin ships **no Helm chart** (manifest/Kustomize only), so — unlike every other app — the wrapper vendors
the **pinned release manifest verbatim** into `templates/` (it has no Go-template braces, so Helm passes it
through); there's no dependency to pin, no `Chart.lock`, no vendored `.tgz`. The version lives in the chart's
`appVersion` + the image tag; re-vendor via that chart's `README.md`. **Wave 3** because it needs cert-manager
(wave 2, for its mTLS Issuer/Certs) and the CNPG operator (wave 2, to discover the plugin Service), and must
live in `cnpg-system`.

## Turning backups on

```sh
# .env: set the deployer creds + bucket. Empty AWS_DEPLOY_ACCESS_KEY_ID => backups stay OFF (13/14 no-op).
#   AWS_REGION, S3_BACKUP_BUCKET, AWS_DEPLOY_ACCESS_KEY_ID, AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET
make s3-backup-bucket        # 13: Terraform -> bucket + lifecycle + IAM writer
make configure-cnpg-backup   # 14: yq bucket/region/RPO into pg-cluster files/backup.yaml + seal writer creds ONCE (cluster-wide)
git add -A && git commit && git push   # ArgoCD applies the plugin + each ObjectStore/ScheduledBackup + sealed creds
```

`14` edits only the **shared** `lib/helm/pg-cluster/files/backup.yaml`: the scalars (`bucket`, `region`,
`retentionPolicy`, `archiveTimeout`) plus the writer creds, sealed **once** cluster-wide into `sealed.ACCESS_KEY_ID` /
`sealed.ACCESS_SECRET_KEY`. The static wiring (plugin, provider, bucket path, wal/data compression, the daily cron)
is hardcoded in the templates, not in the overlay. `backupsEnabled` defaults `true` in `values.yaml`, so a
**populated** overlay is the opt-in: the moment `14` fills in `bucket`, **every** CNPG cluster in every workload gets
backups, and each pg-cluster instance stamps its OWN `<name>-backup-s3` SealedSecret + creds Secret from that one
blob. **Adding a Postgres workload needs nothing extra here.** Cluster-wide scope (not the repo's usual `strict`) is
the deliberate trade that lets one ciphertext unseal into any name in any namespace: that's exactly what lets every
instance reuse the same blob under its own per-instance secret name, so N DBs in one namespace never collide and
there's no shared secret to elect an owner for. Accepted because it's the same S3 writer for all CNPG workloads.

`13`/`14` are wired best-effort into `DANGEROUS_bootstrap_cluster.sh` (guarded on the deployer key), so a full
bootstrap runs `terraform apply` + seals automatically. **Rebuild** runs `13 wipe` — it discards the old
backups (keeping the bucket + IAM) so the fresh clusters start a clean history; it does NOT re-seal (the
restored key already decrypts the committed secret) and does NOT `terraform destroy`. Only **`make
reset-cluster`** tears the bucket down (empty + `terraform destroy`). See the two orchestrators' headers.

## Monitoring (alerts)

Backup health is alerted by **Grafana-provisioned rules** (`05_grafana/values.yaml`) — the only path that fires,
since `vmalert` + Alertmanager are off (a chart `PrometheusRule` is converted to a VMRule, but nothing evaluates
it). No chart `PrometheusRule` defines these, to avoid inert duplicates: `lib/helm/pg-cluster` renders its CNPG
CRs directly and emits no `PrometheusRule` at all (the 18 upstream CNPG rules never enter the cluster), and the
`08_vm_backup` alerts template was removed. The CNPG backup rules (Grafana `backups`
group), exprs lifted verbatim from the old PrometheusRule (per-instance pod regex dropped for cluster-wide):

- **`cnpg-wal-archive-failing`** (`critical`): `cnpg_collector_pg_wal_archive_status{value="ready"} > 0` for 15 min —
  WAL segments piling up unarchived. The load-bearing one (a stalled archiver fills `pg_wal`).
- **`cnpg-backup-too-old`** (`warning`): last successful base backup >36h old. Guarded with `> 0` because the
  `cnpg_collector_last_available_backup_timestamp` metric is deprecated and **may stay 0 under the plugin** — if
  so, this alert simply won't fire and we lean on the WAL alert + `kubectl cnpg status`.

The `08_vm_backup` export CronJob is likewise covered by two Grafana rules (`vm-backup-failed`, `vm-backup-stale`),
and the upstream CNPG operational rules are represented by a curated `cnpg-health` group (connection saturation +
physical replication lag; cluster "offline" is already covered by the generic `target-down` rule). All query the
`VictoriaMetrics` datasource directly. *Verify the exact metric/label names (`value` vs `status`, and whether the
backup-timestamp metric populates) against the live cluster — see the verify steps below.*

### Redis backup alerts (Grafana — the path that fires)

`05_grafana/values.yaml` group `backups` adds two rules keyed on the CronJob **name** via kube-state-metrics
(arbitrary pod/job labels aren't exported; the name always is):

- **`redis-backup-failed`** (`warning`):
  `kube_job_status_failed{namespace="redis-backup", job_name=~"redis-backup-.+"} > 0` (this kube-state-metrics has no `kube_job_failed{condition=...}`)
  — the central backup Job failed (one or more instances failed to dump/upload; the job's stdout says which).
- **`redis-backup-stale`** (`warning`):
  `time() - kube_cronjob_status_last_successful_time{namespace="redis-backup", cronjob="redis-backup"} > 36h`,
  guarded `> 0` so it stays quiet before the first success. Raise it if you set a slower schedule. Verify
  `kube_cronjob_status_last_successful_time` exists in the running KSM at apply time.

The same `backups` group also carries the **Longhorn** pair (Longhorn's own metrics, its ServiceMonitor is on):

- **`longhorn-backup-failed`** (`warning`): `max by (volume) (longhorn_backup_state == 4)` — a volume's backup is in
  Error state (`4`).
- **`longhorn-backup-stale`** (`warning`): `time() - longhorn_volume_last_backup_at > 48h` (guarded `> 0`) — a
  silently stopped RecurringJob makes no Error state, so this is the only signal. **Verify the metric name** against
  the running Longhorn at apply time; a wrong name → NoData → OK (silent, never a false alert).

## Redis RDB backups

Durable (`persistence: true`) Redis instances back up to S3 as periodic RDB dumps, reusing this bucket + writer +
lifecycle under the `redis/` prefix. Done by ONE **central** platform app — `07_redis_backup` (wave 7, ns
`redis-backup`): a single CronJob discovers every durable instance cluster-wide (by label), dumps each with
`redis-cli --rdb`, and uploads. So there's **one sealed `redis-backup-s3` secret in one namespace, no
per-namespace list** — the trade is a single global schedule and job-level alerting (which instance failed is in
the job's stdout → VictoriaLogs). Full mechanism, the `make configure-redis-backup` (step 15) runbook, and the
`make restore-redis` recovery are in [12_redis.md](12_redis.md) ("Off-cluster backups — RDB to S3"). Unlike CNPG
(Barman-managed retention), Redis relies entirely on the bucket's S3 lifecycle for expiry.

## Longhorn volume backups

Selected Longhorn volumes back up to S3 under the `longhorn/` prefix, reusing this bucket + writer. This is for
workloads that keep state on a Longhorn PVC with no backup mechanism of its own (sqlite files, config dirs, generic
app data). It is **opt-in per volume via the StorageClass**: `02_longhorn` ships three classes (all r2 —
`longhorn-r2-ephemeral` / `longhorn-r2-retained` / `longhorn-r2-retained-with-backups`; see
[08_storage.md](08_storage.md)). Only PVCs on **`longhorn-r2-retained-with-backups`** are backed up off-cluster.
The monitoring volumes (VM/VL) and Redis, all on `longhorn-r2-ephemeral`, are
deliberately **not** Longhorn-backed-up — each backs up off-cluster via its own logical path instead (Redis RDB
dumps; VM/VL native exports, see "VictoriaMetrics / VictoriaLogs backups" below), which is app-consistent and far
cheaper than block-level backup of large, churny stores. A workload opts in simply by naming the `-with-backups`
class in its PVC / `volumeClaimTemplate`.

**Native Longhorn backup, not a central CronJob (unlike Redis).** Redis is a network service, so its backup is one
central job that `redis-cli --rdb`s each instance. Longhorn PVCs are RWO block devices attached to a single node
with no network pull interface — the only way to read one for backup *is* Longhorn's own backup API. So Longhorn
uses its **built-in** backup target + `RecurringJob`s + a StorageClass `recurringJobSelector`, all configured inside
the existing `02_longhorn` app (wave 2) — there is deliberately **no** separate `NN_longhorn_backup` platform app.
Native backup is also incremental/deduplicated (cheap on the home uplink), crash-consistent, and content-agnostic
(no per-app dump logic). The classes always exist, but the `RecurringJob`s render only `{{- if backupTarget }}`, so
no backup runs until `16_longhorn_backup.sh` sets the target — the same "empty = off" contract as CNPG/Redis.

Pieces, all under `argo_apps/platform/charts/02_longhorn/`:

- **`values.yaml` `defaultBackupStore`** — `backupTarget` (`s3://<bucket>@<region>/longhorn/`) +
  `backupTargetCredentialSecret` (`longhorn-backup-s3`), filled by `16_longhorn_backup.sh`. `pollInterval: 300`.
- **`templates/recurringjobs.yaml`** — two `RecurringJob`s (`task: backup`) in the shared `backup` group: `backup-daily`
  (03:00 UTC, `retain 7`) + `backup-weekly` (Sun 04:00 UTC, `retain 8`, ~2 months). No snapshot job (local snapshots
  cost scarce Pi NVMe).
- **`templates/storageclasses.yaml`** — the two classes (`longhorn-r2-ephemeral` Delete, and
  `longhorn-r2-retained-with-backups` Retain, no consumer yet). The `-with-backups` class carries
  `recurringJobSelector: '[{"name":"backup","isGroup":true}]'`, so every volume it provisions joins the `backup`
  group and gets both tiers automatically.
- **`templates/backup-s3-sealedsecret.yaml`** — the sealed `longhorn-backup-s3` (keys `AWS_ACCESS_KEY_ID` /
  `AWS_SECRET_ACCESS_KEY`, the names Longhorn's S3 target expects) in `longhorn-system`, written by `16`.

**Retention is Longhorn's, not S3's.** The `longhorn/` prefix is lifecycle-exempt (see "Terraform"), so the
RecurringJob `retain` counts are the only thing that deletes anything: Longhorn prunes old backups and the blocks
they no longer reference. This is the third of three retention models in this doc — CNPG (Barman + aligned S3
expiry), Redis (self-contained RDBs, S3 owns expiry), Longhorn (incremental chains, Longhorn owns expiry, S3 must
NOT expire). **Consistency is crash-consistent** (a block snapshot, like pulling the power cord). That's fine for
sqlite (its journal/WAL survives power loss); a future app needing app-consistency should dump itself to a backed-up
volume, the way CNPG/Redis do.

### Turning Longhorn backups on

```sh
make s3-backup-bucket           # 13: Terraform (idempotent) — now also splits the lifecycle per-prefix
make configure-longhorn-backup  # 16: yq the backup target into 02_longhorn values + seal writer creds into longhorn-system
git add -A && git commit && git push   # ArgoCD applies: backupTarget + sealed creds + the -with-backups SCs + RecurringJobs
# verify:
kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.status.available}{"\n"}'  # true
kubectl -n longhorn-system get recurringjobs.longhorn.io      # backup-daily + backup-weekly
kubectl get storageclass | grep longhorn-           # longhorn-r2-ephemeral / -retained / -retained-with-backups
```

### Restore (and disaster recovery)

`make restore-longhorn` (`recover_longhorn_from_s3.sh`) restores a volume from S3. Because this cluster runs with
the CSI snapshotter sidecar **disabled** (`02_longhorn` `csi.snapshotterReplicaCount: 0`), the Kubernetes
`VolumeSnapshot` restore path is unavailable — the script uses Longhorn's native path instead: it discovers
`BackupVolume`s, picks a `Backup` (latest or named, reading the exact `fromBackup` URL off its `.status.url`), then
creates a Longhorn `Volume` CR with `spec.fromBackup` + a static PV + PVC in the target namespace. Non-destructive
(never touches the source backups or a live volume; refuses to overwrite). Then point your workload at the restored
PVC.

```sh
make restore-longhorn   # interactive: lists BackupVolumes, prompts for volume + target namespace
# or non-interactive:
bash lib/shell/recover_longhorn_from_s3.sh --volume pvc-xxxx --backup latest --target-ns myns --name myns-data-restore --apply
```

**Full-cluster DR ordering:** `make restore-secrets-key` (06, so the committed `longhorn-backup-s3` decrypts) →
platform syncs → Longhorn's `default` BackupTarget goes `available` and auto-discovers the `BackupVolume`s from S3
(the `pollInterval`) → `make restore-longhorn` per volume you need back. Redis restores from its RDB dumps
(`make restore-redis`) and the monitoring volumes from their VM/VL exports (`make restore-vm`); both otherwise
rebuild empty. As with CNPG/Redis, the whole path hinges on the off-repo sealed-secrets key (backed up by 06):
without it the S3 creds can't decrypt and the backups are unreachable.

## VictoriaMetrics / VictoriaLogs backups

The metrics store (VMSingle) and logs store (VLSingle) back up to S3 under the `vm/` prefix, reusing this bucket +
writer + lifecycle. Both sit on `longhorn-r2-ephemeral` (r2, `Delete`): `deletionProtection` on their CRs covers
an accidental prune, but NOT a total loss (both replicas / cluster / off-site). This closes that gap with an **app-consistent logical
export**, done by ONE **central** platform app — `08_vm_backup` (wave 8, ns `monitoring`): a single daily CronJob
streams both stores to S3, no PVC access needed.

**Why export/import, not `vmbackup`.** The obvious tool, `vmbackup`/`vmrestore`, is open-source but needs
**filesystem access to the store's data dir** — an RWO Longhorn PVC already attached to the running pod, which a
separate job can't co-mount, and the operator's `VMSingle`/`VLSingle` spec has no supported general sidecar field.
The operator's automated `vmBackup` sidecar uses **`vmbackupmanager`, which is Enterprise-only**. So we take the
FOSS route VictoriaMetrics itself documents for migration/backup — the HTTP export/import API — which needs no
volume access and mirrors the Redis central-CronJob shape:

Each 01:00 run backs up **only the previous full UTC day** (a bounded daily slice), one file per day:

- **metrics** — `GET /api/v1/export/native?match[]={__name__!=""}&start&end` → gzip →
  `s3://<bucket>/vm/metrics/<YYYYMMDD>.native.gz`
- **logs** — `GET /select/logsql/query?query=_time:[start,end)` → gzip → `s3://<bucket>/vm/logs/<YYYYMMDD>.jsonl.gz`

Pieces, all under `argo_apps/platform/charts/08_vm_backup/` (+ two netpol edits on the `05_*` stores):

- **`values.yaml`** — `bucket`/`region` (filled by `17_vm_backup.sh`; empty = feature off, nothing renders),
  `prefix: vm/`, `schedule` (01:00 UTC, offset from the 02:00/03:00 crowd), the two store Service URLs.
- **`templates/cronjob.yaml`** — one container (`alpine/k8s`: curl + aws-cli + gzip) that streams each dump
  (`curl | gzip | aws s3 cp -`, no local disk); a failed export OR upload deletes the partial object and fails the
  Job so the alert fires.
- **`templates/networkpolicy.yaml`** — egress-only lockdown (DNS + S3 + the two stores). The stores'
  ingress allowlists (`05_victoria_metrics_k8s_stack` / `05_victoria_logs` `networkpolicy.yaml`) each add
  `app.kubernetes.io/name: vm-backup` so this pod is admitted on 8428 / 9428.
- Backup-health alerts are **Grafana-provisioned rules** (`vm-backup-failed` + `vm-backup-stale` in `05_grafana`),
  not shipped here — `vmalert` is off, so a chart `PrometheusRule`/VMRule would never fire.
- **`templates/vm-backup-s3-sealedsecret.yaml`** — the sealed `vm-backup-s3` (keys `AWS_ACCESS_KEY_ID` /
  `AWS_SECRET_ACCESS_KEY`) in `monitoring`, written by `17`.

**Retention is S3's** (same model as Redis): the `vm/` prefix transitions to Glacier IR @`transition_days` and
expires @`retention_days` — each daily slice is self-contained, so age-expiry just drops the oldest days. **Why
daily slices, not one full dump:** a full-store export's peak memory grows with the dataset and eventually OOMs
`vmsingle`/`vlsingle` (it did); a fixed one-day window keeps peak memory flat forever. Trade-off: **DR replays every
slice** (`recover_vm_from_s3.sh --target all`), not one file. **Caveats:** a gap day (a failed run) leaves a hole
unless re-run for that day, and the VictoriaLogs JSONL round-trip is **best-effort on stream-field fidelity**
(stream labels are re-derived on import).

### Turning VM/VL backups on

```sh
make s3-backup-bucket       # 13: Terraform (idempotent) — adds the vm/ lifecycle rule
make configure-vm-backup    # 17: yq bucket/region into 08_vm_backup values + seal writer creds into monitoring
git add -A && git commit && git push   # ArgoCD applies the 08_vm_backup app (wave 8) + the sealed creds
# verify:
kubectl -n monitoring create job --from=cronjob/vm-backup vm-backup-manual
kubectl -n monitoring logs job/vm-backup-manual -f
aws s3 ls s3://$S3_BACKUP_BUCKET/vm/ --recursive     # vm/metrics/*.native.gz + vm/logs/*.jsonl.gz
```

### Restore (and disaster recovery)

`make restore-vm` (`recover_vm_from_s3.sh`) streams a chosen export back into the **live** store's `/import`
endpoint via a temporary pod in `monitoring` (reusing the sealed `vm-backup-s3` creds + the `vm-backup` ingress
allowlist; a break-glass egress netpol lets it reach S3 + the store). **Non-destructive** — `/import` MERGES, so
for a clean DR point it at a fresh/empty store.

```sh
make restore-vm   # interactive: prompts for kind (metrics|logs) + target (all|latest|<s3-key>)
# or non-interactive — `all` replays every daily slice (full DR), `latest` just the newest day:
bash lib/shell/recover_vm_from_s3.sh --kind metrics --target all --apply
```

**Full-cluster DR ordering:** `make restore-secrets-key` (06) → platform syncs (VMSingle/VLSingle come up empty) →
`make restore-vm --kind metrics` + `--kind logs` to backfill. Same key dependency as every other backup here.

## Recovery paths

Durability is two layers, and only the second has a recovery step:

- **In-cluster, nothing to run:** streaming replication across the instances, plus orphan-not-delete. Manifests
  leaving git do NOT delete the `Cluster` (`Prune=false,Delete=false` on the whole DB unit), so the DB keeps
  running unmanaged and restoring the files re-adopts it. `05_orphan_exporter` + `orphan.yaml` make that state loud.
- **Off-cluster (S3):** Barman Cloud (continuous WAL + daily base) for real data loss. `local-path` is
  node-pinned, so a lost node's data exists only here.

Pick by what is actually wrong:

| Symptom | What to do |
|---|---|
| DB still running, app permanently OutOfSync | Restore the workload's files in git and push. Argo re-adopts it, no data moves. Nothing else to do. |
| `Cluster` is GONE and you want it back as itself | `make restore-cnpg`, mode **in-place**. |
| DB is fine; verify a backup, read old rows, test a PITR target | `make restore-cnpg`, mode **side**. |
| Whole cluster rebuilt | `make restore-secrets-key` first (the sealed S3 creds must decrypt), then mode **in-place** per DB. |

### `make restore-cnpg`

`lib/shell/recover_cnpg_from_s3.sh` is the runbook, executable. It asks for a mode, namespace and database name,
then in both modes: lists every catalog it can see, checks the S3 creds Secret, and proves a **completed base
backup** exists (from the ObjectStore status, and independently by listing S3 with the `.env` deployer creds).
That last check is the one that matters: WAL alone has no recovery point, and it is what catches a
`destinationPath` change having orphaned the old catalog at a different prefix.

**Mode `side`** applies one throwaway single-instance `Cluster` named `<db>-restore` that reads the same catalog
(`latest` or a PITR timestamp). It does not archive WAL and is not a GitOps object. Data at `<name>-rw.<ns>`;
delete it when done. Refuses to overwrite an existing cluster.

**Mode `in-place`** drives the `pg-cluster` `restore` knob, so it spans your commits and is **resumable**: run it,
push what it edited, run it again. It prints its phase every time.

1. **Enable.** Finds the workload chart and alias owning the DB, sets `<alias>.restore.enabled: true` (plus
   `targetTime` for PITR), prints the commit. Refuses if the `Cluster` still exists, since `spec.bootstrap` is
   only read at create time.
2. **Wait.** Watches the sync, the base-backup pull, WAL replay, promotion and the replica join. The recovery job
   is one-shot and the operator never retries it, so a failed attempt is offered for deletion (this is the normal
   way to resume after fixing anything).
3. **Verify and finish.** Prints `cnpg status`, every restored table with its live row count, the new timeline,
   and whether the restored DB is backed up again. Offers to roll every workload referencing the regenerated
   `<db>-app` Secret. Then removes `restore`, sets `deletionProtection: true` if it was false, and prints the
   final commit.

Between phases you run the `git add/commit/push` it prints. No script here runs git.

Three facts the script relies on, worth knowing when it goes sideways:

- A restore always lands on a **new timeline** and re-archives into the same prefix, so the plugin's pre-flight
  `barman-cloud-check-wal-archive` would abort with `Expected empty archive`. The chart stamps
  `cnpg.io/skipEmptyWalArchiveCheck: enabled` when recovering from its own catalog, and deliberately not when
  `restore.serverName` names a different source, where the check is protective.
- Deleting a `Cluster` takes its `<db>-app` Secret with it, so the password is **regenerated**. The chart's
  recovery block sets `database: app` / `owner: app` so CNPG realigns the role; consumers still need a restart.
- Turning `restore` back off is inert (`spec.bootstrap` is never re-read). Leaving it on would make a future
  re-create silently restore instead of `initdb`.

### Deleting a database on purpose

Two commits, never `kubectl delete`: set `deletionProtection: false` for that instance and push (drops the
sync-options), then remove its values block + `Chart.yaml` alias and push (the prune now cascades, PVCs included).
Never leave a DB sitting on `false`.

### Rebuild vs reset (and why rebuild wipes the backups)

A **rebuild** (`DANGEROUS_rebuild_cluster.sh`) is a deliberate FULL fresh start: it wipes local-path **and**
empties the S3 bucket (`13 wipe`, keeping the bucket + IAM). Wiping the backups is not incidental — it's
required for correctness. The rebuilt, same-named clusters would otherwise inherit the old backup path, and
Barman refuses to mix a new Postgres systemID into an existing server's data (the `cnpg-wal-archive-failing`
alert would fire forever). Emptying the bucket lets the fresh clusters start a clean backup history.

**So a rebuild DISCARDS your backups.** If you want the old data, restore it BEFORE rebuilding — or don't
rebuild. To recover specific data without a rebuild, use `make restore-cnpg` against the live bucket.

A **reset** (`make reset-cluster`) goes further: it empties the bucket **and** `terraform destroy`s it + the
IAM writer — the full teardown. (A rebuild calls reset internally with `REBUILD_IN_PROGRESS=1`, which skips
that destroy so the bucket survives the rebuild.)

## Verify (end-to-end)

1. **Bucket:** `aws s3api get-bucket-lifecycle-configuration --bucket <bucket>` shows the GLACIER_IR@30 /
   expire@180 rule; SSE on; public access blocked; IAM writer scoped to the bucket. `make s3-backup-bucket`
   again is a no-op.
2. **Plugin synced:** platform Healthy; `kubectl get crd objectstores.barmancloud.cnpg.io`; the `barman-cloud`
   Deployment Ready in `cnpg-system`.
3. **WAL archiving live** (load-bearing): `kubectl cnpg status <cluster> -n <ns>` → "Continuous Archiving: OK"
    + a first-recoverability point; objects under `s3://<bucket>/cnpg/<ns>/<cluster>/wals/`. The daily base backup
      runs on the **standby** pod.
4. **RPO:** `SELECT pg_switch_wal();` on the primary → a new object in `…/wals/` within seconds; confirm
   `SHOW archive_timeout;` is `15min`.
5. **Restore drill:** `make restore-cnpg`, mode `side`, target `latest`. It reaches Healthy from S3 and serves
   data; delete it after. Repeat with a PITR `targetTime`. A full in-place drill (delete the DB, bring it back)
   is the same script in mode `in-place`.
   Also check `cnpg_backup_recoverable` reads `1` per DB: it is the only signal that catches an empty catalog
   sitting behind healthy WAL archiving.
6. **Alerts:** confirm the metric name/label against `/metrics`; break archiving (e.g. revoke the IAM key
   briefly) → the `cnpg-wal-archive-failing` Grafana alert fires; restore → it clears.

## ArgoCD + the ObjectStore sync-wave (why we render the CR ourselves)

The upstream `cnpg/cluster` chart annotates the `ObjectStore` as a Helm `pre-install,pre-upgrade,pre-rollback`
hook. Under ArgoCD that makes it an **ephemeral PreSync hook**, not a tracked resource — ArgoCD created it once,
it was removed, and it **never came back**: WAL archiving stopped, the CNPG cluster stuck `Ready=False`
(`ContinuousArchivingFailing: ObjectStore … not found`), and the whole workload's sync wedged behind the
unready cluster (verified on a rebuild: 3 stale S3 objects, then nothing for ~1 h). Not a "tiny blip" — a hard
break.

This is the reason `pg-cluster` **renders the CNPG CRs directly** instead of wrapping the upstream chart. Our
`templates/objectstore.yaml` annotates the `ObjectStore` with `argocd.argoproj.io/sync-wave: "-1"` — a normal,
persistent resource applied just before the Cluster — with no Helm hook anywhere. Previously this required a
hand-**patched** vendored `charts/cluster-*.tgz`, which Renovate's `helmUpdateSubChartArchives` would silently
re-vendor pristine (clobbering the patch) on any `cnpg/cluster` bump. Rendering the CR ourselves removes the
vendored tarball entirely, so there is nothing to patch and nothing for Renovate to clobber. See
`lib/helm/pg-cluster/templates/objectstore.yaml`.

Upstreamed as <https://github.com/cloudnative-pg/charts/issues/964> (proposing a `backups.objectStore.helmHook`
opt-out + an ObjectStore-only annotations knob). If/when that lands, `pg-cluster` can go back to wrapping the
official `cnpg/cluster` chart (`helmHook: false` + `sync-wave` annotation) instead of rendering the CRs by hand
— but only if the transitive-dep-behind-`file://` vendoring problem is also acceptable then; otherwise keep
rendering directly. Revisit when the issue is resolved.
