# 08: Storage & database

The cluster ships two storage classes and a database operator. [Longhorn](#longhorn) is the
distributed, replicated default `StorageClass` for general PVCs; [local-path-provisioner](#local-path-provisioner)
is a node-local class for [CloudNativePG](#cloudnativepg), whose Postgres already replicates at the DB layer
so a replicated block store underneath would be redundant. All three are pure-GitOps wave-2 leaves (no
imperative script); each needs one Talos host prerequisite that lives in [`03_operating_system.md`](03_operating_system.md).

## Longhorn

[Longhorn](https://longhorn.io) is cloud-native distributed block storage that replicates each volume across
nodes. It's the cluster's default `StorageClass` (nothing stateful could claim a PVC before it), wired to the
dedicated XFS `longhorn` user volume that [`03d`](03_operating_system.md) carves out of each NVMe (the remainder
after the 64 GiB EPHEMERAL cap and the fixed 50 GiB `cnpg` slice), mounted at `/var/mnt/longhorn`.

Wrapper chart: `argo_apps/platform/charts/02_longhorn/` (`Chart.yaml` pins `1.12.0`, all config under the
`longhorn:` key in `values.yaml`).

**V1 data engine (not V2/SPDK).** Longhorn's V2 (SPDK) engine has a known stuck-I/O bug on ARM64 + NVMe with
2+ cores, which is exactly the Pi 5. Stay on the default V1 engine (lighter on low-power nodes anyway); revisit
if the upstream issue is fixed.

**Talos prerequisites.** The `iscsi-tools`/`util-linux-tools` extensions, 4K kernel pages (XFS won't mount on
16K), and the dedicated `/var/mnt/longhorn` XFS volume all come from step 03 (see
[`03_operating_system.md`](03_operating_system.md)). The one thing added for Longhorn is the kubelet
bind-mount of `/var/mnt/longhorn`, in `03d`'s `cp-patch.yaml`:

```yaml
machine:
  kubelet:
    extraMounts:
      - destination: /var/mnt/longhorn
        type: bind
        source: /var/mnt/longhorn
        options: [ bind, rshared, rw ]
```

Talos runs the kubelet in a container, and a host mount under `/var/mnt` is not auto-propagated into it, so
without the bind Longhorn's pods see an empty `/var/mnt/longhorn` and can't use the disk. `rshared` is required
so Longhorn's per-replica sub-mounts propagate back to the host (matches the official Longhorn "Talos Linux
Support" guidance). `03d` is the source of truth so any rebuild gets it; on a live cluster, apply just this
patch per node (`talosctl patch machineconfig ... --mode=auto`) before the Longhorn app syncs, or the manager
pods come up but every node's disk shows unschedulable.

**Values worth calling out** (under `longhorn:` in `values.yaml`):

- `defaultSettings.defaultDataPath: /var/mnt/longhorn`: the dedicated user volume, not the ephemeral
  `/var/lib/longhorn`.
- `defaultSettings.defaultReplicaCount: 3` with `replicaSoftAntiAffinity` left default (`false`) → **hard
  anti-affinity, one replica per node**. Full HA: a volume survives a single node loss intact. Trade-off:
  usable capacity ~1/3 of raw.
- `persistence.defaultClass: true` (+ `defaultClassReplicaCount: 3`): Longhorn is the cluster default
  `StorageClass`; unqualified PVCs land on it.
- `preUpgradeChecker.jobEnabled: false`: that Helm pre-upgrade hook Job can stall an ArgoCD sync waiting on
  completion; version control lives in git anyway.
- `storageMinimalAvailablePercentage: 15`: leave headroom on the Pi NVMes; don't schedule onto a disk under
  15% free.

Longhorn needs privileged Pod Security (Talos enforces `baseline` by default), so the Application stamps
`pod-security.kubernetes.io/enforce: privileged` on the `longhorn-system` namespace via
`managedNamespaceMetadata`. It uses `ServerSideApply` because its CRDs blow the client-side
last-applied-annotation limit.

**Verify:**

```bash
talosctl -n 192.168.10.201 read /proc/mounts | grep longhorn   # /var/mnt/longhorn present (after the patch)
kubectl -n longhorn-system get pods                            # manager on all 3 nodes + CSI Running
kubectl -n longhorn-system get nodes.longhorn.io -o wide       # each node's disk Schedulable
kubectl get storageclass                                       # `longhorn` present and (default)
```

Smoke test: apply a 1Gi PVC with `storageClassName: longhorn` + a pod, confirm it `Bound` and the volume shows
3 healthy replicas, one per node.

**Caveat.** Deliberately deleting the app/CRDs destroys the volumes — back up (Longhorn snapshots/backups)
before any teardown. If a Longhorn-managed field flaps `OutOfSync` after first sync (it mutates its own
StorageClass or a webhook config), add a targeted `ignoreDifferences` rather than fighting `selfHeal`.

## local-path-provisioner

Longhorn is the right default for most workloads but the wrong layer for [CloudNativePG](#cloudnativepg):
Postgres already replicates at the database layer, so replicated block storage underneath is redundant work
(write amplification, the Longhorn engine/CSI in the hot path, and Postgres competing with Longhorn for the one
big XFS partition). local-path-provisioner gives CNPG its own node-local storage on a dedicated partition, so
Postgres streaming replication is the only replication layer.

**Why local-path (not TopoLVM / OpenEBS-LVM).** The capacity-awareness and PVC-size enforcement those buy are
moot here: hostname anti-affinity puts exactly one CNPG instance per node on a dedicated 50 GiB partition, so
there's nothing to overcommit and a runaway DB is already bounded to that partition. LVM provisioners need a
raw block device for a volume group plus an `lvmd` daemon — awkward on Talos' shell-less immutable OS.
local-path is a single Deployment that creates a directory per PV; it's the pragmatic, thin fit. The trade:
local-path does **not** reserve or enforce the PVC `size` (thin/grow-on-write), so a runaway DB can fill the
50 GiB partition — contained to it; rely on CNPG's disk-usage alerts. Real reservation + online auto-grow would
be the signal to revisit TopoLVM.

**`WaitForFirstConsumer` is mandatory.** The StorageClass keeps the chart default
`volumeBindingMode: WaitForFirstConsumer`. For true node-local storage the volume physically exists on only one
node, so the scheduler must place the Postgres pod first (honoring CNPG's `kubernetes.io/hostname`
anti-affinity) and then provision the volume on whatever node it landed on. (`Immediate` binding is fine for
network-reachable CSI like Longhorn, but wrong here — it'd bind a PV to an arbitrary node before the pod is
scheduled.)

**Talos prerequisite.** Two things from [`03d`](03_operating_system.md): the dedicated fixed-size XFS volume at
`/var/mnt/cnpg` (50 GiB, `min == max` so it can't grow into Longhorn's space; the layout per node is EPHEMERAL
64 GiB → `cnpg` 50 GiB → `longhorn` remainder), and a kubelet bind-mount of `/var/mnt/cnpg` in `cp-patch.yaml`.
Same reason as Longhorn (host mounts under `/var/mnt` aren't auto-propagated into the kubelet container), but
plain `[bind, rw]` suffices — no per-replica sub-mount propagation, so no `rshared`.

**Wrapper chart: vendored, not a dependency pin.** There is no usable public Helm repo for
local-path-provisioner (Rancher's registry is auth-gated, bad for ArgoCD's repo-server; the community mirror is
stale), so `argo_apps/platform/charts/02_local_path_provisioner/` vendors the ~6 upstream manifests under
`templates/`, parameterized from `values.yaml` and pinned to `appVersion` `v0.0.36` in `Chart.yaml`. No
`Chart.lock` (no dependencies to resolve). Bump = edit `image.tag`/`helperImage.tag` + `appVersion`, then
re-diff `templates/` against the upstream `deploy/local-path-storage.yaml` at the new tag.

Config worth calling out (`values.yaml`):

- `dataPath: /var/mnt/cnpg`: the dedicated partition; node-local (the `DEFAULT_PATH_FOR_NON_LISTED_NODES`
  catch-all means every node uses this path on its own disk).
- `storageClass`: name `local-path`, `defaultClass: false` (Longhorn stays the cluster default; CNPG opts in by
  name), `volumeBindingMode: WaitForFirstConsumer`, `reclaimPolicy: Retain` (data safety).
- `helperImage` pinned (`busybox:1.37`) for reproducibility.

**Privileged PSA required** (like Longhorn): the provisioner runs unprivileged, but the short-lived helper pods
it stamps out to mkdir/rm per-volume dirs mount the node data path as a `hostPath`, forbidden under Talos'
`baseline` default. `managedNamespaceMetadata` labels the `local-path-storage` namespace
`pod-security.kubernetes.io/enforce: privileged`; without it the helper pods are rejected at admission and PVC
provisioning fails. No CRDs, so no SSA needed.

**Verify:**

```bash
helm template argo_apps/platform/charts/02_local_path_provisioner   # Deployment + local-path SC + RBAC + ConfigMap
export KUBECONFIG=secrets/kubeconfig
talosctl -n 192.168.10.201 get volumestatus | grep -E 'cnpg|longhorn'  # u-cnpg (50GiB) + u-longhorn present
talosctl -n 192.168.10.201 read /proc/mounts | grep /var/mnt/cnpg      # mounted + visible to the kubelet
kubectl -n local-path-storage get pods                                 # provisioner Running
kubectl get sc local-path -o jsonpath='{.volumeBindingMode}'; echo     # == WaitForFirstConsumer
```

**Caveat.** `reclaimPolicy: Retain` leaves host dirs behind: local-path only runs its teardown (`rm -rf
$VOL_DIR`) on `Delete`, so per-volume dirs under `/var/mnt/cnpg` persist after the PVC is gone — clean them up
manually to reclaim space.

## CloudNativePG

[CloudNativePG](https://cloudnative-pg.io) (CNPG) is a Kubernetes-native PostgreSQL operator that reconciles a
declarative `Cluster` CR into an HA Postgres (primary + streaming replicas, with failover, rolling updates and
metrics). It ships as two apps split across the two trees so operator and database land in dependency order
(see the two-tree model in [`05_gitops.md`](05_gitops.md)):

| App | Tree | What |
|-----|------|------|
| `cnpg-operator` (`platform/charts/02_cnpg_operator`) | platform, wave 2 | the controller + its CRDs (`Cluster`, `Backup`, …), an independent leaf. |
| `sample-workload` (`workloads/charts/sample_workload`) | workloads, no wave | a 2-instance Postgres `Cluster` on the `local-path` class. |

The root-of-roots creates the workloads tree only after the whole platform is Healthy, so by the time the
`Cluster` CR is applied both its real dependencies — the operator's `Cluster` CRD and the `local-path` class —
are guaranteed present, no per-app `sync-wave` needed. Chart versions: operator dep `cnpg/cloudnative-pg`
`0.28.3` (app `1.29.1`); the `Cluster` comes via the shared `pg-cluster` wrapper (`lib/helm/pg-cluster`),
which pins cluster dep `cnpg/cluster` `0.7.0`. Images (`ghcr.io/cloudnative-pg/*`) are multi-arch incl. arm64.

> Values nesting: `sample_workload` depends on the `pg-cluster` wrapper (dependency key `pg-cluster:`), which
> depends on `cnpg/cluster` (its `cluster:` map) — which itself has a top-level `cluster:` map for the CR spec.
> So a workload's Postgres knobs live at `pg-cluster.cluster.cluster.*`. Not a typo. Most of that tree is
> pre-baked in the wrapper; a workload only sets `type` + `instances` + `resources`.

**Storage: node-local, off Longhorn.** CNPG runs on the node-local `local-path` class on the dedicated 50 GiB
`/var/mnt/cnpg` partition — no Longhorn engine/CSI in the Postgres data path, isolated so the two can't starve
each other. Postgres streaming replication is the only replication layer: a node loss survives (CNPG promotes
the surviving instance and re-provisions the lost one from scratch via streaming replication). Full reasoning
in [local-path-provisioner](#local-path-provisioner) above.

**Values worth calling out.** Operator (`cloudnative-pg:`): `crds.create: true` (safe — the cluster is only
created after the platform is Healthy), `monitoring.podMonitorEnabled: true`, modest `resources` (it only
reconciles). Cluster — most of the following is pre-baked in the `pg-cluster` wrapper's `values.yaml`; the
workload only overrides the ⭐ **set-per-workload** ones (in `sample_workload/values.yaml` under
`pg-cluster.cluster.cluster.*`):

- ⭐ **`instances: 2`** (REQUIRED): 1 primary + 1 streaming replica on two distinct nodes. Two is enough —
  losing 2 of 3 nodes breaks the cluster many other ways anyway. The wrapper caps this at 1 or 2.
- ⭐ **`resources`** (REQUIRED; here 256Mi/250m req, 512Mi/1cpu limit): sized for the Pi 5s. Per-instance.
- ⭐ **`type: postgresql`** (REQUIRED): selects the container image (postgresql | postgis | timescaledb).
- **`affinity.topologyKey: kubernetes.io/hostname`** (wrapper-baked): the chart default spreads by
  `topology.kubernetes.io/zone`, but bare Pi nodes carry no zone label, so both instances could land on one
  node. Spreading by hostname forces distinct nodes — the node-loss HA that node-local storage relies on.
- `storage.storageClass: local-path`, `size: 45Gi` (wrapper-baked): the size is required by CNPG but a no-op
  under local-path (Postgres sees the whole ~50 GiB partition via `statfs`); set to the honest partition budget
  so it stays sane if the class is ever swapped.
- `postgresql.parameters` (`shared_buffers: 128MB`, `max_connections: 50`) (wrapper defaults, overridable):
  sized for the Pi 5s.
- `monitoring.enabled: true` (+ `podMonitor`; `prometheusRule` on by default) (wrapper-baked): per-instance
  Postgres metrics + CNPG alert rules, auto-converted by the VM operator and discovered by the
  [monitoring](09_monitoring.md) stack.
- `initdb: { database: app, owner: app }` (wrapper-baked): bootstraps a demo `app` DB; the operator
  auto-generates the owner's credentials into the `<name>-app` Secret (e.g. `sample-workload-db-app`, where the
  name is the instance's REQUIRED `cluster.fullnameOverride`) — no sealed-secret needed.

**Reclaim & durability.** PVCs are `reclaimPolicy: Retain`, so a `prune` is data-safe (and deleting the app
leaks the `/var/mnt/cnpg` dirs by design — clean up manually). **No PITR / no continuous backup**:
`backups.enabled: false` — object-storage (Barman) backups need an S3 endpoint + creds, out of scope here.
Until then durability rests entirely on Postgres replication across the 2 instances plus `Retain`; a node loss
rebuilds that instance from scratch by re-streaming a full base backup from its peer (expect IO while it
catches up). Add later via the `cnpg/plugin-barman-cloud` plugin + a sealed-secret ([06_secrets.md](06_secrets.md))
for real PITR.

Neither namespace needs privileged PSA — controller and Postgres pods run non-root (uid 26), so
`cnpg-system`/`sample-workload` stay restricted-compatible. Both apps use SSA (the CRDs and `Cluster` CR blow
the client-side annotation limit). The consuming app + its SSO/ingress edge ship in the merged
`sample-workload` chart — it ships its own edge, see [`07_ingress.md`](07_ingress.md) and
[`10_sample_workload.md`](10_sample_workload.md).

**Verify:**

```bash
helm dependency build argo_apps/platform/charts/02_cnpg_operator
helm dependency build argo_apps/workloads/charts/sample_workload
export KUBECONFIG=secrets/kubeconfig
kubectl -n cnpg-system rollout status deploy/cnpg-operator-cloudnative-pg   # operator Healthy (platform)
kubectl -n sample-workload get pods -o wide                                 # 2 instances Running, distinct nodes
kubectl -n sample-workload get pvc -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName  # == local-path
kubectl get vmpodscrape -A | grep -i cnpg                                   # metrics wired into VictoriaMetrics
```

Smoke test: delete the primary pod (`sample-workload-db-1`) and watch CNPG promote the replica, then heal
back to 2. The `app` role's credentials for external clients live in the auto-generated
`sample-workload-db-app` Secret; connect via the `sample-workload-db-rw` service.
