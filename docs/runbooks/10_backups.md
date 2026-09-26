# Backups runbook

Procedures for the S3 backups. The reasons behind them are in [10_backups.md](../10_backups.md). Redis backups
and restores are in the [Redis runbook](09_redis.md).

## Create the deployer IAM user

The deployer runs Terraform and the wipe and destroy commands. It never enters the cluster.

1. Create an IAM user and attach this policy. Replace `my-cluster-backups` with your `S3_BACKUP_BUCKET` and
   `<ACCOUNT_ID>` with your account ID.

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

2. Put its access key in `.env` as `AWS_DEPLOY_ACCESS_KEY_ID` and `AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET`. Set
   `AWS_REGION` and `S3_BACKUP_BUCKET` too. An empty `AWS_DEPLOY_ACCESS_KEY_ID` keeps every backup off.

Gotchas:

- `s3:*` covers only the one bucket. Terraform reads many bucket sub-resources on refresh, and one missing
  `s3:GetBucket*` would break it.
- Keep the two group actions, although the writer is in no group. The AWS provider lists a user's groups before
  it deletes the user. Without them, `destroy` fails on the last resource with `AccessDenied ...
  iam:ListGroupsForUser`.

## Turn on Postgres backups

1. Create the bucket, lifecycle rules and IAM writer. The command is idempotent.

   ```sh
   make s3-backup-bucket
   ```

2. Write the backup values and seal the writer credentials:

   ```sh
   make configure-cnpg-backup
   ```

3. Commit and push. Argo CD applies each `ObjectStore`, `ScheduledBackup` and the credentials.
4. Check that archiving runs for each cluster:

   ```sh
   kubectl -n <ns> get clusters.postgresql.cnpg.io <cluster> \
     -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}{"\n"}'   # True
   ```

`DANGEROUS_bootstrap_cluster.sh` runs steps 1 and 2 when the deployer key is set.

## Turn on Longhorn volume backups

1. Run `make s3-backup-bucket`, then `make configure-longhorn-backup`.
2. Commit and push.
3. Check the target and jobs:

   ```sh
   kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.status.available}{"\n"}'  # true
   kubectl -n longhorn-system get recurringjobs.longhorn.io   # backup-daily, backup-weekly, filesystem-trim-weekly
   ```

## Turn on VictoriaMetrics and VictoriaLogs backups

1. Run `make s3-backup-bucket`, then `make configure-vm-backup`.
2. Commit and push.
3. Run the job once and check the objects:

   ```sh
   kubectl -n monitoring create job --from=cronjob/vm-backup vm-backup-manual
   kubectl -n monitoring logs job/vm-backup-manual -f
   aws s3 ls "s3://$S3_BACKUP_BUCKET/vm/" --recursive   # 1 metrics/<day>.native.gz, 24 logs/<day>T<hh>.jsonl.gz
   ```

## Back up a missed VictoriaMetrics day

A failed run leaves a gap for that day. Fill it while the day is still inside the store's retention:

```sh
kubectl -n monitoring create job --from=cronjob/vm-backup backfill-20260829 --dry-run=client -o json \
  | jq '.spec.template.spec.containers[0].env += [{"name":"DAY","value":"20260829"}]' \
  | kubectl apply -f -
kubectl -n monitoring logs job/backfill-20260829 -f
```

## Choose a recovery path

| Symptom | Do this |
|---|---|
| The database runs, but its app is OutOfSync | Restore the workload's files in git and push. Argo CD adopts it again. No data moves |
| The `Cluster` is gone and you want it back under its own name | `make restore-cnpg`, mode `in-place` |
| You want to check a backup, read old rows, or test a PITR target | `make restore-cnpg`, mode `side` |
| You rebuilt the whole cluster | `make restore-secrets-key` first. Then the restore for each store |
| A machine died or was replaced | Nothing. The volume reattaches on a surviving node. See [13_node_loss.md](../13_node_loss.md) |
| Every replica of one volume is gone (`faulted`) | `make restore-cnpg` for a database. `make restore-longhorn` for a volume on the backed-up class |

## Restore a Postgres database

```sh
make restore-cnpg
```

The script asks for a mode, a namespace and a database. It first proves that a completed base backup exists.
WAL alone gives no recovery point.

- **Mode `side`** starts a throwaway single-instance cluster `<db>-restore` from the catalog. Connect at
  `<name>-rw.<ns>`, and delete it when you are done.
- **Mode `in-place`** runs in phases. Run it, commit and push what it prints, and run it again. It prints its
  current phase each time.
  1. It turns on `restore` and turns off `deletionProtection`.
  2. After Argo CD syncs, it deletes the `Cluster`. Argo CD recreates it from the catalog.
  3. It shows the restored tables and row counts, offers to restart the apps that use the new `<db>-app` Secret,
     then turns the flags back.

Gotchas:

- The recovery Job runs once and never retries. After you fix the cause, let the script delete the failed attempt
  and run it again.
- `--yes` never deletes a `Cluster` that serves traffic. It always asks for a typed answer.
- The delete creates a new `<db>-app` password. Every app that uses it needs a restart.

## Restore a Longhorn volume

```sh
make restore-longhorn   # lists BackupVolumes, asks for the volume and the target namespace
```

The script creates a new Longhorn `Volume` from the backup, plus a static PV and PVC. It never overwrites. Point
your workload at the restored PVC.

After a full rebuild:

1. Run `make restore-secrets-key`, so `longhorn-backup-s3` decrypts.
2. Let the platform sync. Within the `pollInterval`, Longhorn finds the `BackupVolume`s in S3.
3. Run `make restore-longhorn` for each volume you want back.

## Restore VictoriaMetrics or VictoriaLogs

```sh
make restore-vm   # asks for the kind (metrics or logs) and the target (all, latest or an S3 key)
```

`/import` merges and deletes nothing. For a clean recovery, point it at a new or empty store. `all` replays every
daily slice.

After a full rebuild, run `make restore-secrets-key`, let the stores come up empty, then run `make restore-vm`
for each kind.

## Delete a database on purpose

Use two commits, never `kubectl delete`:

1. Set `deletionProtection: false` for that instance, and push.
2. Remove its values block and its `Chart.yaml` alias, and push. The prune deletes everything, PVCs included.

## Recreate one cluster under the same name

A new `initdb` creates a new system ID, and Barman refuses the existing catalog:

```
WAL archive check failed for server <name>: Expected empty archive
```

`ContinuousArchiving` becomes `False` while the database serves normally. Check it after every recreate. Neither
`restore.enabled` nor a permanent `cnpg.io/skipEmptyWalArchiveCheck` fixes this.

1. Empty that one server's prefix:

   ```bash
   aws s3 rm --recursive "s3://<bucket>/cnpg/<namespace>/<cluster>-pg<major>/"
   kubectl -n <ns> delete backups.postgresql.cnpg.io --all
   kubectl -n <ns> exec <primary> -c postgres -- psql -U postgres -tAc 'select pg_switch_wal()'
   ```

2. Wait for `ContinuousArchiving` to become `True`. It takes under a minute.
3. Take a base backup at once with a `Backup` CR that sets `method: plugin`. Until one completes, there is no
   restore point.
4. Run `select pg_switch_wal()` again. A base backup is restorable only once the WAL segment with its end record
   is in S3. Without the switch, that takes up to 15 minutes, and a restore fails with `WAL ends before end of
   online backup`.

Write `backups.postgresql.cnpg.io` in full. Longhorn also has a `Backup` kind, and it takes the short name.

## Remove the bucket

```sh
make s3-backup-destroy
```

It asks for a confirmation, empties the bucket, then destroys the bucket and the IAM writer. Nothing else runs it.

## Check end to end

1. Check the bucket. One lifecycle rule per prefix:

   ```sh
   aws s3api get-bucket-lifecycle-configuration --bucket <bucket>
   ```

   A second `make s3-backup-bucket` changes nothing.
2. Check the plugin. `kubectl get crd objectstores.barmancloud.cnpg.io` finds the CRD, and the `barman-cloud`
   Deployment in `cnpg-system` is Ready.
3. Check WAL archiving. `ContinuousArchiving` is `True`, and objects appear under
   `cnpg/<ns>/<cluster>-pg<major>/wals/`.
4. Check the recovery window on the `ObjectStore`, not the `Cluster`. The `Cluster` field stays empty under the
   plugin:

   ```bash
   kubectl -n <ns> get objectstores.barmancloud.cnpg.io -o \
     jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.serverRecoveryWindow}{"\n"}{end}'
   ```

5. Check the RPO. `SELECT pg_switch_wal();` on the primary creates a new object under `wals/` within seconds.
   `SHOW archive_timeout;` returns `15min`.
6. Drill a restore. Run `make restore-cnpg` in mode `side` with target `latest`, then with a PITR time. Delete
   the side cluster afterwards. `cnpg_backup_recoverable` reads 1 for every database.
7. Test the alert. Revoke the writer key for a short time, so `cnpg-wal-archive-failing` fires. Restore the key
   and check that the alert clears.
