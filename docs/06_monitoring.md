# Monitoring and observability

- VictoriaMetrics + VictoriaLogs are the metrics and logs backend, with one operator reconciling both.
- Grafana is the UI and the alerting front over them.
- metrics-server serves the narrow in-tree resource-metrics API (`kubectl top`, HPA) that the observability
  stack deliberately does not.

Ingress and SSO for each UI live in [04_ingress.md](04_ingress.md); storage classes in
[05_storage.md](05_storage.md).

## VictoriaMetrics and VictoriaLogs

vmagent (a Deployment, `selectAllByDefault`) scrapes everything into a `VMSingle`. A `victoria-logs-collector`
DaemonSet on every node remote-writes to a `VLSingle`: container logs plus the node's own Talos logs. The VM
operator reconciles the VM* and VL* CRs and converts prometheus-operator objects.

| | VMSingle (metrics) | VLSingle (logs) |
|---|---|---|
| Retention | 180d | 60d, since logs are bulkier |
| PVC | 50Gi `longhorn-r2-ephemeral` | 30Gi `longhorn-r2-ephemeral` |
| Written by | vmagent | `victoria-logs-collector` DaemonSet |
| UI | vmui | vlogs |
| Off-cluster | daily native export, `08_vm_backup` | daily LogsQL export, same CronJob |

Both are operator CRs, so one operator covers everything. The logs store is a `VLSingle`, not the standalone logs
chart. Metrics start fresh, with no `vmctl` backfill.

### What lands in VictoriaLogs

One DaemonSet reads four things off each node's filesystem, all into the same store:

| Source | Where | Query it by |
|---|---|---|
| container logs | `/var/log/pods` | `kubernetes.pod_namespace`, `kubernetes.pod_name`, `kubernetes.container_name` |
| Node system logs | `/var/log/*.log` | `source:node`, `node`, `file` (e.g. `/var/log/kubelet.log`) |
| denied network flows | `/var/run/cilium/hubble/drops.log` | `source:hubble`, `node`, `verdict` |
| kube-apiserver audit | `/var/log/audit/kube/kube-apiserver.log` | `source:kube-audit`, `node`, `verb`, `user.username` |

Talos writes each system service to `/var/log/<service>.log` and rotates at 5MiB, keeping one `.log.1`, and
`dmesg` is just the service named `kernel`. So `kernel`, `kubelet`, `etcd`, `containerd`, `cri`, `machined`,
`controller-runtime`, `dns-resolve-cache`, `apid`, `trustd`, `udevd`, `early-startup` and `ext-iscsid` are all
plain files that the collector's `fileCollector` glob tails, no extra component. This is a Talos >=1.12 feature:
before that, service logs lived only in an in-memory ring buffer, and the usual answer was a Vector DaemonSet fed
by `machine.logging.destinations` over a socket. We do not do that, and no machine config is involved.

`auditd.log` is the ONE file excluded, and it is not close: measured at ~340MB a day per node, against 4.4MB for
every container log in the cluster combined. Reason and how to reconsider are in `05_victoria_logs/values.yaml`.
Everything else is quiet, ~1.5MB a day per node in steady state, with the boot burst on top.

Reading the result:

- **`node`, not `hostname`.** File-collected lines also carry a `hostname` field, which is the collector POD's
  name, not the node's. Ignore it. `node` is stamped from the downward API. Why it cannot just be `hostname` is
  in `05_victoria_logs/values.yaml`.
- **A JSON line keeps its own fields.** etcd and kubelet arrive with their real `_time` (kubelet's float
  epoch-millis included) and etcd with a `level`, so etcd DOES count toward the `high-error-log-rate` alert.
  `kernel`, `machined` and the others are text: `_msg` whole, `_time` is the collection time, and their in-line
  timestamp is just text, not a queryable field.
- **First rollout backfills.** With no checkpoint the collector reads each file from the START, so whatever is
  on disk arrives at once, a few MB per node, text lines all stamped with that moment.

Two things it does not cover, both by design:

- **Boot before the collector.** Nothing ships until `/var/log` mounts and the pod starts, so the early-boot
  kernel lines only reach VL after the fact, once. They do survive on disk across a reboot, which the old ring
  buffer did not, so the previous boot is still readable with `talosctl logs kernel` or `talosctl dmesg`.
- **A node that cannot mount its disk** logs nowhere. Reaching it needs `machine.logging.destinations` pushing
  over the network, which is the reason to add Vector if it ever becomes worth it.

### Denied flows: which CiliumNetworkPolicy denied it

Every app carries a hand-written default-deny CNP, so the usual failure is a connection that just hangs. The
`drop` Hubble METRIC counts those, but a count does not say which pod, port or identity was denied.

`hubble.export.dynamic` in `00_cilium` writes one JSON line per `DROPPED` or `AUDIT` flow to
`/var/run/cilium/hubble/drops.log` on the node, and the collector tails it. `source:hubble |
flow.source.namespace:x` is the query that turns a mystery timeout into the missing rule. `_msg` is the drop
reason, the rest of the flow stays as fields.

`AUDIT` is in the filter because while `policyAuditMode` is on, a policy gap is forwarded and reported as
`AUDIT`, never `DROPPED`. Filtering on `DROPPED` alone writes nothing about the gaps this file exists for.

Two things to keep in mind:

- **`dynamic`, not `static`**, so editing the filters reloads inside the running agents. A `static` exporter is
  bound to the agent's lifetime and needs a DaemonSet roll.
- **A policy mistake is a drop storm.** The file rotates at 10MB keeping one backup, so the node cannot fill,
  but the collector will happily ship what it reads before rotation. If a rollout floods the store, fix the
  policy; do not widen the filter.

### The kube-apiserver audit log

Talos turns audit logging on by DEFAULT and at `level: Metadata` for everything, which measured ~1GB a day per
node here, and none of it was being read. The machine config narrows the policy instead of collecting it raw.
The policy itself is set on the apiserver, which is a host-level change made outside this repo. This section explains what it
does and how to change it, because the consequences land on this repo's log pipeline:

- reads (`get`, `list`, `watch`) are dropped: the bulk of the volume,
- `leases` are dropped: leader election plus kubelet heartbeats were 65% of the events on their own,
- `events` and `nodes/status`, `pods/status` are dropped: controller churn that metrics already cover,
- everything else stays at `Metadata`, which is ~1.5% of the default and is the part worth having: who created,
  changed or deleted what, plus every `tokenreviews`/`subjectaccessreviews` result.

Never raise a rule to `Request` or `RequestResponse`: those log Secret and ConfigMap CONTENTS into a store that
is not encrypted and is exported to S3.

If `source:kube-audit` stays empty after all that, suspect SELinux before the collector: Talos labels this
directory `kube_log_t` and the container-log paths `containers_log_t`, so this is the one file source the
collector reads that it has no precedent for. A denial shows up in `talosctl dmesg` as an AVC line.

`_msg` is the request URI; `verb`, `user.username`, `objectRef.*` and `responseStatus.code` are all queryable
fields. `_time` is collection time, not the request time, because the file collector has no time-field knob and
audit events name theirs `stageTimestamp`. Note that Talos keeps up to 10 rotated 100MB audit files on the
node's EPHEMERAL volume whatever the policy says.

The policy only takes effect once the machine config is pushed, and pushing it restarts the apiserver static
pod on every node it touches. Both are node-level operations, run with whatever tooling manages your machines:

```bash
# node-level, NOT from this repo
make reapply-talos-config NODE=talos-cp1   # one node, dry-run + confirm
kubectl get --raw /healthz                 # it came back? then do the rest
make reapply-talos-config
```

Do it one node first, because an audit policy the apiserver REJECTS stops it from starting, and the no-NODE form
walks every control-plane node in one loop. Better still, validate the policy before pushing anything:

```bash
# policy.yaml = just the auditPolicy body your apiserver is configured with. The key is only there because the apiserver checks it
# BEFORE the policy and any earlier error hides the one you are looking for.
openssl genrsa -out /tmp/sa.key 2048
docker run --rm -v /tmp:/x registry.k8s.io/kube-apiserver:v1.36.3 kube-apiserver \
  --audit-policy-file=/x/policy.yaml --etcd-servers=http://127.0.0.1:2379 \
  --service-account-issuer=x --service-account-key-file=/x/sa.key --service-account-signing-key-file=/x/sa.key
# "error creating storage factory: context deadline exceeded"  -> policy parsed, it just cannot reach etcd. Good.
# "loading audit policy file: rules[0].level: Unsupported ..."  -> policy is broken. Do NOT apply.
```

### Why VictoriaMetrics over Prometheus

One operator covers both metrics and logs, it is far lighter than Prometheus plus Loki on 8GB Pi 5 nodes, and it
is PromQL-compatible so dashboards and queries port unchanged.

### The prometheus-operator CRD converter

The operator's converter turns every existing `ServiceMonitor`, `PodMonitor`, `PrometheusRule` and `Probe` into
its VM equivalent with no rewrites. That is why the `monitoring.coreos.com` CRDs are kept: the wave-0
`00_prometheus_operator_crds` app is the converter's source and is not removable.

Scrape sources across the platform (node-exporter, kube-state-metrics, cilium and hubble, argocd, cert-manager,
longhorn, sealed-secrets, cnpg, metrics-server, ntfy, blackbox-exporter, smartctl-exporter) all reach vmagent
this way. The
converter stamps ArgoCD-ignore annotations on its output
(`operator.prometheus_converter_add_argocd_ignore_annotations: true`) so ArgoCD never fights or prunes
operator-created objects.

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

### Synthetic probes, so an unvisited host still reports

`05_blackbox_exporter` (wave 5) fetches every ingress host once a minute over its PUBLIC name, and vmagent
scrapes the result via one `VMProbe` CR per group. This exists because the `ingress-http` alerts read Envoy's own
counters: they need real traffic, so a host with a dead backend and no visitors stays green until someone tries
it. One probe covers DNS, the router's hairpin back to the LoadBalancer, the served certificate and the route.

Targets sit in groups, each naming the module that grades it, and the module asserts exactly what an
anonymous GET should get back:

| Module | Expects | Covers |
|---|---|---|
| `http_sso_302` | 302 with `Location:` matching `accounts.google.com` | the 8 SSO'd hosts. The edge and that the SecurityPolicy is still attached |
| `http_open_200` | 200 | `ntfy` and the open sample workload, which have no SSO, so the app itself answers |

Consequences worth knowing:

- **An SSO'd host is only checked as far as the edge.** Google answers before the request reaches the backend,
  so the probe cannot see the app behind it. That is not fixable without a login; those backends have their
  own alerts.
- **The `Location` check is the point**, not the 302. A route that lost its SecurityPolicy would still 302
  somewhere. Pinning the destination is what turns "SSO fell off and this is now public" into a firing alert
  rather than a pass.
- **Pick a path that returns 200** for an open host. Both current ones serve 404 at `/`, which a probe cannot
  tell apart from a broken route, hence `/v1/health` and `/users`.
- **Adding a host to `06_platform_ingress` does NOT add a probe.** The target lists in the blackbox chart's
  `values.yaml` are hand-maintained, deliberately: the expected status code is a per-host decision, not
  something derivable from the ingress definition.
- **A group can hold any FQDN**, not just the `ops.` and `app.` tiers. `04_values.sh` composes the targets of
  `sso` and `open` from those two domains and touches nothing else, so a host on another domain goes in a
  group you add by hand, naming its module and listing full URLs.

### SMART, because node-exporter reads none of it

`05_smartctl_exporter` (wave 5) runs `smartctl` against each node's real disk. node-exporter reports a drive's
temperature and nothing else about it: no wear, no spare blocks, no media errors. Without this a disk dies with
no warning, which on a cluster where every volume is replicated onto those same disks is the failure worth
catching earliest. The rules are the `smart-health` group.

Two things about it are not obvious:

- **The image is `ghcr.io/yama6a/smartctl-exporter-multiarch`, not upstream's.** prometheus-community publishes
  smartctl-exporter for amd64 only, so the stock image cannot run on the Pis at all. That repo repackages
  their own release binary, unmodified, as a manifest list. Its tag is `<upstream version>-<build revision>`,
  so `v0.14.0-2` is the second build of upstream's `v0.14.0`, usually after a base-image CVE fix. Renovate
  needs the shape declared or it reads the suffix as a semver prerelease; see the packageRule in
  `renovate.json5`.
- **The device list is hand-maintained, per architecture, and has to be.** Longhorn attaches every replica as
  an iSCSI `/dev/sd*`, the same namespace a real SATA disk lands in. Letting smartctl scan would make it probe
  every attached volume, which has no SMART and whose set changes on every attach. So there is one DaemonSet
  per architecture in the chart's `values.yaml`: the arm64 nodes match `^/dev/nvme`, the amd64 node names its
  SATA disk outright. Adding a node with different disks means editing that file.

### Mixed-architecture nodes, and what that does to hardware alerts

The cluster is no longer uniform: three arm64 Pi 5s and one amd64 box. Three things follow, and all of them
have already bitten:

- **`node_hwmon_temp_celsius{chip="thermal_thermal_zone0"}` means different things per platform.** On the Pis
  it is the SoC. On x86 it is `acpitz`, chassis ambient, which reads ~30C while the CPU is at 90C. So the
  temperature rules read `node_thermal_zone_temp{type=...}` instead, where `type` is the driver's own name:
  `cpu-thermal` on the Pis, `x86_pkg_temp` on Intel, `k10temp` on AMD. Adding a platform means adding its zone
  type to the right allow list in `node-hardware.yaml`. `acpitz` is deliberately in neither.
- **Never select raw hwmon temperatures without pinning the chip.** An unpopulated thermistor on a super-I/O
  chip reports a constant 127.5C, so `node_hwmon_temp_celsius > 80` would fire on day one and never clear.
- **Some signals only exist on one side, which is fine.** `node_hwmon_in_lcrit_alarm_volts` (undervoltage) is
  the Pis only; `node_cpu_package_throttles_total` is x86 only. Both rules stay dormant where the metric is
  absent, so neither needs an architecture selector.

Fan RPM is deliberately unalerted. Only the x86 node exposes a fan at all, and a bare `node_hwmon_fan_rpm == 0`
false-positives forever on unpopulated headers. Guarding it with "spun recently" fixes that but then misfires
on boards with a zero-RPM idle mode, and self-clears once the lookback window is all zeros. `node-cpu-throttled`
and the temperature rules catch a dead fan by its consequence, on any platform.

### Deleting a store is a two-commit dance

Both CRs carry deletion protection, so a stray prune cannot reach them, and total loss is covered by the S3
export. To delete one deliberately, drop the protection first, sync, then remove it in a follow-up commit:

- VL: `deletionProtection: false` in `05_victoria_logs/values.yaml`.
- VMSingle and VMAgent: delete the `annotations:` block under each in
  `05_victoria_metrics_k8s_stack/values.yaml`. That block IS the flag, because `values.yaml` cannot be templated.

Never leave a store sitting unprotected. Off-cluster backup is opt-in via `make configure-vm-backup`; mechanism
and disaster recovery are in [10_backups.md](10_backups.md).

### Other decisions

- node-exporter, smartctl-exporter and the log collector are DaemonSets with `tolerations: [{operator: Exists}]`.
  Node metrics are wanted from EVERY node whatever its role or taints, so tolerate everything rather than trying
  to enumerate. Role selectors are the wrong tool here in both directions: the three Pis are all control-plane,
  so `control-plane: DoesNotExist` would have matched zero nodes before the worker joined, and one node now.
- Each UI (vmui, vlogs) is exposed by the platform-ingress app at wave 6 behind Google SSO, not by its own chart.
  The Hubble UI rides the same app. See [04_ingress.md](04_ingress.md).
- Dashboards come from two places. An upstream chart's own (`grafana_dashboard`-labelled ConfigMaps in ITS
  namespace, picked up because the sidecar runs `searchNamespace: ALL`), and ours, one JSON per file in
  `05_grafana/files/dashboards/`, rendered by `templates/dashboards-configmaps.yaml` the same way the alert
  files are. Write a dashboard there rather than patching an upstream one: the patch has to be reapplied on
  every chart bump. `hubble` is the case that made the rule. See [01_networking.md](01_networking.md).
- Ours so far: `hubble` (Cilium flows, [01_networking.md](01_networking.md)), `ingress-http` (Envoy edge and
  per-HTTPRoute HTTP, [04_ingress.md](04_ingress.md)) and `persistent-volumes`. All hand-written against metrics
  checked to exist first. An upstream dashboard assumes upstream's config: Cilium's four assume `httpV2` and
  context options we do not all run, which is exactly how you end up with a dashboard of empty panels.
- `cnpg` is the ONE fork, not a rewrite: 66 panels of CNPG internals is too much to re-author for the sake of a
  handful of queries. `02_cnpg_operator` sets `monitoring.grafanaDashboard.create: false` and we ship a copy
  keeping the upstream uid `cloudnative-pg`, so the URL does not move. Exactly three families of query differ,
  and a re-fork after a chart bump has to redo them:
  - CPU (4 targets) read raw `container_cpu_usage_seconds_total` instead of the
    `node_namespace_pod_container:...:sum_irate` RECORDING RULE, which nothing here evaluates. VictoriaMetrics
    rewrote its own k8s dashboards the same way; a scan of every `grafana_dashboard` ConfigMap found no other
    consumer of any recording rule, so there is nothing to gain by running vmalert just for this.
  - Operator readiness (3 targets) match `pod=~".*cloudnative-pg.*"`. Upstream anchors on `cloudnative-pg.+`,
    which assumes the release is named after the chart; ours is `cnpg-operator`, so its pods are
    `cnpg-operator-cloudnative-pg-*` and the upstream regex matches nothing.
  - Backups (4 targets) read orphan-exporter's `cnpg_backup_last_success_seconds` and
    `cnpg_backup_first_recoverability_seconds` instead of `cnpg_collector_last_available_backup_timestamp` and
    `cnpg_collector_first_recoverability_point`, which the Barman Cloud plugin leaves at 0 forever. See
    [10_backups.md](10_backups.md).
  - The `Volume Space Usage: Tablespaces` panel is DELETED, the one panel removed rather than rewritten. It
    charts `<instance>-tbs*` PVCs, and `pg-cluster` declares no tablespaces, so it could only ever read "No
    data". The same `-tbs` and `-wal` targets survive inside the multi-target Volume panels, where an empty
    target just adds no series and costs nothing.
- What stays empty in `cnpg`, all of it because the feature is not in use: the `-wal` half of the volume panels
  (no `walStorage`, PGDATA is one volume), Tablespaces (none), and Zone (kube-state-metrics emits no
  `kube_node_labels` because its `metricLabelsAllowlist` has no `nodes=` entry, and bare Pis have no zone
  anyway).
- `persistent-volumes` REPLACES the stack's `persistentvolumesusage`, disabled in
  `05_victoria_metrics_k8s_stack/values.yaml` under `defaultDashboards.dashboards`. The upstream one picks ONE
  PVC at a time from two dropdowns and spends half its space on gauges; with 13 volumes the useful view is all of
  them on one axis. Ours: a table of every PVC plus used-bytes, used-%, used-inodes and inode-% timeseries, each
  `max by (namespace, persistentvolumeclaim)` so a volume moving node does not break its series. The sync-job
  prunes the old ConfigMap on its own (`syncJob.prune` defaults true), so nothing to clean up by hand.
- A kubelet-sourced volume panel only sees PVCs a running pod has MOUNTED. A bound-but-unused PVC emits no
  `kubelet_volume_stats_*` at all and is simply absent, so the table can be shorter than `kubectl get pv`.
- A ratio panel needs `or vector(0)` on the numerator, or it goes BLANK on the healthy case instead of reading
  zero, because a rate over a counter with no matching series returns nothing rather than 0. Per-series ratios
  need `or 0 * <denominator>` instead, which refills the missing series with the labels needed for the division
  to still match up. Both are in `ingress-http`'s 5xx panels.
- vmagent's `externalLabels.cluster` collides with any exporter that emits its OWN `cluster` label. vmagent wins
  and renames the exported one to `exported_cluster`, silently. CNPG is the case that bit us: its dashboard
  resolves `$cluster` from that label and then picks instances with `pod=~"$cluster-N"`, so every panel read "No
  data" while the metrics were there the whole time. Check for `exported_*` first whenever a third-party
  dashboard is empty but its metrics exist.
- The fix for that collision is `honorLabels: true` on the scrape endpoint, which is what `pg-cluster`'s
  PodMonitor sets. A `metricRelabelings` rule CANNOT do it: vmagent merges its external labels AFTER
  `metric_relabel_configs` run, so at that point there is no `exported_cluster` to rename yet and the rule is a
  no-op. Confirmed by reading the target's own label set from vmagent's `/api/v1/targets`, which does not carry
  `cluster` at all. The price is per-scrape and worth knowing: those series get the CNPG cluster name in
  `cluster` and NOT `offgrid`, and any other label the exporter emits would also override the target's.
  For the CNPG pods `cluster` is the only collision.

### Keeping the stores lean

Retention has ample PVC headroom, so the goal is dropping data that never gets charted or alerted, not avoiding
overflow. Exact drops and reasons live as comments where the config does.

- **Check every namespace before adding a drop.** A metric can be charted by a `grafana_dashboard` or
  `grafana_alert` ConfigMap in ANY namespace: the sidecar runs `searchNamespace: ALL`, and cilium and cnpg ship
  dashboards from their own. Missing those breaks a panel you never saw.
- **Where a drop goes.** `globalScrapeMetricRelabelConfigs` for anything many jobs emit, per-target
  `metricRelabelConfigs` for single-job families like the apiserver's view of etcd.
- **veth churn is the only unbounded growth.** Cilium's `lxc<random>` names never repeat, so every pod restart
  mints permanent new series. Dropped in two places: node-exporter flags for `node_network_*`, the vmagent
  list for cAdvisor's `container_network_*`.
- **That drop moves panel values.** The Kubernetes Views network panels sum `container_network_*` with no
  `interface` filter, so keeping only `eth0` takes them down to the real number.
- **60s is the floor.** `dedup.minScrapeInterval` discards anything scraped faster. Check new scrapes.
- **Postgres settings.** `lib/helm/pg-cluster` keeps only `cnpg_pg_settings_setting{name="max_connections"}`,
  which the connection-saturation alert reads, and drops the rest of the per-setting config dump. Alerting on
  another Postgres setting means widening that keep-list.
- **Logs are not a storage problem**: ~5800 lines and 4.4MB a day of CONTAINER logs against a 30Gi PVC, 75% of
  it the three sample workloads. `rabbitmq-messaging-topology-operator` was ~55% before `logLevel: error`; that
  drops WARN too, but failures still surface via CR status conditions, k8s events and the `rabbitmq-health`
  alerts. The collector drops its own logs pre-read, via `excludeFilter` in `05_victoria_logs`. Talos node logs
  add ~1.5MB a day per node on top of that, once `auditd.log` is excluded; to cut another loud service, add its
  path to `excludeGlob` beside the `fileCollector` glob, which drops it by FILE, there is no per-line filter.
- **The two file sources that can surprise you are the audit log and Hubble drops.** Both are filtered at the
  SOURCE rather than in the collector: the apiserver's audit policy, the `includeFilters` in `00_cilium`. Widening
  either is what would actually fill the store, so size it before you do.
- **Envoy access logs show `_msg` as "missing _msg field"** and are fine. Envoy Gateway's default JSON access
  log has no key the collector maps to `_msg`; the structured fields are all queryable (`response_code:500`).
  Fixing it needs a `telemetry.accessLog` block on the EnvoyProxy CR, cosmetic only.

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

### `execErrState: KeepLast` on every rule but one

An eval error is not the same as a firing alert. Under `execErrState: Error` a rule that cannot run its query
goes Alerting with NO query labels, so every `{{ $labels.x }}` in the summary renders `[no value]`. Since all
rules share one datasource, a single vmsingle blip flips all of them at once: one node drain sent 51 FIRING plus
51 RESOLVED in five minutes, each naming nothing, burying the two real alerts in the same window.

So every rule sets `execErrState: KeepLast` and holds its previous state through the gap. The lone exception is
`metrics-datasource-down` in `monitoring-health.yaml`, which keeps `Error` on purpose: it is the one rule whose
job IS to report that queries are failing, and it turns the storm into a single notification. Give any new rule
`KeepLast`.

The gap this leaves: one rule with a permanently broken query, say a metric renamed by a chart bump, now stays
silent on its last state instead of alerting. The datasource canary does not catch that, only total failure.
Re-check queries after bumping a chart that renames metrics.

### Alert severity model and the `alert-criticality` label

Alerts carry exactly two severities, `critical` and `warning`, never `info`, mapped by the ntfy webhook to
priority 5 and 4. Severity is a function of what broke times how important the component is:

| What the alert means | Component labelled `alert-criticality: critical` | Not labelled |
|---|---|---|
| Outage: workload down or broken so it cannot serve | critical | warning |
| Anomaly or about-to-break: degraded, saturating, restarting, near-limit, capacity | warning | warning |

So `critical` fires only when an outage-class alert triggers on a component that opted in with the label.
Everything else is `warning`. Two static `critical`s sit outside the model, both node-level rather than
workload: `Node NotReady`, and `node-undervoltage`, which is the one hardware fault that corrupts data instead
of just slowing things down.

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
| `monitoring-health` | mixed | `metrics-datasource-down` (critical, the only `execErrState: Error` rule), `vmsingle-near-read-only` (critical), `vmagent-dropping-samples`, `victorialogs-errors` |
| `sealed-secrets-health` | static critical | `sealed-secrets-not-ready` (10m). A down controller blocks ALL decryption cluster-wide |
| `ingress-http` | mixed, per route | `ingress-5xx-high` (>2%), `-4xx-high` (>25%), `-latency-p95-high` (>2s), `-no-healthy-upstream` (critical, the 503 cause), `-upstream-connect-failures` |
| `cnpg-health` | `cnpg-instance-not-ready` dynamic, rest warning | `-high-connections-*`, `-replication-lag-*`, `-txid-wraparound-*` (>300M, >1B), `-replication-slot-inactive`, `-long-running-transaction`, `-backends-waiting`, `-deadlocks`, `-manual-switchover-required`, `-fencing-on` |
| `rabbitmq-cluster` | static | `-cluster-down` and `-quorum-at-risk` (critical, <2 nodes), `-node-down` (warning, <3), `-memory-alarm` and `-disk-alarm` (critical, publishers already blocked), `-disk-low` |
| `rabbitmq-queues` | warning | `-queue-no-consumer`, `-queue-backlog` and `-queue-unacked` (>100), `-dlq-not-empty`, `-dead-letter-rate` |
| `redis-health` | `redis-down` dynamic, rest warning | `-memory-high` and `-memory-critical` (percent of maxmemory; noeviction, so writes fail near 100%), `-rejected-connections` and `-connections-high`, `-rdb-save-failing` and `-aof-write-failing`, `-fragmentation-high` |
| `backups` | warning, 2 critical | redis, longhorn, CNPG and VM/VL backup failure plus staleness, and the two unrecoverable-catalog rules. See [10_backups.md](10_backups.md) |
| `orphan` | warning | orphaned and untracked CNPG, Redis and VM/VL CRs, plus the exporter deadman. See [10_backups.md](10_backups.md) |
| `node-hardware` | warning, `node-undervoltage` static critical | `node-undervoltage` (the board's own low-rail alarm), `node-soc-temp-high` (>80C, where an ARM SoC throttles), `node-cpu-temp-high` (>90C, x86, under its ~100C shutdown), `node-cpu-throttled` (the CPU says it clocked itself down) |
| `smart-health` | mixed | `smart-device-failing` (critical, the drive's own verdict), `smart-nvme-critical-warning` and `smart-spare-low` (critical), `smart-media-errors` (new errors in 24h), `smart-wear-high` (>80% of rated endurance), `smart-device-temp-high` (>70C), `smart-sata-reallocated` |
| `probes` | warning | `ingress-probe-failing`, `ingress-cert-expiring` (<14d, on the cert actually SERVED). See "Synthetic probes" |
| `alerting-path` | warning | `alert-delivery-failing`: Grafana's webhook to ntfy is erroring, so alerts fire and nobody is told |

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

ntfy is a private, deny-all instance with no declarative user config, so `lib/shell/06_ntfy_auth.sh` (`make
configure-ntfy-auth`, run post-boot once the pod is up) seeds two users on `cluster-alerts`:

- `phone`, read-only, password from `NTFY_PHONE_PASSWORD_SECRET` in `.env`.
- `grafana`, write-only.

It then mints and seals Grafana's write token into the `grafana-ntfy` Secret under key `token`, surfaced as
`GF_NTFY_TOKEN` and interpolated into the webhook's `authorization_credentials`. That env is optional, so Grafana
starts before the token is sealed. Leave `NTFY_PHONE_PASSWORD_SECRET` empty and the script offers to delete the
sealed token, disabling ntfy alerting.

This is the only imperative script for this step; the VM stack and metrics-server are pure GitOps. Grafana's
`grafana.ops.example.com` edge is served by the platform-ingress app at wave 6, not the `05_grafana` chart. See
[04_ingress.md](04_ingress.md).

#### Watching the alert path itself

The whole chain is Grafana to ntfy to phone, and if it breaks, the thing that would tell you is the thing that
broke. Three partial checks, all in-cluster, because there is deliberately nothing off-cluster to escalate to:

- ntfy runs a SEPARATE metrics listener on `:9091` (`metrics-listen-http`), scraped by a PodMonitor. Separate so
  `/metrics` is never served on the internet-facing `:8080`. A dead ntfy is then just a down scrape target, so
  `target-down` covers it and no ntfy-specific rule is needed.
- `alert-delivery-failing` counts Grafana's failed webhook POSTs, which catches a wrong topic, an expired token
  or a rejected publish while ntfy itself is up and healthy.
- the blackbox probe of `https://ntfy.ops.example.com/v1/health` covers the public edge the PHONE uses, which
  the in-cluster Service path never touches.

None of these can page you, since they all depend on the path they are testing. They fire in the Grafana UI and
resolve on their own, so what you actually get is an after-the-fact record. Closing that gap needs a receiver
outside the cluster.

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
a wired L2 segment, and the connection is encrypted either
way. Only the cert identity goes unchecked, so we take the one-flag, zero-OS-change route.

The secure-path upgrade stays open. To drop the flag: add `rotate-server-certificates: true` to your
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

It also matches the repo's tooling conventions. KRR runs dockerized, reaching the metrics store
over the same documented break-glass port-forward that `05_victoria_metrics_k8s_stack` already advertises, and the
kube API via the pinned kubeconfig. It reuses `MONITORING_NS` and adds no cluster workload, no ArgoCD app and no SSO
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
