# 08: Storage & database

Two storage layers and a database operator, all pure-GitOps wave-2 leaves with no imperative script. Each needs
one Talos host prerequisite from [`03_operating_system.md`](03_operating_system.md).

| Layer | Class | Replicates at | Backs |
|---|---|---|---|
| [Longhorn](#longhorn) | `longhorn-r2-ephemeral`, `longhorn-r2-retained-with-backups` | the volume | Redis, the monitoring stores, ntfy |
| [local-path-provisioner](#local-path-provisioner) | `local-path`, `local-path-ephemeral` | the app | [CloudNativePG](#cloudnativepg), RabbitMQ |

There is **no default StorageClass**. Every PVC names one, or it stays `Pending`.

Per-node NVMe layout, carved by [`03d`](03_operating_system.md): EPHEMERAL 64 GiB, then a fixed 50 GiB
`localpath` slice, then `longhorn` takes the remainder.

## Longhorn

Distributed block storage that replicates each volume across nodes, on the dedicated XFS `longhorn` user volume
mounted at `/var/mnt/longhorn`.

Chart: `argo_apps/platform/charts/02_longhorn/`.

### V1 data engine, not V2/SPDK

V2 (SPDK) has a known stuck-I/O bug on ARM64 + NVMe with 2+ cores, which is exactly the Pi 5. V1 is also lighter
on low-power nodes. Revisit if upstream fixes it.

### Talos prerequisites

From step 03: the `iscsi-tools` and `util-linux-tools` extensions, 4K kernel pages (XFS will not mount on 16K),
and the `/var/mnt/longhorn` XFS volume. Longhorn adds one thing, a kubelet bind-mount in `03d`'s `cp-patch.yaml`:

```yaml
machine:
  kubelet:
    extraMounts:
      - destination: /var/mnt/longhorn
        type: bind
        source: /var/mnt/longhorn
        options: [ bind, rshared, rw ]
```

Talos runs the kubelet in a container and does not auto-propagate host mounts under `/var/mnt` into it, so
without the bind Longhorn's pods see an empty directory. `rshared` is required so per-replica sub-mounts
propagate back to the host, matching Longhorn's own Talos guidance.

`03d` is the source of truth, so any rebuild gets it. On a live cluster apply just this patch per node
(`talosctl patch machineconfig ... --mode=auto`) BEFORE the Longhorn app syncs, or the manager pods come up with
every node's disk unschedulable.

### Values worth calling out

| Value | Why |
|---|---|
| `defaultDataPath: /var/mnt/longhorn` | the dedicated user volume, not the ephemeral `/var/lib/longhorn` |
| `defaultReplicaCount: 2` | with `replicaSoftAntiAffinity` at its default `false`, so hard anti-affinity, one replica per node |
| `persistence.defaultClass: false` | no cluster-default class; a PVC that omits one stays `Pending` |
| `storageMinimalAvailablePercentage: 15` | headroom on the Pi NVMes; do not schedule onto a disk under 15% free |
| `preUpgradeChecker.jobEnabled: false` | that Helm pre-upgrade hook Job can stall an ArgoCD sync waiting on completion |

Why 2 replicas and not 3: 2 on 3 nodes survives the single node loss we design for AND leaves a spare node to
rebuild the lost replica onto. At 3 replicas with hard anti-affinity there is no spare, so a volume stays
degraded until the dead node returns.

### The two StorageClasses

Rendered by `templates/storageclasses.yaml`, both `numberOfReplicas: 2`. They differ only in off-cluster backup.

| Class | reclaimPolicy | S3 backup | Use for |
|---|---|---|---|
| `longhorn-r2-ephemeral` | Delete | none | the general-purpose tier, and the only one in use |
| `longhorn-r2-retained-with-backups` | Retain | daily + weekly | precious data with no app-level backup (sqlite, config) |

The `-with-backups` class adds off-cluster S3 backups via `recurringJobSelector`; see
[13_backups.md](13_backups.md).

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
  volume near-full. See [09_monitoring.md](09_monitoring.md).
- If a Longhorn-managed field flaps `OutOfSync` after first sync (it mutates its own StorageClass or a webhook
  config), add a targeted `ignoreDifferences` rather than fighting `selfHeal`.
- Deliberately deleting the app or its CRDs destroys the volumes. Back up before any teardown.

### Verify

```bash
talosctl -n 192.168.10.201 read /proc/mounts | grep longhorn   # /var/mnt/longhorn present (after the patch)
kubectl -n longhorn-system get pods                            # manager on all 3 nodes + CSI Running
kubectl -n longhorn-system get nodes.longhorn.io -o wide       # each node's disk Schedulable
kubectl get storageclass                                       # the two longhorn-r2-* classes, NO default
```

Smoke test: apply a 1Gi PVC with `storageClassName: longhorn-r2-ephemeral` plus a pod, confirm it goes `Bound`
and the volume shows 2 healthy replicas on two distinct nodes.

## local-path-provisioner

Longhorn is the wrong layer for anything that already replicates itself. Postgres has streaming replication and
RabbitMQ has Raft quorum queues, so replicated block storage underneath is redundant work: write amplification,
the Longhorn engine and CSI in the hot path, and the app competing with Longhorn for one big XFS partition.

local-path gives them node-local storage on a dedicated partition, so the app layer is the only replication
layer.

### Why local-path, not TopoLVM or OpenEBS-LVM

The capacity-awareness and PVC-size enforcement those buy would do nothing for us: hostname anti-affinity puts one
CNPG instance per node on a dedicated 50 GiB partition, so there is nothing to overcommit and a runaway DB is
already bounded to that partition. LVM provisioners also need a raw block device for a volume group plus an
`lvmd` daemon, which is awkward on Talos' shell-less immutable OS.

local-path is a single Deployment that creates a directory per PV.

The trade: it does **not** reserve or enforce the PVC `size` (thin, grow-on-write), so a runaway DB can fill the
50 GiB partition. Contained to that partition, and CNPG's disk-usage alerts cover it. Real reservation plus
online auto-grow would be the signal to revisit TopoLVM.

### WaitForFirstConsumer is mandatory

For true node-local storage the volume physically exists on only one node, so the scheduler must place the pod
first (honoring CNPG's `kubernetes.io/hostname` anti-affinity) and then provision the volume wherever it landed.
`Immediate` is fine for network-reachable CSI like Longhorn but wrong here: it would bind a PV to an arbitrary
node before the pod is scheduled.

### Talos prerequisite

Two things from [`03d`](03_operating_system.md): the fixed-size XFS volume at `/var/mnt/localpath` (50 GiB,
`min == max` so it cannot grow into Longhorn's space), and a kubelet bind-mount of it in `cp-patch.yaml`. Same
reason as Longhorn, but plain `[bind, rw]` suffices, since there are no per-replica sub-mounts to propagate.

### Vendored, not a dependency pin

There is no usable public Helm repo (Rancher's registry is auth-gated, which breaks ArgoCD's repo-server; the
community mirror is stale), so the chart vendors the upstream manifests under `templates/`, parameterized from
`values.yaml` and pinned to `appVersion`. No `Chart.lock`, nothing to resolve.

To bump: edit `image.tag` and `helperImage.tag` plus `appVersion`, then re-diff `templates/` against the upstream
`deploy/local-path-storage.yaml` at the new tag.

### Config worth calling out

- `dataPath: /var/mnt/localpath`, node-local via the `DEFAULT_PATH_FOR_NON_LISTED_NODES` catch-all, so every node
  uses this path on its own disk. Shared by both classes: RabbitMQ's quorum-log volumes co-tenant the 50 GiB
  slice with Postgres. They are tiny, so this is accepted. See [11_messaging.md](11_messaging.md).
- `storageClasses`: two classes on the one provisioner, both `defaultClass: false`, both
  `WaitForFirstConsumer`, both `reclaimPolicy: Delete`. `local-path` for CNPG, `local-path-ephemeral` for
  RabbitMQ.
- `helperImage` pinned for reproducibility.

CNPG does not need Retain: its data is protected from a GitOps prune by orphan-not-delete, and Delete auto-cleans
a per-volume dir on a legitimate PVC delete (replica scale-down, intentional cluster delete) rather than leaking
it on the shared slice.

### Privileged PSA required

The provisioner itself runs unprivileged, but the short-lived helper pods it stamps out to mkdir and rm
per-volume dirs mount the node data path as a `hostPath`, which Talos' `baseline` default forbids.
`managedNamespaceMetadata` labels `local-path-storage` privileged; without it the helper pods are rejected at
admission and PVC provisioning fails. No CRDs, so no SSA needed.

### Verify

```bash
helm template argo_apps/platform/charts/02_local_path_provisioner   # Deployment + 2 SCs + RBAC + ConfigMap
export KUBECONFIG=secrets/kubeconfig
talosctl -n 192.168.10.201 get volumestatus | grep -E 'localpath|longhorn'  # u-localpath (50GiB) + u-longhorn
talosctl -n 192.168.10.201 read /proc/mounts | grep /var/mnt/localpath      # mounted + visible to the kubelet
kubectl -n local-path-storage get pods                                 # provisioner Running
kubectl get sc local-path -o jsonpath='{.volumeBindingMode}'; echo     # == WaitForFirstConsumer
```

## CloudNativePG

[CNPG](https://cloudnative-pg.io) reconciles a declarative `Cluster` CR into an HA Postgres: primary plus
streaming replicas, with failover, rolling updates and metrics. Two apps, split across the two trees so operator
and database land in dependency order (see [`05_gitops.md`](05_gitops.md)):

| App | Tree | What |
|-----|------|------|
| `cnpg-operator` (`platform/charts/02_cnpg_operator`) | platform, wave 2 | the controller + its CRDs, an independent leaf |
| `sample-user-manager` (`workloads/charts/sample_user_manager`) | workloads, no wave | two Postgres `Cluster`s on the `local-path` class |

Workloads carry no `sync-wave`. The root-of-roots creates the workloads tree about 5s after the platform tree
with no health gate, so a `Cluster` CR applied before its CRD registers fails its sync and retries until the
operator lands. See [`05_gitops.md`](05_gitops.md).

Versions: the operator dep `cnpg/cloudnative-pg` in `02_cnpg_operator/Chart.yaml`; the `Cluster` comes via the
shared `pg-cluster` wrapper (`lib/helm/pg-cluster`), which renders the CNPG CRs directly with no upstream chart
and pins the `ghcr.io/cloudnative-pg/postgresql` image itself. Postgres only, no postgis. Multi-arch incl. arm64.

A workload declares `pg-cluster` as an **aliased** `file://` dependency, once per database, so the alias is the
values key and its knobs sit flat under it.

### Storage: node-local, off Longhorn

CNPG runs on `local-path`, on the dedicated 50 GiB partition, so there is no Longhorn engine or CSI in the
Postgres data path and the two cannot starve each other. Postgres streaming replication is the only replication
layer: an HA cluster survives a node loss, because CNPG promotes the surviving instance and re-clones the lost
one from it. Full reasoning in [local-path-provisioner](#local-path-provisioner).

That re-clone is not automatic when the node comes BACK under the same name. A reflash empties the directory
but leaves the PVC Bound, and CNPG will not destroy a PVC that might still hold data, so the instance
crashloops on `pg_controldata: exit status 1` until you delete the PVC yourself. Runbook in
[15_node_recovery.md](15_node_recovery.md).

### Operator values

`crds.create: true`, `monitoring.podMonitorEnabled: true`, modest `resources` (it only reconciles), and
`INHERITED_LABELS: alert-criticality` so the label reaches the Postgres pods for the outage alerts.

The operator pod carries a pod-scoped `CiliumNetworkPolicy`: in from vmagent metrics, the apiserver webhook and
the kubelet probe; out to DNS, the apiserver, each instance's instance-manager, and the barman-cloud plugin. See
[04_networking.md](04_networking.md).

### Cluster values

Most of the tree is pre-baked in the `pg-cluster` wrapper. A workload sets only these:

| Knob | Required | Notes |
|---|---|---|
| `name` | yes | used verbatim: the Cluster, its `<name>-rw`/`-ro`/`-r` Services, the `<name>-app` Secret |
| `postgresVersion` | yes | a MAJOR, and a key into the wrapper's pinned image map |
| `highAvailability` | yes | one bool: true = 2 instances + PDB + switchover, false = 1 instance, PDB off, in-place restart |
| `resources` | yes | per-instance, no default; forced choice on a Pi |
| `allowedClients` | yes | who may open 5432; also drives the client-side egress policy |
| `deletionProtection` | yes | one bool, no default; the only thing between a stray prune and gone data |
| `alertCritical` | no | stamps `alert-criticality`, so a crashloop pages critical rather than warning |

Wrapper-baked, worth knowing:

- `affinity.topologyKey: kubernetes.io/hostname`. The chart default spreads by
  `topology.kubernetes.io/zone`, but bare Pi nodes carry no zone label, so both instances could land on one
  node. Spreading by hostname forces distinct nodes, which is the node-loss HA that node-local storage relies on.
- `storage.size: 45Gi` is a no-op under local-path (Postgres sees the whole partition via `statfs`) but the CR
  requires it, so it is set to the honest partition budget in case the class is ever swapped.
- `postgresql.parameters` sized for the Pi 5s, overridable per workload.
- `initdb: { database: app, owner: app }`. The operator auto-generates the owner's credentials into the
  `<name>-app` Secret, so no sealed secret is needed.
- The chart's own CNPG alert rules are disabled: `vmalert` is off, so a VMRule would never fire. The CNPG backup
  and operational alerts are Grafana rules instead. See [13_backups.md](13_backups.md).

### Reclaim & durability

`local-path` is `reclaimPolicy: Delete`. Data safety does not rest on Retain: the DB unit is protected from a
GitOps prune by orphan-not-delete (`Prune=false,Delete=false` on the Cluster plus its ObjectStore,
ScheduledBackup, PodMonitor, NetworkPolicy and S3-creds SealedSecret). Removing a workload from git leaves its
`Cluster` and PVCs running, and restoring the files re-adopts them with no data movement.

Two durability tiers:

1. **In-cluster**: Postgres replication across the instances, plus orphan-not-delete.
2. **Off-cluster**: S3 backups, continuous WAL archiving plus daily base backups via the
   `cnpg/plugin-barman-cloud` plugin, for real PITR and total-loss recovery. Turned on from `.env` by
   `14_cnpg_backup.sh`. See [13_backups.md](13_backups.md).

Neither namespace needs privileged PSA: controller and Postgres pods run non-root (uid 26). Both apps use SSA,
because the CRDs and the `Cluster` CR blow the client-side annotation limit.

### Verify

```bash
helm dependency build argo_apps/platform/charts/02_cnpg_operator
export KUBECONFIG=secrets/kubeconfig
kubectl -n cnpg-system rollout status deploy/cnpg-operator-cloudnative-pg   # operator Healthy (platform)
kubectl -n sample-user-manager get pods -o wide                             # 2 instances Running, distinct nodes
kubectl -n sample-user-manager get pvc -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName  # local-path
kubectl get vmpodscrape -A | grep -i cnpg                                   # metrics wired into VictoriaMetrics
```

Smoke test: delete the primary pod (`sample-user-manager-db-1`) and watch CNPG promote the replica, then heal
back to 2. The `app` role's credentials live in the auto-generated `sample-user-manager-db-app` Secret; connect
via the `sample-user-manager-db-rw` Service.
