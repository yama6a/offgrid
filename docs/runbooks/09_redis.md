# Runbook: Redis

Decisions and architecture are in [09_redis.md](../09_redis.md).

## Check

1. Load the pinned kubeconfig.

   ```bash
   export KUBECONFIG=.cache/kubeconfig
   ```

2. Check the operator and the instances.

   ```bash
   kubectl -n redis-operator get pods                   # operator Running
   kubectl -n sample-user-manager get redis             # redis-cache and redis-sessions
   kubectl -n sample-user-manager get pvc -o wide       # both on longhorn-r2-ephemeral
   kubectl get vmservicescrape -A | grep -i redis       # metrics reach VictoriaMetrics
   ```

3. Check that both instances get writes.

   ```bash
   kubectl -n sample-user-manager exec sample-user-manager-redis-cache-0    -- redis-cli --scan --pattern 'audit:*'
   kubectl -n sample-user-manager exec sample-user-manager-redis-sessions-0 -- redis-cli SMEMBERS sessions:active
   curl https://sample-user-manager.app.example.com/audit   # events grouped by user UUID
   ```

## Turn on backups

1. Run the backup step. It does nothing while `AWS_DEPLOY_ACCESS_KEY_ID` in `.env` is empty.

   ```bash
   make configure-redis-backup
   ```

2. Commit and push.

## Restore from S3

Pick by symptom:

| Symptom | Action |
|---|---|
| Instance running, data wrong or gone | `make restore-redis` |
| Instance gone, its alias still in git | `make restore-redis`. It waits for Argo CD to rebuild the empty instance, then loads the dump |
| Instance gone and removed from git | Put back its values block and its `Chart.yaml` alias, push, then run `make restore-redis` |
| Instance running, app stays OutOfSync | Restore the files in git. Argo CD adopts the instance again. No data moves |

`make restore-redis` prompts for anything it needs. Read what it prints. If the operator reconciles the `Redis` CR
during the resync and breaks it, run the script again.

## Grow an instance's disk

Changing `initialFixedDiskSize` does nothing to a live instance. The size sits in an immutable StatefulSet template,
and the operator does not expand PVCs.

1. Expand the PVC. Longhorn grows the volume and filesystem online, with no restart.

   ```bash
   kubectl -n <ns> get pvc
   kubectl -n <ns> patch pvc <pvc> --type merge -p '{"spec":{"resources":{"requests":{"storage":"5Gi"}}}}'
   ```

2. Raise `initialFixedDiskSize` in git to the same size, so a rebuild creates the volume at that size.

## Shrink an instance, or move it

Kubernetes cannot shrink a PVC. Move the data to a new instance instead.

1. Add a second alias with the size you want, and push.
2. Copy every key while both instances run. `MIGRATE ... COPY` keeps TTLs and leaves the source intact.

   ```bash
   kubectl -n <ns> exec <old-pod> -- sh -c '
     redis-cli --scan | while read k; do
       redis-cli MIGRATE <new-svc> 6379 "$k" 0 5000 COPY REPLACE
     done'
   ```

3. Point the app at the new instance's `name` in `app.redises`, and push.
4. Delete the old alias as in the next section.

## Delete an instance

1. Set `deletionProtection: false` on the alias. Commit, push and let Argo CD sync. The pod restarts once, because the
   operator copies the CR's annotations onto the pod template. AOF carries the data across.
2. Remove the alias from `values.yaml` and `Chart.yaml`. Commit and push. The sync deletes the instance and its
   volume. The S3 dump is then the only copy.

Never leave an instance on `false` beyond these two commits.
