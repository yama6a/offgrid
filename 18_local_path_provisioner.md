# local-path-provisioner — node-local storage for CloudNativePG

[Longhorn](09_longhorn.md) is the cluster's general-purpose storage: distributed, replicated, the default
`StorageClass`. That's the right default for most stateful workloads — but it's the *wrong* layer for
[CloudNativePG](17_cnpg.md). Postgres already replicates at the database layer (primary + streaming
replicas), so a replicated block store underneath is **redundant work**: extra write amplification, the
Longhorn engine/CSI in the hot path, and — because Longhorn's volumes share the one big XFS partition —
Postgres and Longhorn competing for the same disk.

This step gives CNPG its own **node-local** storage on a **dedicated partition**, so that **Postgres
streaming replication is the only replication layer**. It's a plain wave-2 ArgoCD app (like
[longhorn](09_longhorn.md) / [cnpg-operator](17_cnpg.md) / [sealed-secrets](07_sealed_secrets.md)), with
one host prerequisite in the Talos config (a kubelet bind-mount, below).

## What changed vs. the previous CNPG storage

CNPG previously ran on a dedicated single-replica Longhorn class (`longhorn-single`,
`numberOfReplicas: 1`), so it was **not** double-replicating. The remaining problems this step fixes:

1. **Longhorn engine/CSI still sat in the Postgres data path** — every IO went through a Longhorn volume.
   Now Postgres writes straight to a local directory on the node's disk.
2. **No capacity isolation** — CNPG's volumes lived on the same XFS partition as all Longhorn data, so a
   runaway DB and Longhorn could starve each other. Now CNPG gets its own fixed 50 GiB partition.

The `longhorn-single` StorageClass (and its template in the CNPG chart) is removed — nothing else used it.

## Why local-path-provisioner (and not TopoLVM / OpenEBS LVM)

| Option | Capacity-aware? | Enforces PVC size? | Talos fit | Verdict |
|--------|-----------------|--------------------|-----------|---------|
| **local-path-provisioner** | no | no (thin/grow-on-write) | trivial — just a Deployment + hostPath PVs | **chosen** |
| TopoLVM | yes (scheduler) | yes (each PV is an LV) | needs a *raw* Talos volume + lvmd DaemonSet + a VG to manage | rejected — complexity |
| OpenEBS LVM LocalPV | yes | yes | same raw-VG requirement as TopoLVM | rejected — no edge over TopoLVM here |

The capacity-awareness and size-enforcement that TopoLVM/OpenEBS-LVM buy are **largely moot on this
cluster**: hostname anti-affinity puts exactly **one** CNPG instance per node, on a **dedicated 50 GiB
partition** — so there's nothing to overcommit and a runaway DB's blast radius is already bounded to that
partition (Longhorn and the OS are on other partitions). Against that, LVM-based provisioners need a raw
(unformatted) block device for their volume group plus an `lvmd` daemon — awkward on Talos' shell-less
immutable OS. local-path-provisioner is a single Deployment that creates a directory per PV; it's the
pragmatic fit and matches the repo's "thin" ethos.

**The trade we accept:** local-path doesn't reserve or enforce the PVC `size`. It's inherently
thin/grow-on-write (a PVC consumes 0 bytes until written), so nothing is wasted — but a runaway DB can
grow to fill the whole 50 GiB partition. That's contained to the partition; rely on CNPG's disk-usage
alerts. If real reservation + online auto-grow ("1 GiB then grow") is ever needed, that's the signal to
revisit TopoLVM.

> Because the PVC size is a no-op here, [`cnpg_cluster`'s](17_cnpg.md) `storage.size` is set to the
> honest partition budget (`45Gi`, ~50 GiB minus XFS headroom) purely so the number stays sane if the
> class is ever swapped for an enforcing one — it is **not** a limit. CNPG requires the field, so it
> can't simply be dropped.

## `WaitForFirstConsumer` is mandatory

The StorageClass uses `volumeBindingMode: WaitForFirstConsumer` (the chart default — kept deliberately).
For true node-local storage the volume **only physically exists on one node**, so the scheduler must
place the Postgres pod *first* — honoring CNPG's `kubernetes.io/hostname` anti-affinity — and *then*
provision the volume on whatever node it landed on. (Contrast the old `longhorn-single`, which used
`Immediate`: fine for Longhorn because its CSI is network-reachable from any node, but wrong for
node-local storage, where `Immediate` would bind a PV to an arbitrary node before the pod is scheduled.)

## Talos prerequisite — the dedicated partition + kubelet bind-mount

Two things in [`03d`](03_operating_system.md) (`03_config.sh` + `03d_talos_cluster_config.sh`), the same
shape as Longhorn's:

| Requirement | Where |
|-------------|-------|
| Dedicated fixed-size XFS volume at `/var/mnt/cnpg` (50 GiB, `min == max`) | `03d` `volumes.yaml` (`UserVolumeConfig` `cnpg`); size knob `CNPG_VOLUME_SIZE` in `03_config.sh` |
| **kubelet bind-mount of `/var/mnt/cnpg`** | `03d` `cp-patch.yaml` (`machine.kubelet.extraMounts`) |

The partition layout per node is now: `EPHEMERAL` (64 GiB) → `cnpg` (50 GiB, fixed) → `longhorn` (the
remainder). The `cnpg` volume is `min == max` so it's a fixed slice that can't grow into Longhorn's
space; `longhorn` keeps its no-`maxSize` "claim the rest at provision time" behavior. See
[09_longhorn.md](09_longhorn.md) for the partition-layout reasoning.

**Why the bind-mount is required (same reason as Longhorn):** Talos runs the kubelet in a container, and
host mounts under `/var/mnt` aren't auto-propagated into it. local-path's helper pods (which `mkdir`/`rm`
the per-volume dirs) and the resulting hostPath PVs both resolve `/var/mnt/cnpg` against the kubelet's
view — without the bind they'd hit an empty dir or the root fs. Plain `[bind, rw]` suffices here (no
per-replica sub-mount propagation like Longhorn, so no `rshared`).

## The wrapper chart — vendored, not a dependency pin

Same single-source-of-truth spirit as every other app (`values.yaml` is all config), with one
difference: there is **no maintained public Helm repo** for local-path-provisioner — Rancher's registry
(`oci://dp.apps.rancher.io/...`) is auth-gated (bad for ArgoCD's repo-server) and the community mirror is
years stale. So the chart at `argo_apps/platform/charts/02_local_path_provisioner/` **vendors** the ~6
upstream manifests (ServiceAccount, RBAC, ConfigMap, Deployment, StorageClass) under `templates/`,
parameterized from `values.yaml` and **pinned to `appVersion` in `Chart.yaml`** (`v0.0.36`).

Consequences of vendoring (vs. the dependency-pin pattern in [CLAUDE.md](CLAUDE.md)):

- **No `Chart.lock` / `helm dependency build`** — there are no chart dependencies to resolve.
- **Bumping** = edit `image.tag` + `helperImage.tag` in `values.yaml` and `appVersion` in `Chart.yaml`,
  then re-diff `templates/` against the upstream release manifest
  (`rancher/local-path-provisioner` `deploy/local-path-storage.yaml` at the new tag).

Config worth calling out in `values.yaml`:

- **`dataPath: /var/mnt/cnpg`** — the dedicated partition; node-local (the
  `DEFAULT_PATH_FOR_NON_LISTED_NODES` catch-all means every node uses this path on its **own** disk, not
  a shared filesystem).
- **`storageClass`**: name `local-path`, `defaultClass: false` (Longhorn stays the cluster default; CNPG
  opts in by name), `volumeBindingMode: WaitForFirstConsumer`, `reclaimPolicy: Retain` (data safety).
- **`helperImage`** pinned (`busybox:1.37`) for reproducibility.

## Where it sits — wave 2, with the other storage leaves

Platform, **sync-wave 2**, alongside [longhorn](09_longhorn.md) / [cnpg-operator](17_cnpg.md) /
[cert-manager](08_cert_manager.md) / sealed-secrets — independent leaves that only need the CNI. Per
[CLAUDE.md](CLAUDE.md) the `NN` prefix *is* the wave, so it carries `02_`. The CNPG **cluster** that
consumes the `local-path` class is a [workload](17_cnpg.md) (un-numbered, wave-less), only created once
the whole platform is Healthy — so wave 2 is comfortably early enough for the class to exist first.

**syncPolicy: `automated {prune: true, selfHeal: true}` + `CreateNamespace=true`** — a safe leaf. It owns
no CRDs, so SSA isn't needed (unlike longhorn/cert-manager). **No privileged PSA**: the provisioner and
its helper pods only need `baseline` (hostPath is allowed under baseline, nothing runs privileged), which
is Talos' default — so no `managedNamespaceMetadata` (unlike Longhorn).

## Verifying it

```bash
# the chart renders (no deps, so nothing to build):
helm template argo_apps/platform/charts/02_local_path_provisioner   # Deployment + local-path SC + RBAC + ConfigMap

# after rebuild + push — the partition exists and the kubelet can see it:
export KUBECONFIG=03_operating_system/talos-cluster/kubeconfig
talosctl -n 192.168.10.201 get volumestatus | grep -E 'cnpg|longhorn'  # u-cnpg (50GiB) + u-longhorn present
talosctl -n 192.168.10.201 read /proc/mounts | grep /var/mnt/cnpg      # mounted + visible to the kubelet

kubectl -n local-path-storage get pods                                 # local-path-provisioner Running
kubectl get sc local-path -o jsonpath='{.volumeBindingMode}'; echo     # == WaitForFirstConsumer
kubectl get storageclass                                               # local-path present; longhorn still (default)
```

## Caveats

- **Apply the partition + kubelet extraMount before the app syncs** — both ship in `03d`, so a clean
  rebuild ([03_operating_system.md](03_operating_system.md)) handles it. Without the partition, PVs land
  on the EPHEMERAL fs (no isolation); without the bind-mount, the helper pods/PVs can't see the disk.
- **`reclaimPolicy: Retain` leaves host dirs behind.** local-path only runs its teardown (`rm -rf
  $VOL_DIR`) on `Delete`; with `Retain` the per-volume dirs under `/var/mnt/cnpg` persist after the PVC
  is gone — clean them up manually to reclaim space.
- **No size enforcement** — see the trade above. A runaway DB can fill the 50 GiB partition; lean on
  CNPG's disk-usage alerts.
- **Push before you expect a sync.** ArgoCD reads git, not local disk — commit *and push* `argo_apps/**`
  and this doc, or the root app reports `ComparisonError`.
