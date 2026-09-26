# Storage and database

This step holds one storage layer, one database operator, and a shared chart for storage the cluster does not own.

- Longhorn and the CNPG operator are pure-GitOps wave-2 apps with no imperative script.
- Each needs one host prerequisite from the README: a dedicated filesystem, bind-mounted into the kubelet with
  `rshared`.

| Layer | Classes | Replicates at | Backs |
|---|---|---|---|
| [Longhorn](#longhorn) | `longhorn-r2-ephemeral`, `longhorn-r2-ephemeral-local`, `longhorn-r2-retained-with-backups` | the volume | everything: Postgres, RabbitMQ, Redis, the monitoring stores, ntfy |
| [External NFS](#external-nfs) | none, static PVs | nothing, the server does | storage that already exists off-cluster: a NAS share, a media library |

There is no default StorageClass. Every PVC names one, or it stays `Pending`. A static PV is the one exception. It
names `storageClassName: ""` and binds to a PV by name.

Per-node disk layout on the development cluster, set up by its node tooling: 64 GiB for the OS, then a dedicated
data volume that takes the rest of the disk.

## Why everything is on Longhorn, including the apps that replicate themselves

Postgres has streaming replication and RabbitMQ has Raft quorum queues. So replicating the block device under them
is redundant work. Node-local storage is still not used, and the reason is recovery, not performance.

A node-local PV is pinned to one machine. Replace or wipe that machine, and the PVC stays `Bound`, node-affine, and
pointing at an empty directory. Nothing resolves that on its own. An empty volume and a corrupt one look the same
from the outside. So no operator deletes a PVC that might hold the last copy of something. The pod crashloops until
a person deletes the PVC by hand:

- CNPG: `pg_controldata: exit status 1`, forever.
- RabbitMQ: `Ra could not create its data directory`, forever.

A script can do the delete. The cost is the time until someone notices, and nothing bounds that time. Until
someone looks:

- a 3-broker RabbitMQ runs at 2 of 3 with no spare. A second machine loss drops it below majority, and it stops
  accepting writes.
- a single-instance Postgres needs a full S3 restore, two git commits and a password roll.

On Longhorn the volume is not tied to the dead machine. The pod reattaches on a surviving node and comes back by
itself. Test: unplug the ethernet cable of one machine.

| Setup | Both databases serving again after |
|---|---|
| Longhorn | ~190s, unattended |
| Longhorn, [dead-node watcher](13_node_loss.md) suppressed | 402s |
| node-local storage | never |

Timings and the split-brain result are in [13_node_loss.md](13_node_loss.md).

The price is latency, and it is small. Both numbers are with a local replica:

| Metric | Node-local | Longhorn |
|---|---|---|
| Postgres commit p50 | 6.02 ms | 7.50 ms |
| RabbitMQ confirm p99 | 9.4 ms | 18.4 ms |

Both land inside what RDS Multi-AZ, Cloud SQL HA, SQS and Pub/Sub deliver. A managed service would not give these
milliseconds back either. Full tables are in [12_storage_bench.md](12_storage_bench.md).

## Longhorn

Longhorn is distributed block storage. It replicates each volume across nodes. Its data lives on the dedicated XFS
`longhorn` user volume, mounted at `/var/mnt/storage`.

Chart: `argo_apps/platform/charts/02_longhorn/`.

### V1 data engine, not V2/SPDK

- V2 (SPDK) has a known stuck-I/O bug on ARM64 with NVMe and 2 or more cores. The Pi 5 matches all three.
- V1 is also lighter on low-power nodes.
- Revisit if upstream fixes the bug.

### Host prerequisites

The README lists these, and they are set up outside this repo:

- `iscsid` and `fstrim` on every node.
- an NFSv4 client, if you use RWX volumes. Talos has the NFS client in-kernel, so it needs no extension. Longhorn
  reports it as the `NFSClientInstalled` condition on each `nodes.longhorn.io`.
- 4K kernel pages. XFS does not mount on 16K pages.
- the dedicated data volume.

Longhorn adds one thing: a kubelet bind-mount. On the Talos development cluster it looks like this:

```yaml
machine:
  kubelet:
    extraMounts:
      - destination: /var/mnt/storage
        type: bind
        source: /var/mnt/storage
        options: [ bind, rshared, rw ]
```

- A containerized kubelet does not propagate host mounts into itself. Without the bind, the Longhorn pods see an
  empty directory.
- `rshared` lets the per-replica sub-mounts propagate back to the host.
- If your kubelet runs on the host, not in a container, the mount only has to exist and be shared.

Your node config is the source of truth, so every rebuild gets the mount. On a live cluster, apply the same change
per node before the Longhorn app syncs. Otherwise the manager pods come up with the disk of every node
unschedulable.

### Values worth calling out

| Value | Why |
|---|---|
| `defaultDataPath: /var/mnt/storage` | the dedicated user volume, not the ephemeral `/var/lib/longhorn` |
| `defaultReplicaCount: 2` | `replicaSoftAntiAffinity` stays at its default `false`. That means hard anti-affinity, one replica per node |
| `persistence.defaultClass: false` | no cluster-default class. A PVC that names no class stays `Pending` |
| `storageMinimalAvailablePercentage: 15` | headroom on the Pi NVMes. Longhorn schedules nothing onto a disk under 15% free |
| `preUpgradeChecker.jobEnabled: false` | that Helm pre-upgrade hook Job can stall an Argo CD sync while it waits for completion |
| `networkPolicies.restrictInternalTraffic: false` | chart 1.12.1 turns it on by default, and the internal policies it gates ignore `networkPolicies.enabled`. See [below](#the-1121-network-policy-regression) |

Why 2 replicas and not one per node:

- 2 replicas survive the loss of one node, which is the design target.
- 2 replicas also leave at least one spare node to rebuild the lost replica onto.
- A count equal to the node count leaves no spare under hard anti-affinity. A volume then stays degraded until the
  dead node returns.

A new node does not take over existing replicas. `replica-auto-balance` stays at its default `disabled`. So a new
node holds no replicas until new volumes appear or a replica rebuilds. That is usually fine. Set
`replica-auto-balance: best-effort` to spread replicas over time.

### The 1.12.1 network policy regression

Chart `1.12.1` added `networkPolicies.restrictInternalTraffic` and set it to `true` by default. Six internal
NetworkPolicy templates check only that value. They ignore `networkPolicies.enabled`, so its `false` default does
not stop them. A patch bump from 1.12.0 applies these policies without anyone asking. On a CNI that enforces them,
two things break:

- `longhorn-manager:9500` stops accepting vmagent. Every `longhorn_*` series and every longhorn-health alert goes
  dark, including the alerts that would report this.
- The external CSI sidecars (`csi-attacher`, `csi-provisioner`, `csi-resizer`, `csi-snapshotter`) are separate
  Deployments. They are not on the allow-list of the manager, so volume attach and detach fail.

Upstream rates both as priority/0, and backported both fixes to 1.12.2:
[longhorn#13740](https://github.com/longhorn/longhorn/issues/13740) and
[longhorn#13802](https://github.com/longhorn/longhorn/issues/13802).

- Until 1.12.2, the values set `restrictInternalTraffic: false`. That matches the behaviour of 1.12.0.
- On 1.12.2, drop the line. Adopt the policies on purpose, with the metrics scraper and the CSI sidecars written
  into them.

The chart tarball for 1.12.1 is also gone:

- The GitHub release that held it was deleted. `charts.longhorn.io/index.yaml` still lists the version and points
  at the dead URL.
- The git tag survives, so the source is recoverable.
- `helm dependency build` on a cold cache cannot resolve 1.12.1. A repo-server that already has the chart cached
  keeps working. One without it cannot render this app. Nothing in this repo fixes that.
- A pin back to 1.12.0 would fix the fetch, but Longhorn does not support downgrades. So the plan is to stay on
  1.12.1 and take 1.12.2 when it ships.

### The three StorageClasses

`templates/storageclasses.yaml` renders them, all with `numberOfReplicas: 2`.

| Class | reclaimPolicy | dataLocality | S3 backup | Use for |
|---|---|---|---|---|
| `longhorn-r2-ephemeral` | Delete | disabled | none | the general-purpose tier |
| `longhorn-r2-ephemeral-local` | Delete | best-effort | none | small volumes where write latency matters: RabbitMQ |
| `longhorn-r2-retained-with-backups` | Retain | disabled | daily and weekly | data you cannot lose and that has no app-level backup (sqlite, config). No consumer yet |

The `-with-backups` class adds off-cluster S3 backups through `recurringJobSelector`. See
[10_backups.md](10_backups.md).

**`dataLocality: best-effort`** keeps one of the two replicas on the node that runs the pod. Reads and half the write
path stay on that SSD.

- It takes 31% off the RabbitMQ confirm p99, and only 4% off Postgres. A durable Postgres write has to reach both
  replicas either way.
- The catch: Longhorn pulls a full local copy along on every reschedule.
- So it suits a queue whose consumers keep it near-empty. It does not suit a database that can grow, which would
  cross 1GbE in full on every failover.

**Sizes are ceilings, not reservations.** Longhorn is thin, so a volume occupies only what has been written to it.
The spec size does count against the per-node scheduling budget of Longhorn, at the full number. The >90%-full
alert also measures against it. So set a real ceiling, not a generous one.

A weekly `filesystem-trim` RecurringJob (`templates/recurringjobs.yaml`) returns blocks that the filesystem has
freed. This keeps a thin volume thin.

- It reaches every volume through the Longhorn `default` group. Longhorn puts every volume with no recurring job of
  its own into that group.
- It replaces mounting with `discard`. `discard` would put reclaim inline in the write path, on a consumer NVMe
  whose tail latency is already the weak point.
- It reclaims real space for RabbitMQ, which deletes segments once they are consumed. It reclaims very little for
  Postgres, which reuses pages internally and recycles WAL by rename.

The `parameters` of a StorageClass are immutable. To add a key to an existing class, delete the class by hand
first. Otherwise Argo CD reports the sync failure forever.

**Why there is no plain Retain class**:

- Every stateful app stamps `deletionProtection` (`Prune=false,Delete=false`) on the CR or PVC that owns its
  storage.
- So a prune cannot delete the object. Restoring the files brings it back with zero loss, and nothing is ever
  `Released`.
- `Retain` then protects only against a deliberate deletion, and leaks orphaned PVs.
- So everything uses a Delete class. Regretting a deliberate delete costs the backup RPO of that store.
- The one exception is `longhorn-r2-retained-with-backups`, for data with no app-level backup at all. It is also
  the restore target of `recover_longhorn_from_s3.sh`.

### RWX is a PVC choice, not a class

There is no RWX class, and there should not be one. The PVC sets the access mode of a dynamically provisioned
volume. `accessModes: [ReadWriteMany]` against any class above gets an RWX volume. `ReadWriteOnce` against the same
class gets a plain block device. A class that pinned RWX would force NFS on single-writer volumes too.

For RWX, Longhorn starts a share-manager pod that runs nfs-ganesha. Every consumer mounts that share instead of
attaching a block device. Three results:

- **One pod per volume**: the share-manager is a single point of failure per volume. `rwxVolumeFastFailover` in
  `values.yaml` leases it. That shortens the outage but does not remove it.
- **Two network hops**: every IO crosses the 1GbE network twice, consumer to share-manager, then share-manager to
  replicas. Use RWX when the sharing is the point, not for convenience.
- **No `longhorn-r2-ephemeral-local`**: `dataLocality` is relative to the share-manager pod, not the consumers. For
  an RWX PVC it buys nothing and still pulls a copy along on reschedule.

The mount options are the Longhorn defaults: NFSv4.1 with `softerr,timeo=600,retrans=5`. If concurrent writers
hang, the Longhorn KB blames NFSv4.1+ state handling. The fix is
`nfsOptions: "vers=4.0,noresvport,softerr,timeo=600,retrans=5"` on a new class, because `parameters` cannot be
edited in place.

### Operational notes

- **Privileged Pod Security**: Talos enforces `baseline`. So the Application stamps
  `pod-security.kubernetes.io/enforce: privileged` on `longhorn-system` through `managedNamespaceMetadata`.
- **`ServerSideApply`**: the CRDs are over the size limit of the client-side last-applied annotation.
- **Metrics**: `metrics.serviceMonitor.enabled: true` feeds `longhorn_*` to the stack. That drives the
  `longhorn-health` Grafana alerts: manager down, node NotReady, disk unschedulable, node storage over 85%, volume
  degraded or faulted, volume near full. See [06_monitoring.md](06_monitoring.md).
- **`OutOfSync` flapping**: Longhorn mutates some of its own objects, such as its StorageClass or a webhook config.
  If such a field flaps `OutOfSync` after the first sync, add a targeted `ignoreDifferences`. Do not fight
  `selfHeal`.
- **Teardown**: deleting the app or its CRDs destroys the volumes. Back up before any teardown.

### Verify

```bash
talosctl -n 192.168.10.201 read /proc/mounts | grep storage    # /var/mnt/storage present, after the patch
kubectl -n longhorn-system get pods                            # manager on all 3 nodes, and CSI, Running
kubectl -n longhorn-system get nodes.longhorn.io -o wide       # the disk of each node Schedulable
kubectl get storageclass                                       # the three longhorn-r2-* classes, no default
kubectl -n longhorn-system get recurringjob                    # filesystem-trim-weekly, and the backup jobs
```

Smoke test:

1. Apply a 1Gi PVC with `storageClassName: longhorn-r2-ephemeral`, and a pod that mounts it.
2. Check that the PVC goes `Bound`.
3. Check that the volume shows 2 healthy replicas on two different nodes.

## External NFS

For storage that already exists on an NFS server and that this cluster does not own: a NAS share, a media library,
an archive that somebody else fills. Longhorn is for data the cluster creates. This is for data the cluster only
reads or visits.

Chart: `lib/helm/nfs-volume/`. It is a shared chart, used as a `file://` dependency like the other four. It has no
Argo Application of its own and installs nothing. It does nothing until a workload declares it and fills in
`volumes[]`.

Each entry renders two objects:

- a **PersistentVolume** with an in-tree `nfs:` source, `storageClassName: ""`, and a `claimRef`. The `claimRef`
  pre-binds the PV to one namespace and one claim name.
- the **PersistentVolumeClaim** that names the PV back with `volumeName`.

The `claimRef` has a job. Without it, any PVC whose request the PV satisfies can win the bind first. The intended
claim then sits `Pending` behind a stranger. With both ends named, only the intended pairing can bind.

Nothing else is involved: no StorageClass, no CSI driver, no dynamic provisioning. The kubelet mounts the export
with the kernel NFS client of the node. The Longhorn RWX volumes use the same client.

### Why the in-tree plugin and not csi-driver-nfs

`csi-driver-nfs` is the maintained driver, and it does more: dynamic provisioning, snapshots, class-level mount
options. None of that applies here.

- Dynamic provisioning creates a fresh `pvc-<uuid>` directory per claim. The point here is to mount a directory
  that already exists, under a name a person chose.
- The driver also works for static PVs. It then costs a DaemonSet and a controller for a result the kubelet already
  gives for free.

The in-tree NFS plugin is frozen, not deprecated. Kubernetes plans no CSI migration for it, and nothing removes it.
A later switch means rewriting the PV and restarting the pods. The data stays where it is.

### Capacity and reclaim policy

`capacity` is required, and nothing enforces it:

- NFS reports no size to the kubelet, and no quota applies.
- A pod can fill the disk of the server through a 1Gi PV.
- The field exists because the API demands a number, and the PVC request must match it for the bind.

Put a plausible number in it. Do not treat it as a limit.

`reclaimPolicy` defaults to `Retain`. `Delete` is available but reclaims nothing real. On an NFS PV it deletes the
PV object and leaves every byte on the server.

### hard or softerr, and why there is no right default

`mountOptions` defaults to `nfsvers=4.1, hard, noatime`. That default takes a side:

| | `hard` | `softerr,timeo=600,retrans=5` |
|---|---|---|
| Server goes away | IO blocks until it returns | IO returns EIO after a few minutes |
| Server returns | IO resumes where it stopped, nothing lost | the app already saw an error |
| Cost | the pod blocks in uninterruptible sleep. SIGKILL does not land, and the kubelet can fail to tear the pod down | a write in flight when the server dropped can be torn |

- `hard` is the default because silent corruption is worse than a stuck pod. NFS itself also defaults to `hard`.
- A consumer that prefers the error to the stuck pod sets the other options explicitly. Longhorn makes that same
  choice for its own RWX volumes.

### Permissions

Under AUTH_SYS the uid of the pod crosses the wire unchanged. So the export must be writable by the uid the pods
run as. Or the server must squash that uid to one that can write. The usual symptom of a mismatch: the mount
succeeds, then every write fails. No Kubernetes YAML fixes it.

One trap is specific to NFS:

- The Longhorn CSIDriver declares `fsGroupPolicy: ReadWriteOnceWithFSType`. So the kubelet skips `fsGroup` on
  Longhorn RWX volumes.
- An in-tree NFS volume has no CSIDriver object. So the kubelet applies `fsGroup` itself and chowns the whole mount
  recursively.
- On a large export, the pod start then never finishes.

Pick one fix:

- set no `fsGroup` on pods that mount these volumes.
- keep `fsGroupChangePolicy: OnRootMismatch`, and give the export root the right ownership up front. The kubelet
  then skips the walk.

### No policy rule, and no metrics

The kubelet mounts the export in the host network namespace and bind-mounts the result into the pod. So the NFS
traffic never belongs to the pod. No `CiliumNetworkPolicy` sees it, and none needs a rule for it.

The other side: nothing in the monitoring stack knows this volume exists. There are no Longhorn metrics, no replica
health and no capacity series. So no alert fires when the server disappears. A blackbox TCP probe against port
2049 on the server is the cheapest way to get that back. `05_blackbox_exporter` takes any target in a probe group.

### Verify

```bash
kubectl get pv                                # Bound, with the right CLAIM and RECLAIM POLICY
kubectl -n <ns> get pvc                       # Bound, not Pending
kubectl -n <ns> exec <pod> -- sh -c 'mount | grep nfs; id; ls -lan <mountPath>'
```

- The `mount` line shows the NFS version and the options that took effect. These are not always what the PV asked
  for.
- Files owned by `nobody` or `65534`, not a real numeric uid, mean the server translates identities. Reads still
  work. Writes do not.

## CloudNativePG

[CNPG](https://cloudnative-pg.io) turns a declarative `Cluster` CR into an HA Postgres: a primary and streaming
replicas, with failover, rolling updates and metrics. It runs as two apps, one in each tree, so the operator lands
before the database. See [`02_gitops.md`](02_gitops.md).

| App | Tree | What |
|-----|------|------|
| `cnpg-operator` (`platform/charts/02_cnpg_operator`) | platform, wave 2 | the controller and its CRDs. Nothing else in wave 2 depends on it |
| `sample-user-manager` (`workloads/charts/sample_user_manager`) | workloads, no wave | two Postgres `Cluster`s on the `longhorn-r2-ephemeral` class |

Workloads carry no `sync-wave`. The root-of-roots creates the workloads tree about 5s after the platform tree,
with no health gate. So a `Cluster` CR applied before its CRD registers fails its sync. It retries until the
operator lands. See [`02_gitops.md`](02_gitops.md).

Versions:

- The operator dependency `cnpg/cloudnative-pg` sits in `02_cnpg_operator/Chart.yaml`.
- The `Cluster` comes from the shared `pg-cluster` chart (`lib/helm/pg-cluster`). It renders the CNPG CRs directly,
  with no upstream chart, and pins the `ghcr.io/cloudnative-pg/postgresql` image itself.
- Postgres only, no postgis. Multi-arch, arm64 included.

A workload declares `pg-cluster` as an aliased `file://` dependency, once per database. The alias is the values
key, and the knobs sit flat under it.

### Storage and what a node loss costs

`longhorn-r2-ephemeral`, `dataLocality: disabled`. Not the `-local` variant. That would buy 4% and pay for it by
moving the whole database across 1GbE on every failover. The reason for Longhorn at all is
[above](#why-everything-is-on-longhorn-including-the-apps-that-replicate-themselves).

Two independent layers of redundancy each cover a different failure:

| Layer | Covers |
|---|---|
| Postgres replication (`highAvailability: true`) | the primary dying. A standby is already caught up and gets promoted. Measured: ~97s of write unavailability |
| Longhorn's 2 replicas | the node of the volume dying. The volume reattaches elsewhere with its data intact |

So a machine loss is uneventful either way:

- **`highAvailability: true`**: 3 instances, one per node. One dies, a standby is promoted, writes continue. With
  only 3 machines, the third instance has nowhere to go. It stays Pending until the machine returns.
- **`highAvailability: false`**: the single instance moves to a surviving node with its volume and restarts there.
  Crash recovery replays WAL, as after a `kill -9` on any Postgres. No S3 restore.

### Operator values

- `crds.create: true`.
- `monitoring.podMonitorEnabled: true`.
- modest `resources`, because the operator only reconciles.
- `INHERITED_LABELS: alert-criticality`, so the label reaches the Postgres pods for the outage alerts.

The operator pod carries a pod-scoped `CiliumNetworkPolicy`. In: vmagent metrics, the apiserver webhook, the
kubelet probe. Out: DNS, the apiserver, the instance-manager of each instance, the barman-cloud plugin. See
[01_networking.md](01_networking.md).

### Cluster values

The `pg-cluster` chart bakes in most settings. A workload sets only these:

| Knob | Required | Notes |
|---|---|---|
| `name` | yes | used as-is: the Cluster, its `<name>-rw`/`-ro`/`-r` Services, the `<name>-app` Secret |
| `postgresVersion` | yes | a major version, and a key into the pinned image map of the chart. A change is an upgrade, see below |
| `highAvailability` | yes | one bool. true: 3 instances, synchronous `any 1`, PDB, switchover. false: 1 instance, no sync, PDB off, in-place restart |
| `size` | yes | per-instance disk ceiling. Thin, so it reserves nothing, but it spends the Longhorn scheduling budget |
| `resources` | yes | per instance, no default. A forced choice on a Pi |
| `allowedClients` | yes | who may open 5432. Also drives the client-side egress policy |
| `deletionProtection` | yes | one bool, no default. The only guard between a stray prune and lost data |
| `alertCritical` | no | stamps `alert-criticality`, so a crashloop pages as critical, not warning |

Baked into the chart, worth knowing:

- **`affinity.topologyKey: kubernetes.io/hostname` with `podAntiAffinityType: required`**: the upstream default
  spreads by `topology.kubernetes.io/zone`. Bare Pi nodes carry no zone label, so every instance could land on one
  node. `required` refuses to place two instances on one node, where `preferred` only avoids it. So a machine loss
  never takes two at once. The price: with 3 machines and one down, the third instance waits and does not double
  up.
- **`postgresql.synchronous: {method: any, number: 1, dataDurability: required}`, only with `highAvailability`**:
  a commit waits until one of the two standbys has flushed it. So a promoted standby never misses a transaction
  that the application saw as committed.
  - `required`: if no standby can acknowledge, writes stall. They do not silently fall back to asynchronous.
    `preferred` would quietly reopen that gap.
  - With 3 instances, one of two standbys still acknowledges while one node drains. That keeps a rolling Talos
    upgrade safe.
  - Measured cost: about 2 ms on commit p99.
- **One bool, not three knobs**: 3 instances and synchronous replication always go together. 1 instance has no
  standby to be synchronous with. 2 instances, and more than 3, are out of scope.
- **`postgresql.parameters`**: sized for the Pi 5s. A workload can override them.
- **`initdb: { database: app, owner: app }`**: the operator generates the owner credentials into the `<name>-app`
  Secret. No sealed secret is needed.
- **No CNPG alert rules from the chart**: `vmalert` is off, so a VMRule would never fire. The CNPG backup and
  operational alerts are Grafana rules. See [10_backups.md](10_backups.md).

### Major version upgrade

Bump `postgresVersion` to the next major and merge. That is the whole change:

- The operator sees a higher major in `imageName` and runs an offline in-place `pg_upgrade --link` itself.
- In the same render, the chart moves the backup catalog to `<name>-pg<major>`. That keeps the old catalog
  restorable.

The costs, before you start:

- **Downtime**: the whole database, replicas included, is down for as long as `pg_upgrade` takes. A few minutes
  for a small database. On a large one, re-cloning the replicas afterwards is the slow part.
- **No PITR across the boundary**: the pre-upgrade catalog can only restore to a pre-upgrade point, forever.
- **Extensions**: yours to check. The operator does not touch them.
- **Same OS distribution only**: for example trixie to trixie. `files/postgres-images.yaml` holds one distribution
  only. So this limits edits to that file, not a bump.

```bash
# 1. rehearse on a throwaway clone first. It reads the catalog and archives nothing
make restore-cnpg   # --mode side --source <cluster>, then patch its imageName to the new major by hand

# 2. the real upgrade: merge the postgresVersion bump, then watch
kubectl -n <ns> get job -l cnpg.io/cluster=<cluster> -w      # <primary>-major-upgrade
kubectl -n <ns> get cluster <cluster> -o jsonpath='{.status.pgDataImageInfo}{"\n"}'   # majorVersion is the proof

# 3. extensions, if pg_upgrade wrote a script for them
kubectl -n <ns> exec <primary> -c postgres -- ls /var/lib/postgresql/data/pgdata/update_extensions.sql
kubectl -n <ns> exec -i <primary> -c postgres -- psql -U postgres -d app -f <that path>

# 4. statistics: pg_upgrade carries none over, so the first queries plan without any
kubectl -n <ns> exec <primary> -c postgres -- psql -U postgres -d app -c 'ANALYZE'

# 5. base backup into the new prefix, before the 1h grace of cnpg-no-recoverable-backup runs out
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

Rollback depends on whether the upgrade worked:

- **Job still failing**: set `postgresVersion` back. The operator deletes the job and starts on the old major
  again. The catalog follows back to the old prefix. The data was never modified.
- **Upgrade succeeded**: `--link` left the old directory sharing inodes with the new one, so it is not safe to run
  again. Go back by restore instead: `restore.enabled: true` with `restore.serverName: <cluster>-pg<old major>`.

### Reclaim and durability

`longhorn-r2-ephemeral` is `reclaimPolicy: Delete`. Data safety does not rest on Retain:

- **Orphan-not-delete** protects the database unit from a GitOps prune. `Prune=false,Delete=false` sits on the
  Cluster and on its ObjectStore, ScheduledBackup, PodMonitor, NetworkPolicy and S3-creds SealedSecret.
- Removing a workload from git leaves its `Cluster` and PVCs running. Restoring the files re-adopts them with no
  data movement.

Two durability tiers:

1. **In-cluster**: Postgres replication across the instances, the 2 Longhorn volume replicas under them, and
   orphan-not-delete.
2. **Off-cluster**: S3 backups through the `cnpg/plugin-barman-cloud` plugin. Continuous WAL archiving and daily
   base backups give real PITR and total-loss recovery. `10b_cnpg_backup.sh` turns them on from `.env`. See
   [10_backups.md](10_backups.md).

Neither namespace needs privileged PSA. The controller and Postgres pods run as non-root, uid 26. Both apps use
SSA, because the CRDs and the `Cluster` CR are over the client-side annotation limit.

### Verify

```bash
helm dependency build argo_apps/platform/charts/02_cnpg_operator
export KUBECONFIG=.cache/kubeconfig                                          # written by use_kubeconfig
kubectl -n cnpg-system rollout status deploy/cnpg-operator-cloudnative-pg   # operator Healthy (platform)
kubectl -n sample-user-manager get pods -o wide                             # 3 instances Running, distinct nodes
kubectl -n sample-user-manager get pvc -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName  # longhorn-r2-*
kubectl -n sample-user-manager exec sample-user-manager-db-1 -- \
  psql -U postgres -tAc 'show synchronous_standby_names'                   # non-empty on the HA cluster
kubectl get vmpodscrape -A | grep -i cnpg                                   # metrics wired into VictoriaMetrics
```

Smoke test:

1. Delete the primary pod, `sample-user-manager-db-1`.
2. Watch CNPG promote a standby, then heal back to 3.

The credentials of the `app` role live in the generated `sample-user-manager-db-app` Secret. Connect through the
`sample-user-manager-db-rw` Service.
