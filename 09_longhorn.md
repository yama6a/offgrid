# Longhorn — distributed block storage for the cluster

The cluster had **no persistent storage** — no default `StorageClass`, so nothing stateful could claim a
PVC. [Longhorn](https://longhorn.io) fills that gap: cloud-native distributed block storage that replicates
each volume across nodes. It's wired to the **dedicated XFS `longhorn` user volume** that
[`03d`](03_operating_system.md) already carves out of each NVMe (the rest of the disk after the 64 GiB
EPHEMERAL cap), mounted at `/var/mnt/longhorn`.

Like [`nic-keeper`](06_nic_keeper.md), [`sealed-secrets`](07_sealed_secrets.md) and
[`cert-manager`](08_cert_manager.md), this is **not** an imperative bootstrap (unlike Cilium or ArgoCD,
which have a chicken-and-egg with the cluster/network). It's a plain wave-2 ArgoCD app — with **one** host
prerequisite that lives in the Talos config (the kubelet bind-mount, below).

## The wrapper chart

Single source of truth is the wrapper chart at `argo_apps/platform/charts/02_longhorn/` (same pattern as
`00_cilium` / `01_argocd` / `02_sealed_secrets` / `02_cert_manager`):

| Path          | Holds                                                                                                       |
|---------------|-------------------------------------------------------------------------------------------------------------|
| `Chart.yaml`  | the **Longhorn chart version** (`1.12.0`, app `v1.12.0`), a dependency on the `charts.longhorn.io` repo.     |
| `values.yaml` | all config under the `longhorn:` key — data path, replica count, default StorageClass, pre-upgrade hook.    |
| `Chart.lock`  | pins the resolved dependency; **must be committed** (ArgoCD's repo-server runs `helm dependency build`).     |

Generate/refresh the lock with `helm dependency update argo_apps/platform/charts/02_longhorn` and commit it (the
vendored `charts/*.tgz` is gitignored — reproduced from the lock, same as the other charts).

### Version — `1.12.0`, the latest stable

Pinned to the latest stable GA (verified against `charts.longhorn.io/index.yaml` and the GitHub releases).
Bump by editing the dependency in `Chart.yaml` and refreshing the lock — nothing is hardcoded in a script.

### V1 data engine (not V2/SPDK)

Longhorn's V2 (SPDK) data engine has a **known stuck-I/O bug on ARM64 + NVMe** (SPDK with 2+ cores and the
NVMe driver). The Pi 5 is exactly that combination, so we stay on the default **V1 engine** — lighter on the
low-power nodes anyway. Revisit only if the upstream ARM64/NVMe issue is fixed.

## Talos prerequisites — what was already done, and the one thing that wasn't

Longhorn on Talos (an immutable OS) needs several host-level things. Three were already in place from step 03;
the fourth is added here.

| Requirement | Status | Where |
|-------------|--------|-------|
| `iscsi-tools` extension (iscsid for PV operations) | ✅ baked | `03_config.sh` `ISCSI_EXT`, image built in `03a` |
| `util-linux-tools` extension (nsenter/fstrim) | ✅ baked | `03_config.sh` `UTIL_EXT` |
| **4K kernel pages** (XFS won't mount on 16K) | ✅ built | `03_operating_system.md` ("4K kernel pages") |
| Dedicated XFS volume at `/var/mnt/longhorn` | ✅ provisioned | `03d` `volumes.yaml` (`UserVolumeConfig` `longhorn`) |
| **kubelet bind-mount of `/var/mnt/longhorn`** | ➕ **added here** | `03d` `cp-patch.yaml` (`machine.kubelet.extraMounts`) |

### Why the kubelet extraMount is required

Talos runs the kubelet **in a container**. A host mount under `/var/mnt` is **not** auto-propagated into that
container, so without an explicit bind Longhorn's pods see an empty `/var/mnt/longhorn` (or the root fs) and
can't use the disk. The fix, now in `03d`'s `cp-patch.yaml`:

```yaml
machine:
  kubelet:
    extraMounts:
      - destination: /var/mnt/longhorn
        type: bind
        source: /var/mnt/longhorn
        options: [bind, rshared, rw]
```

`rshared` lets Longhorn's per-replica sub-mounts propagate back to the host. This matches the official
Longhorn "Talos Linux Support" guidance.

### Rolling it out to the already-running nodes

`03d` is the source of truth (so any future rebuild gets the mount), but **re-running all of `03d` on a live
cluster is unsafe** — its `talosctl bootstrap` step errors on an already-bootstrapped cluster under `set -e`.
Apply just this patch to each node instead (Talos restarts the kubelet to pick it up — brief, no reboot, no
data loss):

```bash
cd 03_operating_system/talos-cluster   # has talosconfig from 03d
cat > longhorn-kubelet-patch.yaml <<'EOF'
machine:
  kubelet:
    extraMounts:
      - destination: /var/mnt/longhorn
        type: bind
        source: /var/mnt/longhorn
        options: [bind, rshared, rw]
EOF
for ip in 192.168.10.201 192.168.10.202 192.168.10.203; do   # CLUSTER_NODES in 03_config.sh
  docker run --rm --network host -v "$PWD:/work" -w /work \
    -e TALOSCONFIG=/work/talosconfig \
    ghcr.io/siderolabs/talosctl:v1.13.4 \
    patch machineconfig -n "$ip" -p @longhorn-kubelet-patch.yaml --mode=auto
done
```

Do this **before** the Longhorn app syncs (or the manager pods come up but every node's disk shows
unschedulable/missing).

## Storage layout & the "auto-expanding partition" question

The `longhorn` volume in `03d`'s `volumes.yaml` is `minSize: 50GiB` with **no `maxSize`**:

```yaml
apiVersion: v1alpha1
kind: UserVolumeConfig
name: longhorn
provisioning:
  diskSelector:
    match: disk.transport == "nvme"
  minSize: 50GiB
filesystem:
  type: xfs
```

No `maxSize` means Talos grows it **once, at provision time**, to claim all NVMe space left after the 64 GiB
EPHEMERAL cap. The result is a **stable, fixed-size XFS filesystem** — *not* a partition that keeps growing on
demand at runtime. That distinction matters for Longhorn: it reads a disk's capacity via `statfs` and schedules
replicas against it, so a fixed filesystem is exactly what it wants. A genuinely runtime-growing/thin-provisioned
backing store could mislead Longhorn's capacity accounting — but that's not what we have here. **So no
partition-size change was needed; `volumes.yaml` stays as-is.** Longhorn auto-creates its default disk at
`/var/mnt/longhorn` on every node and reports `~disk − 64 GiB` of capacity.

## Values worth calling out

All under the `longhorn:` key in `values.yaml`:

- **`defaultSettings.defaultDataPath: /var/mnt/longhorn`** — the dedicated user volume, not the default
  `/var/lib/longhorn` (which sits on the ephemeral area).
- **`defaultSettings.defaultReplicaCount: 3`** — one replica per node. Full HA: a volume survives a single node
  loss with data intact. `replicaSoftAntiAffinity` stays default (`false`) → **hard** anti-affinity, so the three
  replicas always land on three distinct nodes (ideal at 3 nodes / 3 replicas). The trade-off is usable capacity
  ≈ 1/3 of raw Longhorn space — acceptable for the resilience.
- **`persistence.defaultClass: true`** (+ `defaultClassReplicaCount: 3`) — Longhorn becomes the cluster's
  default StorageClass; it's the only storage, so unqualified PVCs land on it.
- **`preUpgradeChecker.jobEnabled: false`** — that checker is a Helm **pre-upgrade hook Job**; under ArgoCD a
  hook Job can stall the sync waiting on completion. Version control already lives in git, so it's disabled.
- **`storageMinimalAvailablePercentage: 15`** — leave headroom on the Pi NVMes; don't schedule onto a disk under
  15% free.

## Where it sits — wave 2, with the other leaves

Longhorn, [`nic-keeper`](06_nic_keeper.md), [`sealed-secrets`](07_sealed_secrets.md) and
[`cert-manager`](08_cert_manager.md) are **independent leaves** — none depends on the others — so they share
**sync-wave `2`**. Per [CLAUDE.md](CLAUDE.md) the `NN` prefix *is* the wave, so all four carry the `02_` prefix
(`argo_apps/platform/apps/02_longhorn.yaml`, `…/02_nic_keeper.yaml`, …); the dir/file names stay distinct and
`ls argo_apps/platform/apps/` still reads in deploy order. Wave 2 is the "after the platform (CNI + ArgoCD) is in place"
slot — Longhorn only needs the CNI (wave 0) for pod networking.

> Note on numbering: the argo-app `NN` is the **sync-wave**; the top-level `.md` files (this is `09`) follow
> **runbook step order** (…`07_sealed_secrets`, `08_cert_manager`, `09_longhorn`). The two schemes are
> independent — Longhorn is argo-app `02` but runbook doc `09`.

**syncPolicy: `automated {prune: true, selfHeal: true}` + `CreateNamespace=true` + `ServerSideApply=true`** — a
safe leaf, like the other wave-2 apps. `ServerSideApply` is required because the Longhorn CRDs are large enough
to blow the client-side last-applied-annotation limit (the same reason `01_argocd` / `02_cert_manager` use SSA).
Longhorn needs **privileged** Pod Security; Talos applies `baseline` by default, so the Application stamps
`pod-security.kubernetes.io/enforce: privileged` on the auto-created `longhorn-system` namespace via
`managedNamespaceMetadata`.

## Verifying it

```bash
# the host mount is visible to the kubelet on every node (after the patch above):
talosctl -n 192.168.10.201 read /proc/mounts | grep longhorn     # /var/mnt/longhorn present

# the lock resolves exactly as ArgoCD's repo-server will (proves sync won't break):
helm dependency build argo_apps/platform/charts/02_longhorn
helm template argo_apps/platform/charts/02_longhorn | head                 # renders manager / driver / CSI / CRDs

# after commit/push — the root app picks up 02_longhorn.yaml and syncs at wave 2:
kubectl -n longhorn-system get pods                               # longhorn-manager on all 3 nodes + CSI Running
kubectl -n longhorn-system get nodes.longhorn.io -o wide          # each node's /var/mnt/longhorn disk Schedulable
kubectl get storageclass                                          # `longhorn` present and (default)
```

End-to-end smoke test — prove a replicated volume binds and survives a reschedule:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: lh-smoke }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: lh-smoke }
spec:
  containers:
    - name: w
      image: busybox
      command: ["sh","-c","echo hello-longhorn > /data/t && sleep 3600"]
      volumeMounts: [{ name: v, mountPath: /data }]
  volumes:
    - name: v
      persistentVolumeClaim: { claimName: lh-smoke }
EOF
kubectl get pvc lh-smoke -w                       # Bound
# Longhorn UI / CRDs: the volume shows 3 healthy replicas, one per node.
kubectl delete pod lh-smoke && kubectl delete pvc lh-smoke   # clean up
```

## Caveats

- **Apply the kubelet extraMount to the running nodes first** (the rollout command above). Without it the
  Longhorn manager starts but every node's disk is unschedulable — the app looks Healthy yet no volume can
  schedule.
- **Generate + commit `Chart.lock` before the app syncs.** This app has no imperative bootstrap step — run
  `helm dependency update argo_apps/platform/charts/02_longhorn` yourself and commit the lock, or the `longhorn` app
  shows `OutOfSync` with a `helm dependency build` error (same failure mode as a missing cilium/argocd lock).
- **Push before you expect a sync.** ArgoCD reads git, not local disk — commit *and push* `argo_apps/**` (incl.
  `Chart.lock`) or the root app reports `ComparisonError`.
- **Longhorn owns its CRDs.** A `prune` won't cascade-delete volume data, but deliberately deleting the app/CRDs
  destroys the volumes — back up (Longhorn snapshots/backups) before any teardown.
- **If a Longhorn-managed field flaps `OutOfSync`** after first sync (e.g. it mutates its own StorageClass or a
  webhook config), add a targeted `ignoreDifferences` to the Application rather than fighting `selfHeal`.
