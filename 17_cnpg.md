# CloudNativePG — managed PostgreSQL on the cluster

The cluster had storage ([Longhorn](09_longhorn.md), the default `longhorn` StorageClass) but no
managed database. [CloudNativePG](https://cloudnative-pg.io) (CNPG) fills that gap: a Kubernetes-native
PostgreSQL operator that reconciles a declarative `Cluster` CR into an HA Postgres — a primary plus
streaming replicas, with failover, rolling updates and metrics handled for you.

Like [`longhorn`](09_longhorn.md) / [`sealed-secrets`](07_sealed_secrets.md) /
[`cert-manager`](08_cert_manager.md), this is **not** an imperative bootstrap (unlike Cilium or ArgoCD,
which have a chicken-and-egg with the cluster/network). It's plain ArgoCD apps. It ships as **two**
apps so the operator and the database it provisions sync in dependency order:

| App | Wave | What |
|-----|------|------|
| `02_cnpg_operator` | 2 | the CNPG controller + its CRDs (`Cluster`, `Backup`, …) — an independent leaf, only needs the CNI. |
| `03_cnpg_cluster`  | 3 | a 3-instance Postgres `Cluster` + its dedicated `longhorn-single` StorageClass. |

The split matters: the root app only creates a wave once the previous one is **Synced + Healthy**, so
putting the cluster a wave later **guarantees** the operator's `Cluster` CRD is registered *and*
Longhorn's CSI driver is up before the `Cluster` CR / StorageClass is ever applied. No separate
wave-0 CRD app is needed (cf. the prometheus/VM operator CRDs) — the operator chart installs its own
CRDs at wave 2, before anything consumes them at wave 3.

> Note on numbering: the argo-app `NN` is the **sync-wave**; the top-level `.md` files (this is `17`)
> follow **runbook step order**. The two schemes are independent — the operator is argo-app `02` but
> this doc is `17`, exactly as Longhorn is argo-app `02` but doc `09`.

## The wrapper charts

Single source of truth, same pattern as every other app (`Chart.yaml` pins the version, `values.yaml`
is all config, `Chart.lock` is committed, vendored `charts/*.tgz` is gitignored):

| Path | Holds |
|------|-------|
| `argo_apps/charts/02_cnpg_operator/` | dep `cnpg/cloudnative-pg` **`0.28.3`** (app `1.29.1`); values under `cloudnative-pg:`. |
| `argo_apps/charts/03_cnpg_cluster/`  | dep `cnpg/cluster` **`0.7.0`**; values under `cluster:`; **plus** a first-party `templates/storageclass-longhorn-single.yaml`. |

Both pinned to the latest stable GA (verified against `cloudnative-pg.github.io/charts/index.yaml`).
The operator/Postgres images (`ghcr.io/cloudnative-pg/*`) are **multi-arch incl. arm64**, so they run
on the Pi 5s. Bump by editing the dependency in `Chart.yaml` and refreshing the lock — nothing is
hardcoded in a script.

> Values nesting (`03_cnpg_cluster`): the wrapper key is the dependency *name*, `cluster:`, and the
> upstream chart *itself* has a top-level `cluster:` map for the CR spec — hence `cluster.cluster.*`.
> That double key is expected, not a typo.

## The storage decision — a dedicated single-replica class

This is the heart of "CNPG backed by Longhorn". The naive choice is to put Postgres on the default
3-replica `longhorn` class. **Don't** — it stacks two replication layers:

- Postgres already replicates at the **database** layer across the 3 `Cluster` instances (1 primary +
  2 streaming replicas).
- Longhorn would then replicate each instance's volume **3 more times**.

Net: every write is stored 3 (Postgres) × 3 (Longhorn) = **9×**. On three small Pi NVMes that's a waste
of capacity and IO for no extra safety.

So `03_cnpg_cluster` ships a dedicated **`longhorn-single`** StorageClass and points the `Cluster` at
it:

```yaml
provisioner: driver.longhorn.io
reclaimPolicy: Retain          # deleting the PVC/Cluster never silently destroys DB data
parameters:
  numberOfReplicas: "1"        # one Longhorn replica; HA comes from Postgres failover
  dataLocality: "best-effort"  # keep that replica local to the Postgres pod (low-latency IO)
  fsType: "xfs"
```

With one local Longhorn replica per instance, a **node loss** still survives: the volume's data is
local-only, but Postgres promotes a surviving replica on another node, and CNPG re-provisions the lost
instance's volume from scratch via streaming replication. HA is Postgres's job here, not Longhorn's.

The class is a Longhorn resource but **ships with CNPG** to keep the whole database addition
self-contained (two new app dirs + this doc, nothing existing edited). The name is storage-generic so
other single-replica workloads can reuse it; Longhorn's CSI driver exists from wave 2, this app is
wave 3.

## Values worth calling out

**Operator** (`cloudnative-pg:` in `02_cnpg_operator/values.yaml`):

- **`crds.create: true`** — the operator chart owns the CNPG CRDs. Safe because wave 3 waits for this
  wave to be Healthy, so the CRDs exist before the `Cluster` CR is applied.
- **`monitoring.podMonitorEnabled: true`** — emits the controller's PodMonitor.
- modest `resources` — the controller only reconciles; the DB work is in the Postgres pods.

**Cluster** (`cluster.cluster.*` in `03_cnpg_cluster/values.yaml`):

- **`instances: 3`** — 1 primary + 2 replicas, one per Pi node.
- **`storage.storageClass: longhorn-single`**, `size: 10Gi`.
- **`affinity.topologyKey: kubernetes.io/hostname`** — the chart's default spreads by
  `topology.kubernetes.io/zone`, but bare Pi nodes carry no zone label, so all three instances could
  land on one node. Spreading by hostname forces the three onto three distinct nodes — the node-loss
  HA that the single-replica storage relies on.
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
credentials — out of scope here ("backed by Longhorn" = the data lives on Longhorn PVCs). Add later via
the `cnpg/plugin-barman-cloud` CNPG-I plugin and a [sealed-secret](07_sealed_secrets.md) for the S3
creds. Until then, durability rests on Postgres replication + the `Retain` reclaim policy; for real
PITR you'll want the backup plugin.

## Where it sits — waves 2 and 3

- **Operator = wave 2**, with the other independent leaves
  ([longhorn](09_longhorn.md) / [cert-manager](08_cert_manager.md) / sealed-secrets) — it only needs
  the CNI. Per [CLAUDE.md](CLAUDE.md) the `NN` prefix *is* the wave, so it carries `02_`.
- **Cluster = wave 3**, sharing the wave with [`gateway`](10_gateway.md) (distinct dir names, no mutual
  dependency). Wave 3 is the lowest wave that sits *after* both of the cluster's real dependencies
  (operator CRDs + Longhorn, both wave 2).

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
helm dependency build argo_apps/charts/02_cnpg_operator
helm dependency build argo_apps/charts/03_cnpg_cluster
helm template argo_apps/charts/02_cnpg_operator   # operator + 10 CRDs + PodMonitor render
helm template argo_apps/charts/03_cnpg_cluster     # Cluster CR + longhorn-single SC + PodMonitor render

# after commit/push — the root app picks up both apps and syncs them in wave order:
export KUBECONFIG=03_operating_system/talos-cluster/kubeconfig
kubectl -n cnpg-system rollout status deploy/cnpg-operator-cloudnative-pg   # operator Healthy (wave 2)
kubectl get storageclass longhorn-single                                    # dedicated SC present
kubectl -n databases get cluster                                            # Cluster CR (wave 3)
kubectl -n databases get pods                                               # 3 instances Running, one per node
kubectl -n databases get pvc -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName  # == longhorn-single
kubectl get vmpodscrape -A | grep -i cnpg                                   # metrics wired into VictoriaMetrics
```

End-to-end smoke test — prove the database accepts writes and survives a failover:

```bash
# (optional, needs the CNPG kubectl plugin) shows 1 primary + 2 replicas streaming:
kubectl cnpg status -n databases cnpg-cluster

# write/read directly inside the primary instance pod (local socket, superuser):
kubectl -n databases exec -it cnpg-cluster-1 -- psql -U postgres -d app \
  -c "CREATE TABLE IF NOT EXISTS smoke(t text); INSERT INTO smoke VALUES('hi'); SELECT * FROM smoke;"

# the app role's credentials for external clients live in the auto-generated Secret:
kubectl -n databases get secret cnpg-cluster-app \
  -o jsonpath='{.data.password}' | base64 -d; echo    # connect via the cnpg-cluster-rw service

# delete the primary pod and watch CNPG promote a replica (failover), then heal back to 3:
kubectl -n databases delete pod cnpg-cluster-1
kubectl -n databases get pods -w
```

## Caveats

- **Generate + commit both `Chart.lock`s before the apps sync.** No imperative bootstrap runs them —
  run `helm dependency build` on each chart yourself and commit, or the apps show `OutOfSync` with a
  `helm dependency build` error (same failure mode as a missing longhorn/cilium lock).
- **Push before you expect a sync.** ArgoCD reads git, not local disk — commit *and push*
  `argo_apps/**` (incl. both `Chart.lock`s) and `17_cnpg.md`, or the root app reports `ComparisonError`.
- **`reclaimPolicy: Retain` leaks volumes on teardown.** Deleting the `cnpg-cluster` app leaves the
  Longhorn volumes behind (by design — data safety). Clean them up manually (released PVs / Longhorn
  UI) if you really want the space back.
- **Single-replica storage means a node loss rebuilds that instance.** That's fine (Postgres
  re-streams it), but the rebuild reads a full base backup from a surviving instance — expect IO while
  it catches up. This is the deliberate trade vs. 9× write amplification.
- **No PITR until backups are wired.** `backups.enabled: false` — see the "No backups" section before
  trusting this with data you can't lose.
