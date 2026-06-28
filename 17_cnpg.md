# CloudNativePG — managed PostgreSQL on the cluster

The cluster had storage ([Longhorn](09_longhorn.md), the default `longhorn` StorageClass) but no
managed database. [CloudNativePG](https://cloudnative-pg.io) (CNPG) fills that gap: a Kubernetes-native
PostgreSQL operator that reconciles a declarative `Cluster` CR into an HA Postgres — a primary plus
streaming replicas, with failover, rolling updates and metrics handled for you.

Like [`longhorn`](09_longhorn.md) / [`sealed-secrets`](07_sealed_secrets.md) /
[`cert-manager`](08_cert_manager.md), this is **not** an imperative bootstrap (unlike Cilium or ArgoCD,
which have a chicken-and-egg with the cluster/network). It's plain ArgoCD apps. It ships as **two**
apps, split across the two trees so the operator and the database it provisions land in dependency
order (see the two-tree model in [05_gitops.md](05_gitops.md)):

| App | Tree | What |
|-----|------|------|
| `cnpg-operator` (`platform/charts/02_cnpg_operator`) | **platform**, wave 2 | the CNPG controller + its CRDs (`Cluster`, `Backup`, …) — an independent leaf, only needs the CNI. |
| `cnpg-cluster` (`workloads/charts/cnpg_cluster`)    | **workloads**, no wave | a 2-instance Postgres `Cluster` on the node-local `local-path` class ([local-path-provisioner](18_local_path_provisioner.md)). |

The split matters: the root-of-roots only creates the **workloads** tree once the **whole platform** is
**Synced + Healthy**. So by the time the `Cluster` CR is applied, the operator's `Cluster` CRD is
registered *and* the [local-path provisioner](18_local_path_provisioner.md) (with its `local-path` class)
is up — **without** the cluster needing a per-app `sync-wave`. The operator (platform wave 2) installs its own CRDs before anything in workloads consumes
them; no separate wave-0 CRD app is needed (cf. the prometheus/VM operator CRDs).

> Note on numbering: platform apps use `NN_` = **sync-wave** (operator is `02_`); workloads are
> **un-numbered and wave-less**. And the top-level `.md` files (this is `17`) follow **runbook step
> order** — independent of either, just as Longhorn is argo-app `02` but doc `09`.

## The wrapper charts

Single source of truth, same pattern as every other app (`Chart.yaml` pins the version, `values.yaml`
is all config, `Chart.lock` is committed, vendored `charts/*.tgz` is gitignored):

| Path | Holds |
|------|-------|
| `argo_apps/platform/charts/02_cnpg_operator/` | dep `cnpg/cloudnative-pg` **`0.28.3`** (app `1.29.1`); values under `cloudnative-pg:`. |
| `argo_apps/workloads/charts/cnpg_cluster/`    | dep `cnpg/cluster` **`0.7.0`**; values under `cluster:` (points `storage.storageClass` at `local-path`). |

Both pinned to the latest stable GA (verified against `cloudnative-pg.github.io/charts/index.yaml`).
The operator/Postgres images (`ghcr.io/cloudnative-pg/*`) are **multi-arch incl. arm64**, so they run
on the Pi 5s. Bump by editing the dependency in `Chart.yaml` and refreshing the lock — nothing is
hardcoded in a script.

> Values nesting (`cnpg_cluster`): the wrapper key is the dependency *name*, `cluster:`, and the
> upstream chart *itself* has a top-level `cluster:` map for the CR spec — hence `cluster.cluster.*`.
> That double key is expected, not a typo.

## The storage decision — node-local, off Longhorn

Postgres already replicates at the **database** layer (primary + streaming replicas), so a replicated
block store underneath is redundant work. The full reasoning — why node-local beats Longhorn for CNPG,
why local-path-provisioner over TopoLVM/OpenEBS-LVM, and the `WaitForFirstConsumer` requirement — lives
in **[18_local_path_provisioner.md](18_local_path_provisioner.md)**. In short:

- CNPG runs on the node-local **`local-path`** class, on a **dedicated 50 GiB partition** (`/var/mnt/cnpg`,
  carved by [03d](03_operating_system.md)) — **no Longhorn engine/CSI in the Postgres data path**, and
  the partition is isolated from Longhorn's so the two can't starve each other.
- **Postgres streaming replication is the only replication layer.** A **node loss** still survives:
  Postgres promotes the surviving instance, and CNPG re-provisions the lost one from scratch via
  streaming replication. HA is Postgres's job — there is no storage-level replica to lean on.

> Earlier this cluster ran CNPG on a single-replica Longhorn class (`longhorn-single`, now removed). That
> already avoided the 9× write amplification of the default 3-replica `longhorn` class, but kept Longhorn
> in the data path and on the shared partition — the two problems this change finishes off. See the
> "what changed" section in [18_local_path_provisioner.md](18_local_path_provisioner.md).

## Values worth calling out

**Operator** (`cloudnative-pg:` in `platform/charts/02_cnpg_operator/values.yaml`):

- **`crds.create: true`** — the operator chart owns the CNPG CRDs. Safe because the workloads tree (the
  cluster) is only created after the whole platform is Healthy, so the CRDs exist before the `Cluster`
  CR is applied.
- **`monitoring.podMonitorEnabled: true`** — emits the controller's PodMonitor.
- modest `resources` — the controller only reconciles; the DB work is in the Postgres pods.

**Cluster** (`cluster.cluster.*` in `workloads/charts/cnpg_cluster/values.yaml`):

- **`instances: 2`** — 1 primary + 1 streaming replica, on two distinct Pi nodes. Two is enough here:
  losing 2 of 3 nodes breaks the cluster in many other ways anyway.
- **`storage.storageClass: local-path`**, `size: 45Gi`. The size is **required by CNPG but a no-op under
  local-path** (it neither reserves nor enforces — Postgres sees the whole ~50 GiB partition via
  `statfs`); set to the honest partition budget so it stays sane if the class is ever swapped. See
  [18_local_path_provisioner.md](18_local_path_provisioner.md).
- **`affinity.topologyKey: kubernetes.io/hostname`** — the chart's default spreads by
  `topology.kubernetes.io/zone`, but bare Pi nodes carry no zone label, so both instances could land on
  one node. Spreading by hostname forces them onto distinct nodes — the node-loss HA that node-local
  storage relies on.
- **`resources`** (256Mi/250m req, 512Mi/1cpu limit) + **`postgresql.parameters`**
  (`shared_buffers: 128MB`, `max_connections: 50`) — sized for the Pi 5s.
- **`monitoring.enabled: true`** (+ `podMonitor` / `prometheusRule`) — per-instance Postgres metrics +
  CNPG alert rules.
- **`initdb: { database: app, owner: app }`** — bootstraps a demo `app` DB; the operator auto-generates
  the owner's credentials into the `cnpg-cluster-app` Secret (no sealed-secret needed for this).

## Monitoring — wires into VictoriaMetrics for free

Both apps emit **PodMonitor** (and the cluster a **PrometheusRule**). The VM operator auto-converts
`PodMonitor → VMPodScrape` / `PrometheusRule → VMRule`, and the [k8s-stack](15_monitoring.md) discovers
every scrape cluster-wide — so CNPG metrics and alerts flow into VictoriaMetrics with **no extra
config**, the same convention as longhorn / cert-manager / argocd.

## No backups in this pass

`cluster.backups.enabled: false`. Object-storage (Barman) backups need an S3-compatible endpoint and
credentials — out of scope here. Add later via the `cnpg/plugin-barman-cloud` CNPG-I plugin and a
[sealed-secret](07_sealed_secrets.md) for the S3 creds. Until then, durability rests on Postgres
replication across the 2 instances + the `local-path` class's `Retain` policy; for real PITR you'll want
the backup plugin. (This matters more now: node-local storage has no storage-level replica, so a node
loss rebuilds the instance entirely from its peer — see Caveats.)

## Where it sits — platform operator, workload cluster

- **Operator = platform, wave 2**, with the other independent leaves
  ([longhorn](09_longhorn.md) / [cert-manager](08_cert_manager.md) / sealed-secrets) — it only needs
  the CNI. Per [CLAUDE.md](CLAUDE.md) the `NN` prefix *is* the wave, so it carries `02_`.
- **Cluster = workload, no wave.** It lives in the workloads tree, which the root-of-roots only creates
  after the entire platform is Healthy — so both of its real dependencies (the operator's `Cluster` CRD
  + the [local-path provisioner](18_local_path_provisioner.md)'s `local-path` class, both platform wave 2)
  are guaranteed present, with no per-app `sync-wave` needed. It reconciles in parallel with the other
  workloads (e.g. `gateway-test`), which it doesn't depend on.

**syncPolicy** on both: `automated {prune: true, selfHeal: true}` + `CreateNamespace=true` +
`ServerSideApply=true`. SSA matters — the CNPG CRDs and the `Cluster` CR are large enough to blow the
client-side last-applied-annotation limit (same reason longhorn / cert-manager / argocd use SSA).
Neither namespace needs privileged PSA: the controller and the Postgres pods run **non-root** (uid 26),
so `cnpg-system` / `databases` stay restricted-compatible (no `managedNamespaceMetadata`, unlike
Longhorn). A `prune` is **data-safe** — the PVCs are `reclaimPolicy: Retain`.

> The `cnpg/cluster` chart also renders a `helm.sh/hook: test` Job (`cnpg-cluster-ping-test`). ArgoCD
> **ignores Helm `test` hooks** (it only runs pre/post-install/upgrade/delete hooks), so the Job is
> never applied during sync and causes no `OutOfSync` — no action needed.

## Verifying it

```bash
# the locks resolve exactly as ArgoCD's repo-server will (proves sync won't break):
helm dependency build argo_apps/platform/charts/02_cnpg_operator
helm dependency build argo_apps/workloads/charts/cnpg_cluster
helm template argo_apps/platform/charts/02_cnpg_operator   # operator + 10 CRDs + PodMonitor render
helm template argo_apps/workloads/charts/cnpg_cluster       # Cluster CR (storageClass: local-path, instances: 2) + PodMonitor

# after commit/push — platform brings up the operator, then the workloads tree brings up the cluster:
export KUBECONFIG=03_operating_system/talos-cluster/kubeconfig
kubectl -n cnpg-system rollout status deploy/cnpg-operator-cloudnative-pg   # operator Healthy (platform)
kubectl get storageclass local-path                                         # local-path SC present (18_local_path_provisioner.md)
kubectl -n databases get cluster                                            # Cluster CR (workload)
kubectl -n databases get pods -o wide                                       # 2 instances Running, on 2 distinct nodes
kubectl -n databases get pvc -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName  # == local-path
kubectl get vmpodscrape -A | grep -i cnpg                                   # metrics wired into VictoriaMetrics
```

End-to-end smoke test — prove the database accepts writes and survives a failover:

```bash
# (optional, needs the CNPG kubectl plugin) shows 1 primary + 1 replica streaming:
kubectl cnpg status -n databases cnpg-cluster

# write/read directly inside the primary instance pod (local socket, superuser):
kubectl -n databases exec -it cnpg-cluster-1 -- psql -U postgres -d app \
  -c "CREATE TABLE IF NOT EXISTS smoke(t text); INSERT INTO smoke VALUES('hi'); SELECT * FROM smoke;"

# the app role's credentials for external clients live in the auto-generated Secret:
kubectl -n databases get secret cnpg-cluster-app \
  -o jsonpath='{.data.password}' | base64 -d; echo    # connect via the cnpg-cluster-rw service

# delete the primary pod and watch CNPG promote the replica (failover), then heal back to 2:
kubectl -n databases delete pod cnpg-cluster-1
kubectl -n databases get pods -w
```

## Caveats

- **Generate + commit both `Chart.lock`s before the apps sync.** No imperative bootstrap runs them —
  run `helm dependency build` on each chart yourself and commit, or the apps show `OutOfSync` with a
  `helm dependency build` error (same failure mode as a missing longhorn/cilium lock). (The
  [local-path-provisioner](18_local_path_provisioner.md) chart is vendored, so *it* has no lock — but
  these two CNPG charts still do.)
- **Push before you expect a sync.** ArgoCD reads git, not local disk — commit *and push*
  `argo_apps/**` (incl. both `Chart.lock`s) and `17_cnpg.md`, or the root app reports `ComparisonError`.
- **`reclaimPolicy: Retain` leaks volumes on teardown.** Deleting the `cnpg-cluster` app leaves the
  node-local dirs under `/var/mnt/cnpg` behind (by design — data safety). Clean them up manually on each
  node if you really want the space back (see [18_local_path_provisioner.md](18_local_path_provisioner.md)).
- **Node-local storage means a node loss rebuilds that instance from scratch.** There's no storage-level
  replica — Postgres re-streams a full base backup from the surviving instance onto a freshly-provisioned
  local volume. Expect IO while it catches up. This is the deliberate trade for keeping Longhorn out of
  the data path.
- **No size enforcement.** `local-path` doesn't cap a volume — a runaway DB can fill the 50 GiB partition
  (contained to it; Longhorn/OS untouched). Lean on CNPG's disk-usage alerts. See
  [18_local_path_provisioner.md](18_local_path_provisioner.md).
- **No PITR until backups are wired.** `backups.enabled: false` — see the "No backups" section before
  trusting this with data you can't lose.
