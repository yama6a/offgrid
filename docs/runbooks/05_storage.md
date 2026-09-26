# Storage and database runbook

The design is in [05_storage.md](../05_storage.md).

## Prepare the nodes for Longhorn

The README lists the host prerequisites: `iscsid`, `fstrim`, 4K kernel pages and a dedicated data volume. Longhorn
also needs that volume bind-mounted into a containerized kubelet with `rshared`. Without it the Longhorn pods see an
empty directory.

1. Add the mount to the node config. On Talos:

   ```yaml
   machine:
     kubelet:
       extraMounts:
         - destination: /var/mnt/storage
           type: bind
           source: /var/mnt/storage
           options: [ bind, rshared, rw ]
   ```

2. On a live cluster, apply it to every node before the Longhorn app syncs. Otherwise every node's disk comes up
   unschedulable.
3. Check the mount on each node:

   ```bash
   talosctl -n <node-ip> read /proc/mounts | grep storage    # /var/mnt/storage present
   ```

## Check Longhorn

1. Check the pods, disks and classes:

   ```bash
   kubectl -n longhorn-system get pods                            # manager on every node, and CSI, Running
   kubectl -n longhorn-system get nodes.longhorn.io -o wide       # every disk Schedulable
   kubectl get storageclass                                       # the three longhorn-r2-* classes, no default
   kubectl -n longhorn-system get recurringjob                    # filesystem-trim-weekly, and the backup jobs
   ```

2. Optional smoke test: apply a 1Gi PVC on `longhorn-r2-ephemeral` and a pod that mounts it. Expect the PVC
   `Bound` and the volume with 2 healthy replicas on two nodes.

## Spread replicas onto a new node

A new node gets replicas only from new volumes or rebuilds, because `replica-auto-balance` stays `disabled`. To
spread replicas over time, set `defaultSettings.replicaAutoBalance: best-effort` in `02_longhorn/values.yaml`.

## Add a key to a StorageClass

StorageClass `parameters` cannot change in place. Argo CD reports the sync failure forever.

1. Delete the class by hand: `kubectl delete storageclass <name>`.
2. Let Argo CD recreate it with the new key.

## Fix hanging concurrent writers on an RWX volume

The Longhorn KB blames NFSv4.1 state handling. Create a new class with
`nfsOptions: "vers=4.0,noresvport,softerr,timeo=600,retrans=5"` and move the PVC to it.

## Fix Longhorn apps that flap `OutOfSync`

Longhorn mutates some of its own objects, such as a StorageClass or a webhook config. Add a targeted
`ignoreDifferences` for the field to the Application. Do not turn off `selfHeal`.

Deleting the Longhorn app or its CRDs destroys every volume. Back up first.

## Check an NFS volume

1. Check the bind:

   ```bash
   kubectl get pv                                # Bound, with the right CLAIM and RECLAIM POLICY
   kubectl -n <ns> get pvc                       # Bound, not Pending
   ```

2. Check the mount from inside a pod:

   ```bash
   kubectl -n <ns> exec <pod> -- sh -c 'mount | grep nfs; id; ls -lan <mountPath>'
   ```

   - The `mount` line shows the options that took effect. They can differ from what the PV asked for.
   - Files owned by `nobody` or `65534` mean the server translates identities. Reads work, writes fail.

## Check CNPG

1. Check the operator and the databases:

   ```bash
   kubectl -n cnpg-system rollout status deploy/cnpg-operator-cloudnative-pg   # rolled out
   kubectl -n sample-user-manager get pods -o wide                             # 3 instances Running, on 3 nodes
   kubectl -n sample-user-manager exec sample-user-manager-db-1 -- \
     psql -U postgres -tAc 'show synchronous_standby_names'                   # non-empty on the HA cluster
   kubectl get vmpodscrape -A | grep -i cnpg                                   # metrics scraped
   ```

2. Optional smoke test: delete the primary pod. Expect CNPG to promote a standby, then heal back to 3 instances.

Apps connect as the `app` role through the `<name>-rw` Service, with the credentials in the `<name>-app` Secret.

## Upgrade Postgres to a new major

1. Rehearse on a throwaway clone. It reads the catalog and archives nothing:

   ```bash
   make restore-cnpg   # --mode side --source <cluster>, then patch its imageName to the new major by hand
   ```

2. Bump `postgresVersion` in the workload values, then commit and push.
3. Watch the upgrade job and confirm the new major:

   ```bash
   kubectl -n <ns> get job -l cnpg.io/cluster=<cluster> -w      # <primary>-major-upgrade completes
   kubectl -n <ns> get cluster <cluster> -o jsonpath='{.status.pgDataImageInfo}{"\n"}'   # the new majorVersion
   ```

4. Run the extension script if `pg_upgrade` wrote one:

   ```bash
   kubectl -n <ns> exec <primary> -c postgres -- ls /var/lib/postgresql/data/pgdata/update_extensions.sql
   kubectl -n <ns> exec -i <primary> -c postgres -- psql -U postgres -d app -f <that path>
   ```

5. Rebuild the statistics. `pg_upgrade` carries none over:

   ```bash
   kubectl -n <ns> exec <primary> -c postgres -- psql -U postgres -d app -c 'ANALYZE'
   ```

6. Take a base backup into the new catalog before the 1h grace of `cnpg-no-recoverable-backup` runs out:

   ```bash
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

### Roll back a major upgrade

- The upgrade job still fails: set `postgresVersion` back. The operator deletes the job and starts the old major
  again. The data was never modified.
- The upgrade succeeded: `--link` shares inodes between the old and new data, so the old directory is not safe to
  run. Restore instead, with `restore.enabled: true` and `restore.serverName: <cluster>-pg<old major>`.
