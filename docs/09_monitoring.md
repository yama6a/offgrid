# 09: Monitoring & observability

VictoriaMetrics + VictoriaLogs are the metrics+logs backend (one operator reconciles both), Grafana
is the UI and alerting front over them, and metrics-server serves the narrow in-tree resource-metrics
API (`kubectl top`, HPA) that the observability stack deliberately doesn't. Ingress and SSO for each UI
live in [07_ingress.md](07_ingress.md); storage classes in [08_storage.md](08_storage.md).

## VictoriaMetrics & VictoriaLogs

vmagent (Deployment, `selectAllByDefault`) scrapes everything into a `VMSingle` (1x, 50Gi longhorn PVC,
180d retention) exposed via vmui. A `victoria-logs-collector` DaemonSet on all 3 nodes remote-writes to a
`VLSingle` (1x, 30Gi longhorn PVC, 60d retention) exposed via vlogs. The VM operator reconciles the VM*/VL*
CRs and converts prometheus-operator objects.

### Why VictoriaMetrics over Prometheus
One operator covers both metrics (VM*) and logs (VL*), far lighter than Prometheus+Loki on 8GB Pi 5 nodes,
and PromQL-compatible so dashboards/queries port unchanged.

### The prometheus-operator CRD converter
The operator's prometheus converter turns every existing `ServiceMonitor`/`PodMonitor`/`PrometheusRule`/`Probe`
into its VM equivalent (`VMServiceScrape`/`VMPodScrape`/...) with no rewrites. That is why the coreos
`monitoring.coreos.com` CRDs are kept, the wave-0 `00_prometheus_operator_crds` app is the converter's
source, not removable. Scrape sources across the platform (node-exporter, kube-state-metrics, cilium/hubble,
argocd, cert-manager, longhorn, sealed-secrets, cnpg, metrics-server, ...) all reach vmagent this way. The
converter stamps ArgoCD-ignore annotations on its output
(`operator.prometheus_converter_add_argocd_ignore_annotations: true`) so ArgoCD never fights or prunes
operator-created objects.

### Grafana owns alerting
`vmalert` and `vmalertmanager` are OFF; Grafana provisions the contact point + notification policy + alert
rules as code (see below). No Alertmanager. Dropping vmalert means the stack's default recording/alerting
VMRules are not created (`defaultRules.create: false`); Grafana alert expressions are inlined PromQL.

### Talos control-plane scrapes (outside ArgoCD)
kube-controller-manager (:10257), kube-scheduler (:10259) (both https, self-signed → `insecureSkipVerify`)
and etcd (:2381, plain http, Talos `listen-metrics-urls`) are exposed via **Talos machine config, applied
OUTSIDE ArgoCD** — they're machine-level, not a chart — and scraped by static `endpoints` at the CP node IPs
(192.168.10.201-203). kube-proxy is OFF (Cilium replaces it). apiserver/etcd high-cardinality histograms are
dropped via `metricRelabelConfigs`.

### Other decisions
Both VMSingle and VLSingle PVCs use the `longhorn-r2-retained` class (r2, `Retain` — survives an accidental
delete, but not a total loss). Off-cluster S3 backup of both stores is opt-in via `make configure-vm-backup`
(a daily native-export CronJob, `08_vm_backup`); mechanism + disaster recovery are in
[13_backups.md](13_backups.md) ("VictoriaMetrics / VictoriaLogs backups"). Metrics retention 180d, logs 60d
(logs are bulkier, their own shorter window). Metrics start fresh (no `vmctl` backfill). The logs store is
the operator `VLSingle` CR (one operator for everything), not the standalone logs chart. node-exporter and
the log collector are DaemonSets with `tolerations: [{operator: Exists}]` — this is an all-control-plane
cluster, so a `node-role.kubernetes.io/control-plane: DoesNotExist` selector would match ZERO nodes.

Each UI (vmui, vlogs) is exposed by the consolidated platform-ingress app (wave 6) behind Google SSO,
not by its own chart; see [07_ingress.md](07_ingress.md). The Hubble UI (`hubble.<domain>`) rides the same
platform-ingress app. Cilium/Hubble also ships Grafana dashboards: `hubble.metrics.dashboards.enabled` in
`00_cilium` emits `grafana_dashboard` ConfigMaps that this stack's Grafana sidecar picks up cluster-wide (see
[04_networking.md](04_networking.md)).

### Pinned versions

Chart versions live in each app's `Chart.yaml` (Renovate groups the VictoriaMetrics charts —
operator-crds, operator, k8s-stack, logs-collector — and bumps them together). Two constraints:

- `victoria-metrics-operator-crds` and `victoria-metrics-operator` must ship the SAME operator app
  version; bump them together.
- `00_prometheus_operator_crds` is kept as the converter's source — do not remove it.

## Grafana

Standalone `grafana/grafana` chart (release `grafana`, ns `monitoring`, chart `05_grafana`, no persistence):
the dashboards/Explore UI over the two datasources and the owner of alerting. Run on its own rather than as
the k8s-stack subchart so it versions/syncs/rolls back independently, no feature loss.

### Provisioned as code
- Two datasources: VictoriaMetrics (type `prometheus`, uid `VictoriaMetrics`) and VictoriaLogs (the signed
  `victoriametrics-logs-datasource` plugin, uid `VictoriaLogs`). UIDs match the k8s-stack defaults so synced
  dashboards resolve. The **datasources sidecar is OFF** (provisioned directly); the **dashboards sidecar
  stays ON** (`searchNamespace: ALL`) and ingests the k8s-stack's `grafana_dashboard` ConfigMaps on every
  start.
- **Alerting is NOT inline in `values.yaml`.** The contact point (an **ntfy webhook** → self-hosted ntfy,
  `05_ntfy`), notification policy, and every rule group each live in their own file under
  `05_grafana/files/alerts/*.yaml`, shipped as ConfigMaps (`templates/alerts-configmaps.yaml`, label
  `grafana_alert`) and loaded by the chart's **alerts sidecar** (`sidecar.alerts.enabled`) — the SAME model as
  dashboards, so `values.yaml` stays small and each group is its own diffable file. The files are read raw via
  `.Files.Get` (not Helm-templated), so the Grafana `{{ $labels.x }}` / severity templates are plain literals
  (no `{{`…`}}` escaping). Groups: `cluster-health` (node NotReady/pressure, node mem/CPU/disk/inodes,
  disk-fill-predict, memory committed + cluster overcommit, PVC >85%, target down), `workload-outages` +
  `workload-anomalies` (the global k8s object alerts — see the severity model below), `storage-tls-health`
  (cert-manager TLS expiry/ready, Longhorn volume degraded/faulted, PV/PVC errors), `backups` (redis + longhorn
  + VM/VL + CNPG backup health), `cnpg-health`, `rabbitmq-cluster` + `rabbitmq-queues`, `redis-health`,
  `longhorn-health` (see the per-service catalog below), plus a VictoriaLogs error-rate
  alert. Rules survive restart (provisioned); alert *state* resets on restart (no PVC). (Datasources, by
  contrast, are still provisioned inline in `values.yaml` — the datasources sidecar is OFF.)

### Alert severity model & the `alert-criticality` label

Alerts carry exactly two severities — **`critical`** and **`warning`** (never `info`) — mapped by the ntfy
webhook to priority 5 / 4. Severity is a function of **what broke** × **how important the component is**:

| Alert semantics | Component labeled `alert-criticality: critical` | Not labeled |
|---|---|---|
| **Outage** — workload down / broken so it can't serve | **critical** | warning |
| **Anomaly / about-to-break** — degraded, saturating, restarting, near-limit, capacity | warning | warning |

So `critical` fires only when an *outage-class* alert triggers on a component that has opted in with the
`alert-criticality: critical` label. Everything else is `warning`. `Node NotReady` is the one static
`critical` (infra, not a workload).

**Opting a component in.** Put `alert-criticality: critical` on the workload. It must reach the object the
firing alert keys off:

- **Plain Deployments/StatefulSets/DaemonSets** (e.g. the sample apps): set it on BOTH the workload
  `metadata.labels` *and* the pod template `spec.template.metadata.labels` (so the object AND its pods carry
  it). See `argo_apps/workloads/charts/*/templates/app.yaml`.
- **CNPG Postgres**: set `cluster.cluster.additionalLabels.alert-criticality: critical` on the DB (per
  consumer/alias). CNPG has no Deployment/StatefulSet, so the operator's `INHERITED_LABELS: alert-criticality`
  (`02_cnpg_operator`) copies it from the Cluster CR onto the Postgres pods — the pod path is what pages.
- **Redis** (`lib/helm/redis-instance`): set `alertCritical: true` on the instance; OpsTree propagates the CR
  label onto the StatefulSet + pods. Default `false` — a plain cache being down usually just degrades.
- **Ingress** (`01_envoy_gateway`): the merged Envoy proxy pods are labeled `critical` in the EnvoyProxy
  (`envoyDeployment.pod.labels`) — a crashlooping ingress pod pages `critical` via `container-waiting-fatal`.

The label value is the self-documenting string `critical` (a numeric value would save nothing).

**Mechanism (how the label drives severity).** kube-state-metrics is told to expose the label as a metric
dimension via `metricLabelsAllowlist` (`05_victoria_metrics_k8s_stack`) — modern KSM emits NO `kube_*_labels`
without this, so that one setting both *creates* the join target and *adds* the `label_alert_criticality`
dimension. Each outage-class rule joins it into its series
(`<expr> * on(<keys>) group_left(label_alert_criticality) kube_<obj>_labels`) and sets severity with a
per-instance Grafana label template:

```yaml
severity: '{{`{{ if eq $labels.label_alert_criticality "critical" }}critical{{ else }}warning{{ end }}`}}'
```

An absent label evaluates to `""` → `warning`. Anomaly-class rules skip the join and set `severity: warning`
statically.

**The global alert catalog** (all cluster-wide, one rule per problem, in `05_grafana/values.yaml`):

- **`workload-outages`** (dynamic severity): `deployment-not-available`, `statefulset-not-available`,
  `daemonset-not-available` (all: desired>0 but 0 available), `container-waiting-fatal` (stuck ≥15m in
  CrashLoopBackOff / ImagePullBackOff / config error). The old warning-only `pod-crashloop` was folded into
  `container-waiting-fatal`.
- **`workload-anomalies`** (warning): `container-oomkilled`, `container-high-restarts`,
  `container-cpu-throttling`, `container-memory-near-limit`, `pod-pending`, `pod-not-ready`,
  `replicaset-degraded`, `deployment-degraded` (partial), `deployment-generation-mismatch`, and HPA
  (`hpa-at-max`, `hpa-scaling-blocked`, `hpa-below-min` — dormant until an HPA exists).
- **`cluster-health`** node/cluster alerts (warning, plus the static-critical `node-not-ready`):
  `node-disk-space`/`node-disk-inodes` (>85%), `node-disk-fill-predict` (fills within 24h), `node-high-memory`
  (>90%), `node-memory-committed` (requests >80% allocatable), `node-high-cpu`, `node-pressure`
  (Memory/Disk/PID), `cluster-memory-overcommit` (can't absorb one node loss), `pvc-nearly-full`, `target-down`.
- **`storage-tls-health`** (warning): `cert-expiring-soon` (<14d), `cert-not-ready`, `pv-errors`, `pvc-pending`.
- **`longhorn-health`** (distributed storage): `longhorn-manager-down` (critical, dead-man — metrics absent),
  `longhorn-node-down` (warning — Longhorn node NotReady; the hard k8s node loss is `node-not-ready`),
  `longhorn-disk-unschedulable`, `longhorn-node-storage-high` (>85%), `longhorn-volume-degraded` (warning) /
  `longhorn-volume-faulted` (**critical** — 0 healthy replicas), `longhorn-volume-near-full` (>90%). NOTE:
  `longhorn_volume_robustness` is **state-labelled** here (`{state="degraded|faulted|..."}=1`), not a numeric
  0–3 gauge — the degraded/faulted rules were moved here from `storage-tls-health` and fixed (the old
  `== 2`/`== 3` never matched). Backup health stays in `backups` (`longhorn-backup-failed`/`-stale`).
- **`cnpg-health`** (CNPG Postgres): `cnpg-instance-not-ready` (**dynamic severity** — `cnpg_collector_up==0`,
  the CNPG outage signal, joined to the criticality label like the workload-outages rules), plus warnings:
  `cnpg-high-connections-*` (saturation vs `max_connections`), `cnpg-replication-lag-*` (physical lag),
  `cnpg-txid-wraparound-warning/critical` (xid age >300M/>1B — forced-shutdown risk), `cnpg-replication-slot-inactive`
  (WAL-retention risk), `cnpg-long-running-transaction`, `cnpg-backends-waiting` (lock contention),
  `cnpg-deadlocks`, `cnpg-manual-switchover-required`, `cnpg-fencing-on`. WAL-archiving + base-backup staleness
  live in the `backups` group; CPU/mem and disk fall to the generic container + `node-disk-space`
  (`/var/mnt/localpath`) / `pvc-nearly-full` rules.
- **`rabbitmq-cluster`** (shared broker, static severity): `rabbitmq-cluster-down` / `rabbitmq-quorum-at-risk`
  (critical, <2 nodes) / `rabbitmq-node-down` (warning, <3), `rabbitmq-memory-alarm` / `rabbitmq-disk-alarm`
  (critical — the broker has already blocked publishers), `rabbitmq-disk-low` (early warning). Metrics come
  from the broker PodMonitor added by `03_rabbitmq` (scrapes `:15692` `/metrics`).
- **`rabbitmq-queues`** (per-queue, from the broker's `/metrics/detailed`): `rabbitmq-queue-no-consumer`,
  `rabbitmq-queue-backlog`/`rabbitmq-queue-unacked` (>100), `rabbitmq-dlq-not-empty` (a DLQ holds messages —
  names the failing flow), `rabbitmq-dead-letter-rate` (cluster-wide dead-lettering). DLQs are excluded from
  the consumer/backlog rules.
- **`redis-health`** (per-instance redis-exporter): `redis-down` (**dynamic severity** — `redis_up==0` joined
  to the criticality label, like `cnpg-instance-not-ready`), `redis-memory-high`/`redis-memory-critical`
  (%-of-maxmemory; noeviction → writes fail near 100%), `redis-rejected-connections`/`redis-connections-high`
  (maxclients), `redis-rdb-save-failing`/`redis-aof-write-failing` (persistence), `redis-fragmentation-high`.

**Coverage nuance.** Outage→`critical` is guaranteed for Deployment/StatefulSet/DaemonSet workloads (incl. the
sample apps and Redis's StatefulSet), for any crashlooping labeled-critical container (incl. CNPG), and for a
CNPG instance that is up-but-not-serving (`cnpg-instance-not-ready`, dynamic). A CNPG pod not-ready in other
ways still pages `warning` via `pod-not-ready`. The Envoy *Deployment* object isn't labeled (only its pods), so
a graceful ingress scale-to-zero warns rather than pages.

### No persistence (`persistence.enabled: false`)
Explicit requirement, safe because Grafana holds no state worth keeping: datasources + curated dashboards
re-provision each start, alert rules are file-provisioned. Trade-off: UI-created dashboards/settings and
alert state are lost on pod restart. Add a small `longhorn` PVC if that ever matters; deliberately not done.

### Anonymous Admin, gated by SSO
`auth.anonymous.enabled: true` with `org_role: Admin`, `disable_login_form: true`, basic auth off. Every
request reaches Grafana already authenticated at the edge (the Gateway's Google SSO + email allowlist), so
there's no second login. This is only safe because the edge gates it: anonymous Admin means every
SSO-allowlisted user is a full Grafana admin — acceptable for a small trusted allowlist, the gateway
allowlist is the real boundary. Drop `auth.anonymous.org_role` to `Viewer` if that's ever too broad.

### ntfy alerting (mobile push, replaces email)
Alerts go to your phone via self-hosted **ntfy** (`05_ntfy`), not email. Grafana's webhook contact point publishes
to the in-cluster ntfy Service on the `cluster-alerts` topic; the Android app subscribes over the public edge
`ntfy.ops.example.com` (`06_platform_ingress`, on `letsencrypt-prod` — the app validates TLS — and deliberately
**not** behind Google SSO, since the mobile app can't do human OAuth; ntfy's own deny-all + token/user auth is the gate).

ntfy is a private, deny-all instance with no declarative user config, so `lib/shell/10_ntfy_auth.sh` (`make
configure-ntfy-auth`, run post-boot once the pod is up) seeds two users on `cluster-alerts` — `phone` (read-only,
password from `NTFY_PHONE_PASSWORD_SECRET` in `.env`) and `grafana` (write-only) — and mints + **seals** Grafana's
write token into the `grafana-ntfy` Secret (key `token`), surfaced as `GF_NTFY_TOKEN` and interpolated into the
webhook's `authorization_credentials` (optional env, so Grafana starts before it's sealed). Leave
`NTFY_PHONE_PASSWORD_SECRET` empty and the script offers to delete the sealed token (disables ntfy alerting).
This is the only imperative script for this step; the VM stack and metrics-server are pure GitOps.

Grafana's `grafana.ops.example.com` edge (Gateway + Certificate + SSO HTTPRoute) is served by the consolidated
platform-ingress app (wave 6), not the `05_grafana` chart; see [07_ingress.md](07_ingress.md).

### Verify
```bash
kubectl -n monitoring get deploy,pod -l app.kubernetes.io/name=grafana   # Running; no PVC
# Browse https://grafana.ops.example.com -> Google SSO first, then straight into the UI (anonymous Admin).
# Connections -> Data sources shows VictoriaMetrics + VictoriaLogs; curated dashboards listed.
```

## metrics-server

The observability stack collects rich custom metrics but does **not** serve `metrics.k8s.io`, the narrow
in-tree resource-metrics contract that HPA, `kubectl top`, and the scheduler expect from an aggregated
APIService. [metrics-server](https://github.com/kubernetes-sigs/metrics-server) fills exactly that gap: it
scrapes each kubelet's Summary API over HTTPS (`:10250`) and registers `v1beta1.metrics.k8s.io`. Thin
wrapper chart at `argo_apps/platform/charts/02_metrics_server/` (chart pinned in `Chart.yaml`),
single replica, 50m/100Mi, runs in `kube-system`. It emits a ServiceMonitor for its own `/metrics`, which
the VM operator's converter picks up like every other leaf.

### `--kubelet-insecure-tls`
metrics-server verifies the kubelet serving cert by default. On Talos that cert is self-signed, so
verification fails. We set `--kubelet-insecure-tls` (skip cert-identity verification; the connection stays
TLS-encrypted). `--kubelet-preferred-address-types=InternalIP` is kept (chart default; the kubelet
serving-cert SANs are node IPs and Talos hostnames aren't in DNS). `--kubelet-certificate-authority` is
rejected for now — it only works if the kubelet cert is CA-signed, which Talos doesn't do by default.

The security gain of the secure path is marginal here: it's a pod→kubelet hop on the cluster's own trusted,
NIC-hardened L2 (see [03_operating_system.md](03_operating_system.md)), and the connection is encrypted
either way — only the cert identity goes unchecked. So we take the one-flag, zero-OS-change route.

> **Secure-path upgrade (stays open):** to drop `--kubelet-insecure-tls`, add
> `rotate-server-certificates: true` to 03d's `cp-patch.yaml` (re-applied to all three nodes), add a
> CSR-approver platform app (Kubernetes never auto-approves `kubernetes.io/kubelet-serving` CSRs; the
> Talos-documented `alex1989hu/...` ships raw kustomize, breaking the wrapper-chart convention, so the
> Helm-native `postfinance/kubelet-csr-approver` with SAN/IP-regex config is the fit), then swap the flag
> for `--kubelet-certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`.

### Verify
```bash
export KUBECONFIG=secrets/kubeconfig
kubectl get apiservice v1beta1.metrics.k8s.io    # AVAILABLE: True
kubectl top nodes                                # the real end-to-end check
kubectl top pods -A
```
A TLS error from `kubectl top` despite `--kubelet-insecure-tls` is the signal to move to the secure path,
not to debug the flag.

## Rightsizing (KRR)

Two halves to catching over-/undersized containers, and the stack already provides one: **continuous
visualization** is the Grafana `k8s_views_pods` dashboard (usage vs requests, always on). What it doesn't give
is a concrete number to set. [KRR](https://github.com/robusta-dev/krr) (Robusta Kubernetes Resource
Recommender) fills that gap: it reads usage history from the metrics store and prints, per workload, the
current request next to a recommended one for CPU and memory. Run it on demand: `make krr` (table),
`make krr-json`, or `make krr-yaml`. The script passes `"$@"` straight to KRR, so for any other flag (e.g.
`-n <ns>` to scope) run it directly: `bash lib/shell/krr.sh -n <ns>`. It runs our custom **`conservative`**
strategy by default (see below); the upstream `simple`/`simple-limit` still work
(`bash lib/shell/krr.sh` with `KRR_STRATEGY` edited, or `--help` on either).

### Why on-demand, not automated
At 3-node homelab scale — a handful of workloads, one operator — a weekly in-cluster CronJob + a report store
+ a dedicated Robusta UI is overkill. `make krr` is the right-sized answer: run it when you want to retune,
read the table, hand-edit the relevant chart `values.yaml`. It matches the repo's existing tooling
conventions — KRR runs **dockerized** (like `talosctl()`), reaching the metrics store over the same
documented break-glass port-forward (`kubectl -n monitoring port-forward svc/vmsingle-... 8428:8428`) that
`05_victoria_metrics_k8s_stack` already advertises, and the kube API via the 03d kubeconfig. Reuses
`MONITORING_NS`; adds no cluster workload, no ArgoCD app, no SSO host.

### The `conservative` strategy (custom, RAM-frugal)
`lib/krr/conservative.py` is a custom KRR strategy for this cluster's scarce RAM (3x 8GB). The built-in
`simple` sets memory `request == limit == peak + buffer`; but `request` is what the scheduler **reserves**, so
requesting the peak permanently books rarely-used memory and tanks pod density. `conservative` splits them:

- **memory request = max(average working-set, 16Mi)** — scheduler packs on typical use, not peak; the 16Mi
  floor (`--memory-request-min`) reflects the idle working set so the scheduler doesn't overcommit,
- **memory limit = max(peak × 1.2, 32Mi)** (`--memory_limit_buffer_percentage` + `--memory-limit-min`), raised
  further to the **OOMKilled limit + 25%** for any workload OOMKilled during the window (`--use-oomkill-data`,
  on by default — an OOMKill proves the ceiling was too low; the bump lands on the limit, not the request),
- **CPU unchanged** from `simple` (request = 95th percentile, no limit — CPU is compressible).

The two memory floors are **asymmetric** (request 16Mi < limit 32Mi), which KRR's single `--mem-min` can't
express — it floors request and limit to the *same* value. So the floors live inside the strategy
(`lib/krr/conservative.py`) and `krr.sh` runs with `--mem-min 0` to hand floor control to it. Rationale for
splitting them: the *request* floor is a scheduling concern (reserve ~the idle footprint; too low → node
overcommit + eviction-prone), while the *limit* floor is the OOM-safety headroom (cold-start/GC spikes) — a
low request never OOM-kills a pod, only the limit does. Both are knobs at the top of `krr.sh`
(`KRR_REQ_MIN`, `KRR_LIM_MIN`).

Deliberate trade-off: since requests no longer cover the peak, simultaneous peaks across pods can exhaust node
RAM and trigger a kernel/node-pressure OOMKill even while each pod is under its own limit. That's the price of
the density; keep a node eviction headroom and watch for OOMKills.

It loads without rebuilding the image: `lib/shell/krr.sh` bind-mounts `conservative.py` into the image's
`robusta_krr/strategies/` package plus a shadow `__init__.py` (`lib/krr/strategies_init.py`) that imports it,
so KRR's `__subclasses__()` discovery registers it. Written against the pinned KRR's internals — revisit both
files on an image bump.

### Metrics dependency
`conservative` reads `container_cpu_usage_seconds_total` and `container_memory_working_set_bytes` (the latter
via both `max_over_time` and `avg_over_time`), plus — for the OOMKill floor — `kube_pod_container_resource_limits`
and `kube_pod_container_status_last_terminated_reason`. All four are **kept** by vmagent's `metricRelabelConfigs`
drop list (the drops are otherwise aggressive), so `--use-oomkill-data` has data on this cluster. VictoriaMetrics
speaks the Prometheus query API, so the queries run unchanged. If a future drop-list change removes the OOM
series the flag degrades gracefully (that loader has `warning_on_no_data = False`), just stops bumping limits.

### Docker networking note
The script runs KRR on the **default bridge network** (not `--network host`) pointing at
`http://host.docker.internal:<port>`: on Docker Desktop/macOS a host-network container can't see the
host-side port-forward, whereas the bridge reaches it via `host.docker.internal`; the kube API VIP is a LAN
IP reachable from the bridge via NAT.

### Verify
```bash
make krr    # prints a KRR table: workload | cpu request->recommended | mem request->recommended
# Expect no "metric not found" / connection-refused errors. Spot-check one row against the
# k8s_views_pods Grafana dashboard — measured usage should sit near KRR's recommended request.
```
