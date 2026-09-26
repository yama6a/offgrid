# Monitoring and observability

- VictoriaMetrics stores metrics and VictoriaLogs stores logs. One operator reconciles both.
- Grafana is the UI over both stores, and it owns alerting.
- metrics-server serves the resource-metrics API that `kubectl top` and the HPA (Horizontal Pod Autoscaler) read.
- KRR prints rightsizing numbers on demand.

Procedures are in [runbooks/06_monitoring.md](runbooks/06_monitoring.md). Ingress and SSO for each UI are in
[04_ingress.md](04_ingress.md).

## VictoriaMetrics and VictoriaLogs

- vmagent scrapes every target into a `VMSingle`, the single-node metrics store.
- A `victoria-logs-collector` DaemonSet sends container logs and the node's own logs to a `VLSingle`, the
  single-node logs store.
- The VM operator reconciles both stores as custom resources (CRs), so one operator covers everything.

| | VMSingle (metrics) | VLSingle (logs) |
|---|---|---|
| Retention | 180d | 60d, because logs are larger |
| PVC | 50Gi `longhorn-r2-ephemeral` | 30Gi `longhorn-r2-ephemeral` |
| Off-cluster | daily native export, `08_vm_backup` | daily LogsQL export, same CronJob |

Both stores carry deletion protection, so a stray prune cannot reach them. The S3 export covers total loss. See
[10_backups.md](10_backups.md).

### Why VictoriaMetrics over Prometheus

- One operator covers both metrics and logs.
- It is much lighter than Prometheus plus Loki on the 8GB Pi 5 nodes.
- It speaks PromQL, so dashboards and queries work unchanged.

The operator converts every `ServiceMonitor`, `PodMonitor` and `Probe` into its VM equivalent. So upstream charts
plug in with no rewrite, and the wave-0 `00_prometheus_operator_crds` app must stay as the converter's source.

### What lands in VictoriaLogs

One DaemonSet reads four sources from each node's filesystem. No extra log shipper runs.

| Source | Query it by |
|---|---|
| Container logs | `kubernetes.pod_namespace`, `kubernetes.pod_name`, `kubernetes.container_name` |
| Node system logs, Talos writes one file per service | `source:node`, `node`, `file` |
| Denied network flows from Hubble | `source:hubble`, `node`, `verdict` |
| kube-apiserver audit log | `source:kube-audit`, `node`, `verb`, `user.username` |

- **Denied flows.** Every app has a default-deny CiliumNetworkPolicy, so the usual failure is a connection that
  hangs. The Hubble `drop` metric only counts drops. The flow log names the denied pod, port and identity, so a
  timeout turns into the missing rule.
- **Audit log.** Talos logs every request at `Metadata` by default, about 1GB a day per node that nothing read.
  The machine config, outside this repo, narrows the policy to writes. It drops reads, `leases`, `events` and
  status updates, and keeps about 1.5% of the default volume: who created, changed or deleted what.
- **Never raise an audit rule to `Request` or `RequestResponse`.** Those levels write Secret and ConfigMap
  contents into a store that is not encrypted and is exported to S3.
- **Two gaps, by design.** Lines logged before the collector starts arrive late, once. A node that cannot mount
  its disk logs nowhere. Closing that gap needs a network log push from the machine config, for example Vector.

Logs are not a storage problem: all container logs write about 4.4MB a day against a 30Gi PVC. The collector
excludes two node files for volume: `auditd.log` at about 340MB a day per node, and `dns-resolve-cache.log` at
about 107MB a day. vlagent cannot drop lines by content, so a few known noisy lines stay. None carries a `level`
field, so none trips `high-error-log-rate`.

### Keeping the stores lean

The PVCs have headroom for the retention. The goal is to drop data that no chart or alert reads, not to avoid
overflow. Each drop and its reason is a comment next to the config.

- Cilium's `lxc<random>` veth names never repeat, so every pod restart creates permanent new series. This is the
  only unbounded growth, and both node-exporter and vmagent drop those interfaces.
- `dedup.minScrapeInterval: 60s` makes 60s the floor for every scrape.
- The audit log and the Hubble drops are filtered at their source, the apiserver policy and `00_cilium`. Widening
  either is what would fill the store.

### Control-plane scrapes

Many distributions bind kube-controller-manager, kube-scheduler and etcd metrics to localhost. Exposing them is a
machine config change outside this repo. vmagent scrapes them at the control-plane node IPs, which `04_values.sh`
reads from the cluster.

### Synthetic probes

`05_blackbox_exporter` fetches every ingress host once a minute over its public name. The `ingress-http` alerts read
Envoy's counters, which need real traffic. Without a probe, a host with a dead backend and no visitors stays green.
One probe covers DNS, the router's hairpin, the certificate and the route.

- A host behind SSO is checked only up to the edge. The probe also requires the redirect to point at Google, so a
  route that lost its SecurityPolicy fires an alert instead of going public unnoticed.
- The target lists are maintained by hand, on purpose. The expected status code is a per-host decision that the
  ingress definition does not carry. A new host in `06_platform_ingress` gets no probe until you add it.
- A group can use `tcp_connect` against a bare `host:port`, for example a NAS behind an NFS PV. Nothing else in
  the stack notices such an export going away. Give that group its own alert rule, because
  `ingress-probe-failing` matches only `https://` targets.

### SMART and node hardware

node-exporter reports a drive's temperature and nothing else: no wear, no spare blocks, no media errors. Every
volume is replicated onto these same disks, so a dying disk is the failure to catch earliest.
`05_smartctl_exporter` reads SMART from each node's real disk. Its device list is per architecture and written by
hand, because a scan would also probe Longhorn's iSCSI volumes.

The cluster mixes three arm64 Pi 5 nodes with one amd64 node. The same hwmon metric means SoC temperature on one
and chassis air on the other. So the hardware rules read thermal zones by driver type. A new platform adds its
zone type in `node-hardware.yaml`.

### Dashboards

- Upstream charts ship dashboards as `grafana_dashboard` ConfigMaps. The Grafana sidecar collects them from every
  namespace.
- This repo's own dashboards are JSON files in `05_grafana/files/dashboards/`: `hubble`, `ingress-http`,
  `persistent-volumes` and `cnpg`. An upstream dashboard assumes upstream's config, and several Cilium ones stay
  empty here. So this repo writes its own instead of patching upstream ones, which a chart bump would undo.
- `persistent-volumes` replaces the stack's one-PVC-at-a-time dashboard with all 13 volumes on one axis.
- `cnpg` is a fork of the upstream dashboard, not a rewrite. Its 66 panels are too many to re-author for a few
  broken queries. A chart bump needs the fork redone, see the runbook.

## Grafana

Grafana runs from the standalone `grafana/grafana` chart, not as the k8s-stack subchart. So it versions, syncs and
rolls back on its own, with no feature lost.

- **Provisioned as code.** Datasources are inline in `values.yaml`. The contact point, the notification policy
  and each rule group are one file each under `05_grafana/files/alerts/`, so each group has its own diff.
- **No persistence.** Grafana holds no state worth keeping, because everything above provisions again on start.
  A restart loses alert state and anything made in the UI. It runs one replica, because more replicas need
  `unified_alerting.ha_*` or each one sends every alert.
- **Anonymous Admin, gated by SSO.** Every request arrives already authenticated by the Gateway's Google SSO and
  email allowlist, so there is no second login. Every allowlisted user is a full Grafana admin. That is fine for a
  small trusted allowlist. Lower `auth.anonymous.org_role` to `Viewer` if it is ever too broad.

### Grafana owns alerting

`vmalert` and `vmalertmanager` are off. Grafana evaluates every rule, and there is no Alertmanager.

- One engine, one place for rules, one notification path.
- Nothing evaluates rule CRs. So no `PrometheusRule` or `VMRule` may exist on the cluster, because each would be
  inert. Every chart's bundled alerts stay off, and a Grafana rule gives the coverage instead.
- The stack's recording rules are off too. No dashboard or alert here reads a recorded series.

### Alert content

Every rule carries two annotations, and the ntfy payload maps them to the push notification:

- `summary` is the title. One line, faulty resource first, for example `Redis <ns>/<pod> ...`.
- `description` is the message. Short fragments: what is wrong and how to fix it, with a real diagnosis command.

Notifications group by every label, so each faulty resource gets its own push with its name in the title.

### `execErrState: KeepLast`

An evaluation error is not a firing alert. Under `execErrState: Error`, a rule that cannot run its query fires with
no labels. All rules share one datasource, so one vmsingle outage flips all of them at once. One node drain sent 51
firing and 51 resolved notifications in five minutes. None named a resource, and they buried the two real alerts.

So every rule sets `KeepLast` and holds its state through the gap. The one exception is `metrics-datasource-down`,
which keeps `Error` to report the outage as one notification.

The cost: a rule with a permanently broken query, for example after a chart bump renames a metric, stays silent.

### Severity model

Alerts are `critical` or `warning`, never `info`. ntfy maps them to priority 5 and 4.

| What the alert means | Component labelled `alert-criticality: critical` | Not labelled |
|---|---|---|
| Outage: down, or broken so it cannot serve | critical | warning |
| Anomaly: degraded, saturating, near a limit | warning | warning |

A component opts in with the label, so only an outage of something that matters wakes you. kube-state-metrics
exposes the label, and each outage rule joins it in. Two node-level alerts are always critical: `Node NotReady` and
`node-undervoltage`, the one hardware fault that corrupts data.

### ntfy for phone push

Alerts go to a phone through self-hosted ntfy (`05_ntfy`), not email. Grafana publishes to the in-cluster ntfy
Service. The Android app subscribes over the public edge `ntfy.ops.example.com`.

- The edge is not behind Google SSO, because the mobile app cannot do an OAuth login. ntfy's deny-all default
  with per-user tokens is the gate.
- The edge uses `letsencrypt-prod`, because the app validates TLS.
- ntfy has no declarative user config, so `06_ntfy_auth.sh` seeds the users and seals Grafana's write token.

### Watching the alert path

The chain is Grafana to ntfy to phone. If it breaks, the part that would tell you is the part that broke. Three
checks cover pieces of it:

- ntfy exposes metrics on a separate listener, so a dead ntfy fires `target-down`.
- `alert-delivery-failing` counts Grafana's failed webhook calls, for example a wrong topic or an expired token.
- The blackbox probe covers the public edge the phone uses.

None of these can page you, because each depends on the path it tests. They leave a record in Grafana. Closing
the gap needs a receiver outside the cluster, which this repo does not run.

## metrics-server

The observability stack does not serve `metrics.k8s.io`, the API that the HPA, `kubectl top` and the scheduler
expect. metrics-server fills that gap by scraping each kubelet.

It runs with `--kubelet-insecure-tls`, because Talos kubelet serving certs are self-signed. The connection stays
TLS-encrypted, and only the cert identity goes unchecked. The hop is pod to kubelet on the cluster's own wired
network, so the one flag was chosen over an OS change and a CSR approver. The runbook covers the secure path.

## Rightsizing with KRR

- The Grafana `k8s_views_pods` dashboard always shows usage against requests, but gives no number to set.
- [KRR](https://github.com/robusta-dev/krr) reads usage history and prints a recommended request per workload.

KRR runs on demand in Docker through `make krr`. A weekly in-cluster CronJob with a report store and a UI is too
much for a few workloads and one operator. It adds no cluster workload, no Argo CD app and no SSO host.

It runs a custom `conservative` strategy (`lib/krr/conservative.py`). The built-in strategy sets the memory request
to the peak. The scheduler reserves the full request, so on 8GB nodes that books memory that is rarely used.
`conservative` sets the request to average use and the limit to 1.5 times the peak. The cost: several pods peaking
together can exhaust node RAM and trigger an OOMKill under each pod's own limit. Keep eviction headroom and watch
for OOMKills.
