# 09: Monitoring and observability

- VictoriaMetrics + VictoriaLogs are the metrics and logs backend, with one operator reconciling both.
- Grafana is the UI and the alerting front over them.
- metrics-server serves the narrow in-tree resource-metrics API (`kubectl top`, HPA) that the observability
  stack deliberately does not.

Ingress and SSO for each UI live in [07_ingress.md](07_ingress.md); storage classes in
[08_storage.md](08_storage.md).

## VictoriaMetrics and VictoriaLogs

vmagent (a Deployment, `selectAllByDefault`) scrapes everything into a `VMSingle`. A `victoria-logs-collector`
DaemonSet on all 3 nodes remote-writes to a `VLSingle`. The VM operator reconciles the VM* and VL* CRs and
converts prometheus-operator objects.

| | VMSingle (metrics) | VLSingle (logs) |
|---|---|---|
| Retention | 180d | 60d, since logs are bulkier |
| PVC | 50Gi `longhorn-r2-ephemeral` | 30Gi `longhorn-r2-ephemeral` |
| Written by | vmagent | `victoria-logs-collector` DaemonSet |
| UI | vmui | vlogs |
| Off-cluster | daily native export, `08_vm_backup` | daily LogsQL export, same CronJob |

Both are operator CRs, so one operator covers everything. The logs store is a `VLSingle`, not the standalone logs
chart. Metrics start fresh, with no `vmctl` backfill.

### Why VictoriaMetrics over Prometheus

One operator covers both metrics and logs, it is far lighter than Prometheus plus Loki on 8GB Pi 5 nodes, and it
is PromQL-compatible so dashboards and queries port unchanged.

### The prometheus-operator CRD converter

The operator's converter turns every existing `ServiceMonitor`, `PodMonitor`, `PrometheusRule` and `Probe` into
its VM equivalent with no rewrites. That is why the `monitoring.coreos.com` CRDs are kept: the wave-0
`00_prometheus_operator_crds` app is the converter's source and is not removable.

Scrape sources across the platform (node-exporter, kube-state-metrics, cilium and hubble, argocd, cert-manager,
longhorn, sealed-secrets, cnpg, metrics-server) all reach vmagent this way. The converter stamps ArgoCD-ignore
annotations on its output (`operator.prometheus_converter_add_argocd_ignore_annotations: true`) so ArgoCD never
fights or prunes operator-created objects.

### Grafana owns alerting, and the cluster carries NO rule CRs

`vmalert` and `vmalertmanager` are OFF. Grafana provisions the contact point, notification policy and alert rules
as code. No Alertmanager, and Grafana alert expressions are inlined PromQL.

Because nothing evaluates rule CRs with vmalert off, the invariant is that no `PrometheusRule` or `VMRule` exists
on the cluster: every one would be inert dead weight. So the stack's bundled default rules are disabled at the
source, and the RECORDING rules go too. Nothing evaluates them, so they would produce no series anyway, and no
dashboard or alert here queries a recorded series.

Chart-key gotcha, re-check on every vm-k8s-stack bump: the master toggle is `defaultRules.enabled: false`, and
the older `defaultRules.create` key is SILENTLY IGNORED. The chart also delivers rules via a sync-job, whose
objects are labelled `app.kubernetes.io/managed-by: sync-job` and are NOT ArgoCD-tracked, so prune will not clean
leftovers. A stray `enabled: true`, or a future rename, repopulates a large set of inert alerts unnoticed. After
any bump, confirm `kubectl get vmrule -A` is empty.

Other charts follow the same rule: bundled alerts stay OFF, and the coverage lives as a Grafana rule instead. For
example `02_sealed_secrets` sets `metrics.prometheusRule.enabled: false` and its coverage is the
`sealed-secrets-health` group; `lib/helm/pg-cluster` emits no `PrometheusRule` and its coverage is the `backups`
group.

### Talos control-plane scrapes, outside ArgoCD

kube-controller-manager (:10257), kube-scheduler (:10259), both https with a self-signed cert hence
`insecureSkipVerify`, and etcd (:2381, plain http via Talos `listen-metrics-urls`) are exposed via Talos machine
config, applied OUTSIDE ArgoCD because they are machine-level rather than a chart. They are scraped by static
`endpoints` at the control-plane node IPs. kube-proxy is off, since Cilium replaces it. The high-cardinality
apiserver and etcd histograms are dropped via `metricRelabelConfigs`.

### Deleting a store is a two-commit dance

Both CRs carry deletion protection, so a stray prune cannot reach them, and total loss is covered by the S3
export. To delete one deliberately, drop the protection first, sync, then remove it in a follow-up commit:

- VL: `deletionProtection: false` in `05_victoria_logs/values.yaml`.
- VMSingle and VMAgent: delete the `annotations:` block under each in
  `05_victoria_metrics_k8s_stack/values.yaml`. That block IS the flag, because `values.yaml` cannot be templated.

Never leave a store sitting unprotected. Off-cluster backup is opt-in via `make configure-vm-backup`; mechanism
and disaster recovery are in [13_backups.md](13_backups.md).

### Other decisions

- node-exporter and the log collector are DaemonSets with `tolerations: [{operator: Exists}]`. This is an
  all-control-plane cluster, so a `node-role.kubernetes.io/control-plane: DoesNotExist` selector would match ZERO
  nodes.
- Each UI (vmui, vlogs) is exposed by the platform-ingress app at wave 6 behind Google SSO, not by its own chart.
  The Hubble UI rides the same app. See [07_ingress.md](07_ingress.md).
- Cilium and Hubble ship Grafana dashboards: `hubble.metrics.dashboards.enabled` in `00_cilium` emits
  `grafana_dashboard` ConfigMaps that Grafana's sidecar picks up cluster-wide. See
  [04_networking.md](04_networking.md).

### Keeping the stores lean

Retention has ample PVC headroom, so the goal is dropping data that never gets charted or alerted, not avoiding
overflow. Exact drops and reasons live as comments where the config does.

Metrics: vmagent's `globalScrapeMetricRelabelConfigs` is the "drop everywhere regardless of job" list, and
per-target `metricRelabelConfigs` handle single-job families like the apiserver and etcd histograms and the
rabbitmq broker. Two exporter families are dropped globally: the RabbitMQ Erlang runtime internals and the
redis-exporter per-command latency buckets. Neither is charted or alerted. `lib/helm/pg-cluster` keeps only
`cnpg_pg_settings_setting{name="max_connections"}`, which the connection-saturation alert reads, and drops the
rest of the per-setting config dump. Alerting on another Postgres setting means widening that keep-list.

Logs: the `rabbitmq-messaging-topology-operator` was about 55% of all cluster log volume, logging
Start/declare/Finished at INFO per topology CR every `SYNC_PERIOD`. It runs at `logLevel: error`. That drops WARN
too, but failures still surface via CR status conditions, k8s events, and the `rabbitmq-health` alerts. The
collector also drops its own logs pre-read, via `excludeFilter` in `05_victoria_logs`.

### Loud lines nothing can drop

`excludeFilter` matches container METADATA (namespace, pod, container, labels) and runs BEFORE the log file is
opened, so it cannot match message text. Nothing else in the vlagent/VictoriaLogs ingest path drops a line by
content either (`ignoreFields` drops fields, not lines). So these three stay, about 6000 lines and 1.5MB a day:

| Pattern | Volume | What it is |
|---|---|---|
| kube-apiserver `grpc: addrConn.createTransport failed to connect to 127.0.0.1:2379` | 4300/d | the etcd health probe closing a connection mid-dial, once a minute per apiserver. Confirm with `talosctl etcd members` and service health before believing it means anything |
| longhorn-manager `Warning: v1 Endpoints is deprecated in v1.33+` | 1150/d | client-go warning on Longhorn's own API calls, gone when upstream migrates |
| argocd `DiffFromCache error: ... cache: key is missing` | 200/d | Argo logs the cache miss at ERROR, then just does a full diff |

None carries a `level` field, so none reaches the `high-error-log-rate` alert, which counts `level:error` and
`level=error` only. Ignore them when browsing vlogs, and do not widen that alert's NOT-list for them.

### Pinned versions

Chart versions live in each app's `Chart.yaml`, and Renovate groups the VictoriaMetrics charts so they bump
together. Two constraints:

- `victoria-metrics-operator-crds` and `victoria-metrics-operator` must ship the SAME operator app version, so
  bump them together.
- `00_prometheus_operator_crds` is the converter's source. Do not remove it.

## Grafana

Standalone `grafana/grafana` chart (release `grafana`, ns `monitoring`, chart `05_grafana`, no persistence): the
dashboards and Explore UI over the two datasources, and the owner of alerting. Run on its own rather than as the
k8s-stack subchart so it versions, syncs and rolls back independently, with no feature loss.

### Provisioned as code

Two datasources: VictoriaMetrics (type `prometheus`, uid `VictoriaMetrics`) and VictoriaLogs (the signed
`victoriametrics-logs-datasource` plugin, uid `VictoriaLogs`). The UIDs match the k8s-stack defaults so synced
dashboards resolve. The datasources sidecar is OFF, since they are provisioned inline. The dashboards sidecar
stays ON (`searchNamespace: ALL`) and ingests the k8s-stack's `grafana_dashboard` ConfigMaps on every start.

Alerting is NOT inline in `values.yaml`. The contact point (an ntfy webhook to the self-hosted `05_ntfy`), the
notification policy, and every rule group each live in their own file under `05_grafana/files/alerts/*.yaml`,
shipped as ConfigMaps labelled `grafana_alert` and loaded by the chart's alerts sidecar. The same model as
dashboards, so `values.yaml` stays small and each group is its own diffable file.

The files are read raw via `.Files.Get` rather than Helm-templated, so the Grafana `{{ $labels.x }}` and severity
templates are plain literals with no escaping needed.

Rules survive a restart, being provisioned. Alert STATE resets on restart, since there is no PVC.

### Alert content convention

Every rule carries exactly two annotations, and the ntfy payload maps them straight to the push:

- `summary` becomes the notification TITLE. Resource-first, one line, what is wrong. Lead with the faulty object,
  e.g. `Redis {{ $labels.namespace }}/{{ $labels.pod }} ...`. A genuinely cluster-scoped alert (API server 5xx,
  CoreDNS down, Cilium agent count) names the subsystem instead.
- `description` becomes the notification MESSAGE. Short `-` bullets, half-sentences: what is wrong plus how to
  fix, with a real `kubectl`, `redis-cli` or `cnpg` diagnosis command where it helps. Actionable and brief, no
  prose.

Two wiring choices make the resource actually arrive on the phone. A nameless "fragmentation high" alert was the
bug that prompted them:

- `policies.yaml` uses `group_by: ['...']`, grouping by all labels, so there is one notification per faulty
  resource.
- `contactpoints.yaml` reads PER-ALERT `.Annotations` via `(index .Alerts 0).Annotations.summary`, NOT
  `.CommonAnnotations`. The latter silently empties whenever two grouped alerts differ, which is exactly when you
  most need the name.

Add both annotations to every new rule.

### Alert severity model and the `alert-criticality` label

Alerts carry exactly two severities, `critical` and `warning`, never `info`, mapped by the ntfy webhook to
priority 5 and 4. Severity is a function of what broke times how important the component is:

| What the alert means | Component labelled `alert-criticality: critical` | Not labelled |
|---|---|---|
| Outage: workload down or broken so it cannot serve | critical | warning |
| Anomaly or about-to-break: degraded, saturating, restarting, near-limit, capacity | warning | warning |

So `critical` fires only when an outage-class alert triggers on a component that opted in with the label.
Everything else is `warning`. `Node NotReady` is the one static `critical`, being infra rather than a workload.

Opting a component in means putting `alert-criticality: critical` on it, and it must reach the object the firing
alert keys off:

- Plain Deployments, StatefulSets and DaemonSets: set it on BOTH the workload `metadata.labels` and the pod
  template `spec.template.metadata.labels`, so the object AND its pods carry it.
- CNPG Postgres: set `alertCritical: true` on the DB, per consumer alias. CNPG has no Deployment or StatefulSet,
  so the operator's `INHERITED_LABELS: alert-criticality` copies the label from the Cluster CR onto the Postgres
  pods, and the pod path is what pages. The wrapper always stamps the label, either critical or warning, so it is
  never absent.
- Redis: set `alertCritical: true` on the instance, and OpsTree propagates the CR label onto the StatefulSet and
  pods. Default `false`, because a plain cache being down usually just degrades.
- Ingress: the merged Envoy proxy pods are labelled critical in the EnvoyProxy (`envoyDeployment.pod.labels`), so
  a crashlooping ingress pod pages critical via `container-waiting-fatal`.

The label value is the self-documenting string `critical`; a numeric value would save nothing.

How the label drives severity: kube-state-metrics is told to expose it as a metric dimension via
`metricLabelsAllowlist`. It emits NO `kube_*_labels` without that, so the one setting both creates the join target
and adds the `label_alert_criticality` dimension. Each outage-class rule joins it into its series with
`<expr> * on(<keys>) group_left(label_alert_criticality) kube_<obj>_labels`, then sets severity with a per-instance
Grafana label template:

```yaml
severity: '{{`{{ if eq $labels.label_alert_criticality "critical" }}critical{{ else }}warning{{ end }}`}}'
```

An absent label evaluates to `""` and therefore `warning`. Anomaly-class rules skip the join and set `severity:
warning` statically.

### The global alert catalog

One rule per problem, all cluster-wide. Each group is its own file under `05_grafana/files/alerts/`.

| Group | Severity | Rules |
|---|---|---|
| `workload-outages` | dynamic | `deployment-not-available`, `statefulset-not-available`, `daemonset-not-available` (all: desired>0, 0 available), `container-waiting-fatal` (stuck 15m+ in CrashLoopBackOff, ImagePullBackOff or config error) |
| `workload-anomalies` | warning | `container-oomkilled`, `-high-restarts`, `-cpu-throttling`, `-memory-near-limit`, `pod-pending`, `pod-not-ready`, `replicaset-degraded`, `deployment-degraded`, `deployment-generation-mismatch`, plus 3 HPA rules, dormant until an HPA exists |
| `cluster-health` | warning, `node-not-ready` static critical | `node-disk-space`/`-inodes` (>85%), `node-disk-fill-predict` (24h), `node-high-memory` (>90%), `node-memory-committed` (requests >80% allocatable), `node-high-cpu`, `node-pressure`, `cluster-memory-overcommit` (cannot absorb one node loss), `pvc-nearly-full`, `target-down` |
| `storage-tls-health` | warning | `cert-expiring-soon` (<14d), `cert-not-ready`, `pv-errors`, `pvc-pending` |
| `longhorn-health` | mixed | `longhorn-manager-down` (critical deadman), `-node-down`, `-disk-unschedulable`, `-node-storage-high` (>85%), `-volume-degraded`, `-volume-faulted` (critical, 0 healthy replicas), `-volume-near-full` (>90%) |
| `argocd-health` | warning | `argocd-app-unhealthy` (15m), `argocd-app-out-of-sync` (30m), `argocd-app-comparison-error` |
| `cilium-health` | warning | `cilium-agent-down` (<3), `cilium-bpf-map-pressure` (>80%), `cilium-unreachable-nodes` |
| `control-plane` + `dns` | mixed | `apiserver-error-rate-high` (critical, >5% 5xx), `coredns-down` (<2), `coredns-serverfail-rate` (>2%) |
| `monitoring-health` | mixed | `vmsingle-near-read-only` (critical), `vmagent-dropping-samples`, `victorialogs-errors` |
| `sealed-secrets-health` | static critical | `sealed-secrets-not-ready` (10m). A down controller blocks ALL decryption cluster-wide |
| `ingress-http` | mixed, per route | `ingress-5xx-high` (>2%), `-4xx-high` (>25%), `-latency-p95-high` (>2s), `-no-healthy-upstream` (critical, the 503 cause), `-upstream-connect-failures` |
| `cnpg-health` | `cnpg-instance-not-ready` dynamic, rest warning | `-high-connections-*`, `-replication-lag-*`, `-txid-wraparound-*` (>300M, >1B), `-replication-slot-inactive`, `-long-running-transaction`, `-backends-waiting`, `-deadlocks`, `-manual-switchover-required`, `-fencing-on` |
| `rabbitmq-cluster` | static | `-cluster-down` and `-quorum-at-risk` (critical, <2 nodes), `-node-down` (warning, <3), `-memory-alarm` and `-disk-alarm` (critical, publishers already blocked), `-disk-low` |
| `rabbitmq-queues` | warning | `-queue-no-consumer`, `-queue-backlog` and `-queue-unacked` (>100), `-dlq-not-empty`, `-dead-letter-rate` |
| `redis-health` | `redis-down` dynamic, rest warning | `-memory-high` and `-memory-critical` (percent of maxmemory; noeviction, so writes fail near 100%), `-rejected-connections` and `-connections-high`, `-rdb-save-failing` and `-aof-write-failing`, `-fragmentation-high` |
| `backups` | warning, 2 critical | redis, longhorn, CNPG and VM/VL backup failure plus staleness, and the two unrecoverable-catalog rules. See [13_backups.md](13_backups.md) |
| `orphan` | warning | orphaned and untracked CNPG, Redis and VM/VL CRs, plus the exporter deadman. See [13_backups.md](13_backups.md) |

Notes worth knowing:

- `longhorn_volume_robustness` is state-labelled here (`{state="degraded|faulted|..."}=1`), not a numeric 0-3
  gauge, so those rules select on `state`.
- `ingress-http` groups by `envoy_cluster_name`, one per ingress-chart instance, so alerts are per-route. Error
  rules carry a small request-volume floor. Per-virtual-host downstream stats would need `enableVirtualHostStats`,
  left off, since the per-cluster stats already give per-route.
- A down component process is `target-down`, not a per-app rule. kube-scheduler and kube-controller-manager are
  NOT scraped, because the Talos machine-config metrics bind is not landing, so they have no alerts. Fix the
  scrape first.
- CNPG CPU, memory and disk fall to the generic container rules plus `node-disk-space` and `pvc-nearly-full`.

What this does and does not cover: outage-to-critical is guaranteed for Deployment, StatefulSet and DaemonSet
workloads, for any crashlooping labelled-critical container including CNPG, and for a CNPG instance that is up but
not serving. A CNPG pod not-ready in other ways still pages warning via `pod-not-ready`. The Envoy Deployment
object is not labelled, only its pods, so a graceful ingress scale-to-zero warns rather than pages.

### No persistence

`persistence.enabled: false`, an explicit requirement, safe because Grafana holds no state worth keeping:
datasources and curated dashboards re-provision each start, and alert rules are file-provisioned.

Trade-off: UI-created dashboards and settings, plus alert state, are lost on pod restart. Add a small `longhorn`
PVC if that ever matters. Deliberately not done.

### Anonymous Admin, gated by SSO

`auth.anonymous.enabled: true` with `org_role: Admin`, `disable_login_form: true`, basic auth off. Every request
reaches Grafana already authenticated at the edge by the Gateway's Google SSO and email allowlist, so there is no
second login.

Only safe because the edge gates it. Anonymous Admin means every SSO-allowlisted user is a full Grafana admin,
which is acceptable for a small trusted allowlist, and the gateway allowlist is the real boundary. Drop
`auth.anonymous.org_role` to `Viewer` if that is ever too broad.

### ntfy alerting, mobile push instead of email

Alerts go to your phone via self-hosted ntfy (`05_ntfy`), not email. Grafana's webhook contact point publishes to
the in-cluster ntfy Service on the `cluster-alerts` topic; the Android app subscribes over the public edge
`ntfy.ops.example.com` (`06_platform_ingress`).

That edge is on `letsencrypt-prod`, because the app validates TLS, and deliberately NOT behind Google SSO, because
the mobile app cannot do human OAuth. ntfy's own deny-all plus token and user auth is the gate.

The webhook payload maps the firing alert's `summary` to the push title and `description` to the push message.
Priority and tag come from `severity`: critical is 5, warning is 4.

ntfy is a private, deny-all instance with no declarative user config, so `lib/shell/10_ntfy_auth.sh` (`make
configure-ntfy-auth`, run post-boot once the pod is up) seeds two users on `cluster-alerts`:

- `phone`, read-only, password from `NTFY_PHONE_PASSWORD_SECRET` in `.env`.
- `grafana`, write-only.

It then mints and seals Grafana's write token into the `grafana-ntfy` Secret under key `token`, surfaced as
`GF_NTFY_TOKEN` and interpolated into the webhook's `authorization_credentials`. That env is optional, so Grafana
starts before the token is sealed. Leave `NTFY_PHONE_PASSWORD_SECRET` empty and the script offers to delete the
sealed token, disabling ntfy alerting.

This is the only imperative script for this step; the VM stack and metrics-server are pure GitOps. Grafana's
`grafana.ops.example.com` edge is served by the platform-ingress app at wave 6, not the `05_grafana` chart. See
[07_ingress.md](07_ingress.md).

### Verify

```bash
kubectl -n monitoring get deploy,pod -l app.kubernetes.io/name=grafana   # Running; no PVC
# Browse https://grafana.ops.example.com: Google SSO first, then straight into the UI as anonymous Admin.
# Connections -> Data sources shows VictoriaMetrics + VictoriaLogs; curated dashboards listed.
```

## metrics-server

The observability stack collects rich custom metrics but does NOT serve `metrics.k8s.io`, the narrow in-tree
resource-metrics contract that HPA, `kubectl top` and the scheduler expect from an aggregated APIService.
[metrics-server](https://github.com/kubernetes-sigs/metrics-server) fills exactly that gap: it scrapes each
kubelet's Summary API over HTTPS on `:10250` and registers `v1beta1.metrics.k8s.io`.

Thin wrapper chart at `argo_apps/platform/charts/02_metrics_server/`, single replica, 50m/100Mi, in `kube-system`.
It emits a ServiceMonitor for its own `/metrics`, which the VM operator's converter picks up like every other
leaf.

### `--kubelet-insecure-tls`

metrics-server verifies the kubelet serving cert by default. On Talos that cert is self-signed, so verification
fails. We set `--kubelet-insecure-tls`, which skips cert-identity verification while the connection stays
TLS-encrypted.

`--kubelet-preferred-address-types=InternalIP` is kept (the chart default), because the kubelet serving-cert SANs
are node IPs and Talos hostnames are not in DNS. `--kubelet-certificate-authority` is rejected for now: it only
works if the kubelet cert is CA-signed, which Talos does not do by default.

The security gain of the secure path is marginal here. It is a pod-to-kubelet hop on the cluster's own trusted,
NIC-hardened L2 (see [03_operating_system.md](03_operating_system.md)), and the connection is encrypted either
way. Only the cert identity goes unchecked, so we take the one-flag, zero-OS-change route.

The secure-path upgrade stays open. To drop the flag: add `rotate-server-certificates: true` to 03d's
`cp-patch.yaml` and re-apply to all three nodes, add a CSR-approver platform app (Kubernetes never auto-approves
`kubernetes.io/kubelet-serving` CSRs, and the Talos-documented `alex1989hu/...` ships raw kustomize which breaks
the wrapper-chart convention, so the Helm-native `postfinance/kubelet-csr-approver` with SAN and IP-regex config
is the fit), then swap the flag for
`--kubelet-certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`.

### Verify

```bash
export KUBECONFIG=secrets/kubeconfig
kubectl get apiservice v1beta1.metrics.k8s.io    # AVAILABLE: True
kubectl top nodes                                # the real end-to-end check
kubectl top pods -A
```

A TLS error from `kubectl top` despite `--kubelet-insecure-tls` is the signal to move to the secure path, not to
debug the flag.

## Rightsizing (KRR)

Two halves to catching over- and undersized containers, and the stack already provides one: continuous
visualization is the Grafana `k8s_views_pods` dashboard, usage vs requests, always on. What it does not give is a
concrete number to set.

[KRR](https://github.com/robusta-dev/krr) fills that gap: it reads usage history from the metrics store and
prints, per workload, the current request next to a recommended one for CPU and memory. Run it on demand with
`make krr` (table), `make krr-json`, or `make krr-yaml`. The script passes `"$@"` straight to KRR, so for any other
flag run it directly, e.g. `bash lib/shell/krr.sh -n <ns>`. It runs our custom `conservative` strategy by default;
the upstream `simple` and `simple-limit` still work.

### Why on-demand, not automated

At 3-node homelab scale, a handful of workloads and one operator, a weekly in-cluster CronJob plus a report store
plus a dedicated Robusta UI is overkill. `make krr` is the right-sized answer: run it when you want to retune,
read the table, hand-edit the relevant chart `values.yaml`.

It also matches the repo's tooling conventions. KRR runs dockerized like `talosctl()`, reaching the metrics store
over the same documented break-glass port-forward that `05_victoria_metrics_k8s_stack` already advertises, and the
kube API via the 03d kubeconfig. It reuses `MONITORING_NS` and adds no cluster workload, no ArgoCD app and no SSO
host.

### The `conservative` strategy

`lib/krr/conservative.py` is a custom KRR strategy for this cluster's scarce RAM. The built-in `simple` sets
memory `request == limit == peak + buffer`, but `request` is what the scheduler RESERVES, so requesting the peak
permanently books rarely-used memory and tanks pod density. `conservative` splits them:

- Memory request = max(average working-set, 16Mi). The scheduler packs on typical use, not peak, and the 16Mi
  floor reflects the idle working set so it does not overcommit.
- Memory limit = max(peak x 1.2, 32Mi), raised further to the OOMKilled limit plus 25% for any workload OOMKilled
  during the window (`--use-oomkill-data`, on by default). An OOMKill proves the ceiling was too low, and the
  bump lands on the limit, not the request.
- CPU unchanged from `simple`: request is the 95th percentile, no limit, because CPU is compressible.

The two memory floors are ASYMMETRIC (request 16Mi below limit 32Mi), which KRR's single `--mem-min` cannot
express, since it floors request and limit to the same value. So the floors live inside the strategy and `krr.sh`
runs with `--mem-min 0` to hand floor control to it.

Why split them: the request floor is a scheduling concern, reserving roughly the idle footprint, because too low
means node overcommit and eviction. The limit floor is OOM-safety headroom for cold-start and GC spikes. A low
request never OOM-kills a pod; only the limit does. Both are knobs at the top of `krr.sh`.

Deliberate trade-off: since requests no longer cover the peak, simultaneous peaks across pods can exhaust node RAM
and trigger a kernel or node-pressure OOMKill even while each pod is under its own limit. That is the price of the
density, so keep node eviction headroom and watch for OOMKills.

It loads without rebuilding the image: `lib/shell/krr.sh` bind-mounts `conservative.py` into the image's
`robusta_krr/strategies/` package plus a shadow `__init__.py` that imports it, so KRR's subclass discovery
registers it. Written against the pinned KRR's internals, so revisit both files on an image bump.

### Metrics dependency

`conservative` reads `container_cpu_usage_seconds_total` and `container_memory_working_set_bytes`, the latter via
both `max_over_time` and `avg_over_time`, plus `kube_pod_container_resource_limits` and
`kube_pod_container_status_last_terminated_reason` for the OOMKill floor.

All four are KEPT by vmagent's drop list, which is otherwise aggressive, so `--use-oomkill-data` has data here.
VictoriaMetrics speaks the Prometheus query API, so the queries run unchanged. If a future drop-list change removes
the OOM series the flag degrades gracefully, because that loader has `warning_on_no_data = False`, and simply stops
bumping limits.

### Docker networking note

The script runs KRR on the default bridge network rather than `--network host`, pointing at
`http://host.docker.internal:<port>`. On Docker Desktop and macOS a host-network container cannot see the
host-side port-forward, whereas the bridge reaches it via `host.docker.internal`. The kube API VIP is a LAN IP
reachable from the bridge via NAT.

### Verify

```bash
make krr    # a KRR table: workload | cpu request vs recommended | mem request vs recommended
# Expect no "metric not found" or connection-refused errors. Spot-check one row against the
# k8s_views_pods Grafana dashboard: measured usage should sit near KRR's recommended request.
```
