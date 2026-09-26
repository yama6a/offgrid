# Monitoring and observability

- VictoriaMetrics stores metrics and VictoriaLogs stores logs. One operator reconciles both.
- Grafana is the UI over both stores, and it owns alerting.
- metrics-server serves the in-tree resource-metrics API that `kubectl top` and the HPA (Horizontal Pod
  Autoscaler) read. The observability stack does not serve that API.

Ingress and SSO for each UI are in [04_ingress.md](04_ingress.md). Storage classes are in
[05_storage.md](05_storage.md).

## VictoriaMetrics and VictoriaLogs

- vmagent is a Deployment with `selectAllByDefault`. It scrapes every target into a `VMSingle`, the single-node
  metrics store.
- A `victoria-logs-collector` DaemonSet runs on every node. It sends container logs and the node's own Talos logs
  to a `VLSingle`, the single-node logs store.
- The VM operator reconciles the `VM*` and `VL*` custom resources (CRs). It also converts prometheus-operator
  objects.

| | VMSingle (metrics) | VLSingle (logs) |
|---|---|---|
| Retention | 180d | 60d, because logs are larger |
| PVC | 50Gi `longhorn-r2-ephemeral` | 30Gi `longhorn-r2-ephemeral` |
| Written by | vmagent | `victoria-logs-collector` DaemonSet |
| UI | vmui | vlogs |
| Off-cluster | daily native export, `08_vm_backup` | daily LogsQL export, same CronJob |

Both stores are operator CRs, so one operator covers everything. The logs store is a `VLSingle` CR, not the
standalone VictoriaLogs chart. Metrics start empty. Nothing backfills them with `vmctl`.

### What lands in VictoriaLogs

One DaemonSet reads four sources from each node's filesystem into the same store:

| Source | Where | Query it by |
|---|---|---|
| Container logs | `/var/log/pods` | `kubernetes.pod_namespace`, `kubernetes.pod_name`, `kubernetes.container_name` |
| Node system logs | `/var/log/*.log` | `source:node`, `node`, `file` (for example `/var/log/kubelet.log`) |
| Denied network flows | `/var/run/cilium/hubble/drops.log` | `source:hubble`, `node`, `verdict` |
| kube-apiserver audit | `/var/log/audit/kube/kube-apiserver.log` | `source:kube-audit`, `node`, `verb`, `user.username` |

Talos writes the log of each system service to `/var/log/<service>.log`. It rotates each file at 5MiB and keeps one
`.log.1`. The kernel log (`dmesg`) is the service named `kernel`. So these are all plain files that the collector's
`fileCollector` glob tails, with no extra component: `kernel`, `kubelet`, `etcd`, `containerd`, `cri`, `machined`,
`controller-runtime`, `apid`, `trustd`, `udevd`, `early-startup` and `ext-iscsid`. This needs
Talos 1.12 or later. No machine config change is involved.

The collector excludes two files for their volume. All container logs in the cluster together write 4.4MB a day.

- `auditd.log`: about 340MB a day per node.
- `dns-resolve-cache.log`: about 107MB a day, 47% of all log bytes. Every line is a DEBUG dump of one query.

The reasons, and how to reconsider them, are in `05_victoria_logs/values.yaml`.
Every other node log is quiet: about 1.5MB a day per node in steady state, plus a burst at boot.

Reading the result:

- **Query by `node`, not `hostname`.** File-collected lines also carry a `hostname` field. That field holds the
  collector pod's name, not the node's, so ignore it. The collector stamps `node` from the downward API.
  `05_victoria_logs/values.yaml` explains why `hostname` cannot hold the node name.
- **A JSON line keeps its own fields.** etcd and kubelet lines arrive with their real `_time`, kubelet's float
  epoch milliseconds included. etcd lines also carry a `level`, so etcd counts toward the `high-error-log-rate`
  alert. `kernel`, `machined` and the other services write text. For those, `_msg` holds the whole line and
  `_time` is the collection time. Their inline timestamp is text, not a queryable field.
- **The first rollout backfills.** With no checkpoint, the collector reads each file from the start. So all logs
  already on disk arrive at once, a few MB per node. The text lines all carry that one collection time.

Two gaps, both by design:

- **Boot before the collector.** Nothing ships until `/var/log` mounts and the collector pod starts. So early-boot
  kernel lines reach VictoriaLogs late, once. They survive a reboot on disk, so `talosctl logs kernel` or
  `talosctl dmesg` still shows the previous boot.
- **A node that cannot mount its disk** logs nowhere. To reach it, `machine.logging.destinations` must push logs
  over the network. That is the reason to add Vector, if it ever becomes worth it.

### Denied flows: which CiliumNetworkPolicy denied it

Every app carries a hand-written default-deny CiliumNetworkPolicy (CNP). So the usual failure is a connection that
hangs. The Hubble `drop` metric counts those drops. A count does not say which pod, port or identity Cilium
denied.

`hubble.export.dynamic` in `00_cilium` writes one JSON line per `DROPPED` or `AUDIT` flow to
`/var/run/cilium/hubble/drops.log` on the node. The collector tails that file. The query
`source:hubble | flow.source.namespace:x` turns an unexplained timeout into the missing rule. `_msg` holds the drop
reason. The rest of the flow stays as fields.

The filter includes `AUDIT` because of `policyAuditMode`. While audit mode is on, Cilium forwards a policy gap and
reports it as `AUDIT`, never `DROPPED`. A filter on `DROPPED` alone writes nothing about those gaps.

Two things to keep in mind:

- **`dynamic`, not `static`.** An edit to the filters reloads inside the running agents. A `static` exporter is
  bound to the agent's lifetime and needs a DaemonSet restart.
- **A policy mistake causes a flood of drops.** The file rotates at 10MB and keeps one backup, so the node disk
  cannot fill. The collector still ships all it reads before rotation. If a rollout floods the store, fix the
  policy. Do not widen the filter.

### The kube-apiserver audit log

Talos turns on audit logging by default, at `level: Metadata` for every request. That measured about 1GB a day per
node here, and nothing read it. So the machine config narrows the audit policy instead of collecting it raw. The
policy is set on the apiserver, a host-level change made outside this repo. This section explains what the policy
does and how to change it, because its output lands in this repo's log pipeline:

- Reads (`get`, `list`, `watch`) are dropped. They are most of the volume.
- `leases` are dropped. Leader election and kubelet heartbeats alone were 65% of the events.
- `events`, `nodes/status` and `pods/status` are dropped. They are controller churn that metrics already cover.
- Everything else stays at `Metadata`. That is about 1.5% of the default volume, and it is the useful part: who
  created, changed or deleted what, and every `tokenreviews` and `subjectaccessreviews` result.

Never raise a rule to `Request` or `RequestResponse`. Those levels log the contents of Secrets and ConfigMaps into
a store that is not encrypted and is exported to S3.

If `source:kube-audit` stays empty, suspect SELinux before the collector. Talos labels this directory
`kube_log_t` and the container-log paths `containers_log_t`. So the audit log is the one file source with a label
the collector has not read before. A denial shows up in `talosctl dmesg` as an AVC line.

Fields:

- `_msg` is the request URI.
- `verb`, `user.username`, `objectRef.*` and `responseStatus.code` are queryable fields.
- `_time` is the collection time, not the request time. The file collector has no setting for the time field, and
  audit events name theirs `stageTimestamp`.

Talos keeps up to 10 rotated 100MB audit files on the node's ephemeral volume, whatever the policy says.

The policy takes effect only after the machine config is pushed. The push restarts the apiserver static pod on
every node it touches. Both are node-level operations. Run them with the tooling that manages your machines:

```bash
# node-level, not from this repo
make reapply-talos-config NODE=talos-cp1   # one node, dry-run and confirm
kubectl get --raw /healthz                 # healthy again? then do the rest
make reapply-talos-config
```

Push to one node first. An audit policy the apiserver rejects stops the apiserver from starting. The form without
`NODE` walks every control-plane node in one loop. Better, validate the policy before you push anything:

```bash
# policy.yaml holds only the auditPolicy body your apiserver uses. The key exists because the apiserver checks it
# before the policy, and an earlier error hides the one you look for.
openssl genrsa -out /tmp/sa.key 2048
docker run --rm -v /tmp:/x registry.k8s.io/kube-apiserver:v1.36.3 kube-apiserver \
  --audit-policy-file=/x/policy.yaml --etcd-servers=http://127.0.0.1:2379 \
  --service-account-issuer=x --service-account-key-file=/x/sa.key --service-account-signing-key-file=/x/sa.key
# "error creating storage factory: context deadline exceeded": the policy parsed, only etcd is unreachable. Good.
# "loading audit policy file: rules[0].level: Unsupported ...": the policy is broken. Do not apply it.
```

### Why VictoriaMetrics over Prometheus

- One operator covers both metrics and logs.
- It is much lighter than Prometheus plus Loki on the 8GB Pi 5 nodes.
- It speaks PromQL, so dashboards and queries work unchanged.

### The prometheus-operator CRD converter

The operator's converter turns every `ServiceMonitor`, `PodMonitor`, `PrometheusRule` and `Probe` into its VM
equivalent, with no rewrite. So the `monitoring.coreos.com` CRDs stay. The wave-0 `00_prometheus_operator_crds` app
is the converter's source. Do not remove it.

Every scrape source in the platform reaches vmagent this way: node-exporter, kube-state-metrics, cilium and hubble,
argocd, cert-manager, longhorn, sealed-secrets, cnpg, metrics-server, ntfy, blackbox-exporter and
smartctl-exporter. The converter stamps Argo CD ignore annotations on its output
(`operator.prometheus_converter_add_argocd_ignore_annotations: true`). So Argo CD never fights or prunes the
objects the operator creates.

### Grafana owns alerting, and the cluster carries no rule CRs

`vmalert` and `vmalertmanager` are off. Grafana provisions the contact point, the notification policy and the alert
rules as code. There is no Alertmanager. Grafana alert expressions are inline PromQL.

With vmalert off, nothing evaluates rule CRs. So the invariant is that no `PrometheusRule` or `VMRule` exists on
the cluster, because each one would be inert. The stack's bundled default rules are off at the source. The
recording rules are off too. Nothing evaluates them, so they produce no series, and no dashboard or alert here
queries a recorded series.

Re-check the chart keys on every vm-k8s-stack bump:

- The master switch is `defaultRules.enabled: false`. The chart ignores the older `defaultRules.create` key
  without a warning.
- The chart delivers rules through a sync job. Its objects carry `app.kubernetes.io/managed-by: sync-job`, and
  Argo CD does not track them. So prune does not clean up leftovers.
- A stray `enabled: true`, or a future key rename, brings back a large set of inert alerts, and nothing reports it.
- After any bump, confirm that `kubectl get vmrule -A` returns nothing.

Other charts follow the same rule. Bundled alerts stay off, and a Grafana rule gives the coverage instead:

- `02_sealed_secrets` sets `metrics.prometheusRule.enabled: false`. The `sealed-secrets-health` group covers it.
- `lib/helm/pg-cluster` emits no `PrometheusRule`. The `backups` group covers it.

### Talos control-plane scrapes, outside ArgoCD

Talos machine config exposes these metrics endpoints. That config is applied outside Argo CD, because it is
machine-level and not a chart:

| Component | Port | Protocol |
|---|---|---|
| kube-controller-manager | 10257 | HTTPS with a self-signed cert, so `insecureSkipVerify` |
| kube-scheduler | 10259 | HTTPS with a self-signed cert, so `insecureSkipVerify` |
| etcd | 2381 | plain HTTP, through Talos `listen-metrics-urls` |

vmagent scrapes them through static `endpoints` at the control-plane node IPs. kube-proxy is off, because Cilium
replaces it. `metricRelabelConfigs` drops the high-cardinality apiserver and etcd histograms.

### Synthetic probes, so an unvisited host still reports

`05_blackbox_exporter` (wave 5) fetches every ingress host once a minute over its public name. vmagent scrapes the
result through one `VMProbe` CR per group. The probes exist because the `ingress-http` alerts read Envoy's own
counters, and those need real traffic. Without a probe, a host with a dead backend and no visitors stays green
until someone opens it. One probe covers DNS, the router's hairpin back to the LoadBalancer, the served certificate
and the route.

Targets sit in groups. Each group names the module that grades it. The module asserts exactly what an anonymous
GET gets back:

| Module | Expects | Covers |
|---|---|---|
| `http_sso_302` | 302 with `Location:` matching `accounts.google.com` | the 8 hosts behind SSO. Checks the edge, and that the SecurityPolicy is still attached |
| `http_open_200` | 200 | `ntfy` and the open sample workload. They have no SSO, so the app itself answers |

Consequences:

- **A host behind SSO is checked only up to the edge.** Google answers before the request reaches the backend, so
  the probe cannot see the app. Only a login could change that. Those backends have their own alerts.
- **The `Location` check matters more than the 302.** A route that lost its SecurityPolicy still returns a 302 to
  somewhere. Pinning the destination turns "SSO fell off and this host is now public" into a firing alert.
- **Pick a path that returns 200 for an open host.** Both current open hosts serve 404 at `/`. A probe cannot tell
  that apart from a broken route, so the targets use `/v1/health` and `/users`.
- **A new host in `06_platform_ingress` gets no probe.** You maintain the target lists in the blackbox chart's
  `values.yaml` by hand, on purpose. The expected status code is a per-host decision, and the ingress definition
  does not carry it.
- **A group can hold any FQDN**, not only the `ops.` and `app.` tiers. `04_values.sh` writes the `sso` and `open`
  targets from those two domains and changes nothing else. So a host on another domain goes in a group you add by
  hand, with its module and full URLs.
- **A group need not be HTTP.** The module picks the prober, so a group can point at a bare `host:port` with the
  `tcp_connect` module. Use case: a NAS behind an NFS PV. Such a PV has no Longhorn metrics, no replica health and
  no capacity series. Without a probe, nothing in the stack notices the export going away. Give that group its own
  alert rule. `ingress-probe-failing` matches only `instance=~"https://.*"`, so a bare host does not fire an alert
  whose text talks about DNS and certificates.

### SMART, because node-exporter reads none of it

`05_smartctl_exporter` (wave 5) runs `smartctl` against each node's real disk. node-exporter reports a drive's
temperature and nothing else: no wear, no spare blocks, no media errors. Without SMART data, a disk dies with no
warning. Every volume here is replicated onto those same disks, so this is the failure to catch earliest. The
`smart-health` group holds the rules.

Two details are not obvious:

- **The image is upstream's `master` tag, not a release.** Every tagged smartctl-exporter release is amd64-only, so
  none runs on the Pis. `master` is the only multi-arch tag prometheus-community publishes. The chart's
  `values.yaml` pins it by digest, and Renovate refreshes that digest.
- **The device list is maintained by hand, per architecture, and must be.** Longhorn attaches every replica as an
  iSCSI `/dev/sd*`, the same namespace a real SATA disk lands in. A smartctl scan would probe every attached
  volume. Those have no SMART data, and the set changes on every attach. So the chart's `values.yaml` defines one
  DaemonSet per architecture. The arm64 nodes match `^/dev/nvme`. The amd64 node names its SATA disk directly. A
  node with different disks needs an edit to that file.

### Mixed-architecture nodes, and what that does to hardware alerts

The cluster has three arm64 Pi 5 nodes and one amd64 node. That has three effects:

- **`node_hwmon_temp_celsius{chip="thermal_thermal_zone0"}` means different things per platform.** On the Pis it
  is the SoC. On x86 it is `acpitz`, the chassis ambient, which reads about 30C while the CPU is at 90C. So the
  temperature rules read `node_thermal_zone_temp{type=...}` instead. `type` is the driver's own name:
  `cpu-thermal` on the Pis, `x86_pkg_temp` on Intel, `k10temp` on AMD. A new platform needs its zone type in the
  right allow list in `node-hardware.yaml`. `acpitz` is in neither list, on purpose.
- **Never select raw hwmon temperatures without pinning the chip.** An unpopulated thermistor on a super-I/O chip
  reports a constant 127.5C. So `node_hwmon_temp_celsius > 80` would fire on day one and never clear.
- **Some signals exist on one platform only, and that is fine.** `node_hwmon_in_lcrit_alarm_volts` (undervoltage)
  exists only on the Pis. `node_cpu_package_throttles_total` exists only on x86. Each rule stays dormant where its
  metric is absent, so neither needs an architecture selector.

No alert watches fan RPM, on purpose:

- Only the x86 node exposes a fan.
- A bare `node_hwmon_fan_rpm == 0` fires forever on unpopulated fan headers.
- A "spun recently" guard fixes that, but misfires on boards with a zero-RPM idle mode. It also clears itself once
  the lookback window holds only zeros.

`node-cpu-throttled` and the temperature rules catch a dead fan by its effect, on any platform.

### Deleting a store is a two-commit dance

Both CRs carry deletion protection, so a stray prune cannot reach them. The S3 export covers total loss. To delete
a store on purpose, remove the protection first and sync. Then remove the store in a second commit:

- VictoriaLogs: set `deletionProtection: false` in `05_victoria_logs/values.yaml`.
- VMSingle and VMAgent: delete the `annotations:` block under each in
  `05_victoria_metrics_k8s_stack/values.yaml`. That block is the flag, because `values.yaml` cannot be templated.

Never leave a store unprotected. Off-cluster backup is opt-in through `make configure-vm-backup`. The mechanism and
disaster recovery are in [10_backups.md](10_backups.md).

### Other decisions

- **Tolerate every taint.** node-exporter, smartctl-exporter and the log collector are DaemonSets with
  `tolerations: [{operator: Exists}]`. Node metrics must come from every node, whatever its role or taints. A role
  selector is the wrong tool in both directions. The three Pis are all control-plane nodes, so
  `control-plane: DoesNotExist` would match only the one worker.
- **UIs go through platform-ingress.** The platform-ingress app (wave 6) exposes vmui and vlogs behind Google SSO.
  Their own charts do not. The Hubble UI uses the same app. See [04_ingress.md](04_ingress.md).
- **Dashboards come from two places.**
  - Upstream charts ship `grafana_dashboard`-labelled ConfigMaps in their own namespace. The Grafana sidecar
    finds them because it runs with `searchNamespace: ALL`.
  - This repo's dashboards are one JSON file each in `05_grafana/files/dashboards/`.
    `templates/dashboards-configmaps.yaml` renders them the same way as the alert files.
  - Write a new dashboard there instead of patching an upstream one. A patch needs reapplying on every chart bump.
    [01_networking.md](01_networking.md) covers the `hubble` case.
- **This repo's dashboards:** `hubble` (Cilium flows, [01_networking.md](01_networking.md)), `ingress-http` (Envoy
  edge and per-HTTPRoute HTTP, [04_ingress.md](04_ingress.md)) and `persistent-volumes`. Each is hand-written
  against metrics checked to exist first. An upstream dashboard assumes upstream's config. Cilium's four assume
  `httpV2` and context options this cluster does not all run, so their panels stay empty.
- **`cnpg` is a fork of the upstream dashboard, not a rewrite.** Its 66 panels of CNPG internals are too many to
  re-author for a few queries. `02_cnpg_operator` sets `monitoring.grafanaDashboard.create: false`, and this repo
  ships a copy. The copy keeps the upstream uid `cloudnative-pg`, so the URL stays the same. These changes differ
  from upstream, and a re-fork after a chart bump must redo them:
  - CPU (4 targets): reads raw `container_cpu_usage_seconds_total` instead of the
    `node_namespace_pod_container:...:sum_irate` recording rule, which nothing here evaluates. VictoriaMetrics
    rewrote its own k8s dashboards the same way. No other `grafana_dashboard` ConfigMap uses a recording rule, so
    running vmalert for this alone gains nothing.
  - Operator readiness (3 targets): matches `pod=~".*cloudnative-pg.*"`. Upstream anchors on `cloudnative-pg.+`,
    which assumes the release is named after the chart. Here the release is `cnpg-operator`, so its pods are
    `cnpg-operator-cloudnative-pg-*`, and the upstream regex matches nothing.
  - Backups (4 targets): read orphan-exporter's `cnpg_backup_last_success_seconds` and
    `cnpg_backup_first_recoverability_seconds`. Upstream reads `cnpg_collector_last_available_backup_timestamp`
    and `cnpg_collector_first_recoverability_point`, which the Barman Cloud plugin leaves at 0 forever. See
    [10_backups.md](10_backups.md).
  - The `Volume Space Usage: Tablespaces` panel is deleted. It is the one panel removed instead of rewritten. It
    charts `<instance>-tbs*` PVCs, and `pg-cluster` declares no tablespaces, so it could only show "No data". The
    same `-tbs` and `-wal` targets stay inside the multi-target Volume panels. There an empty target adds no series
    and costs nothing.
- **Some `cnpg` panels stay empty**, because the feature is not in use:
  - The `-wal` half of the volume panels. There is no `walStorage`, and PGDATA is one volume.
  - Tablespaces. There are none.
  - Zone. kube-state-metrics emits no `kube_node_labels`, because its `metricLabelsAllowlist` has no `nodes=`
    entry. Bare Pis have no zone anyway.
- **`persistent-volumes` replaces the stack's `persistentvolumesusage`.** `defaultDashboards.dashboards` in
  `05_victoria_metrics_k8s_stack/values.yaml` turns the upstream one off. That one shows one PVC at a time, picked
  from two dropdowns, and spends half its space on gauges. With 13 volumes, the useful view is all of them on one
  axis. This repo's version has a table of every PVC, plus timeseries for used bytes, used %, used inodes and
  inode %. Each query is `max by (namespace, persistentvolumeclaim)`, so a volume that moves node keeps its series.
  The sync job prunes the upstream ConfigMap itself (`syncJob.prune` defaults to true), so no manual cleanup is
  needed.
- **A volume panel sourced from the kubelet sees only mounted PVCs.** A bound PVC that no running pod mounts emits
  no `kubelet_volume_stats_*`. So the table can be shorter than `kubectl get pv`.
- **A ratio panel needs `or vector(0)` on the numerator.** A rate over a counter with no matching series returns
  nothing, not 0. Without the fallback, the panel goes blank in the healthy case instead of showing zero.
  Per-series ratios need `or 0 * <denominator>` instead. That refills each missing series with the labels the
  division needs to match. The 5xx panels in `ingress-http` use both.
- **vmagent's `externalLabels.cluster` collides with an exporter's own `cluster` label.** vmagent wins and renames
  the exporter's label to `exported_cluster`, without a warning. CNPG is an example. Its dashboard resolves
  `$cluster` from that label and picks instances with `pod=~"$cluster-N"`. So every panel showed "No data" while
  the metrics existed. When a third-party dashboard is empty but its metrics exist, check for `exported_*` first.
- **The fix for that collision is `honorLabels: true` on the scrape endpoint.** `pg-cluster`'s PodMonitor sets it.
  A `metricRelabelings` rule cannot fix it. vmagent merges its external labels after `metric_relabel_configs` run,
  so at that point no `exported_cluster` exists to rename. vmagent's `/api/v1/targets` shows this: the target's own
  label set carries no `cluster`. The cost applies to every series from that scrape. Those series carry the CNPG
  cluster name in `cluster`, not `offgrid`. Any other label the exporter emits would also override the target's
  label. For the CNPG pods, `cluster` is the only collision.

### Keeping the stores lean

The PVCs have plenty of headroom for the retention. So the goal is to drop data that no chart or alert uses, not
to avoid overflow. The exact drops and their reasons are comments next to the config.

- **Check every namespace before you add a drop.** A `grafana_dashboard` or `grafana_alert` ConfigMap in any
  namespace can use a metric. The sidecar runs `searchNamespace: ALL`, and cilium and cnpg ship dashboards from
  their own namespaces. A missed consumer means a broken panel you never saw.
- **Where a drop goes.** Use `globalScrapeMetricRelabelConfigs` for metrics many jobs emit. Use per-target
  `metricRelabelConfigs` for single-job families, such as the apiserver's view of etcd.
- **veth churn is the only unbounded growth.** Cilium's `lxc<random>` interface names never repeat, so every pod
  restart creates permanent new series. Two places drop them: node-exporter flags for `node_network_*`, and the
  vmagent list for cAdvisor's `container_network_*`.
- **That drop changes panel values.** The Kubernetes Views network panels sum `container_network_*` with no
  `interface` filter. Keeping only `eth0` brings them down to the real number.
- **60s is the floor.** `dedup.minScrapeInterval` discards samples scraped faster. Check the interval of each new
  scrape.
- **Postgres settings.** `lib/helm/pg-cluster` keeps only `cnpg_pg_settings_setting{name="max_connections"}`,
  which the connection-saturation alert reads. It drops the rest of the per-setting config dump. To alert on
  another Postgres setting, widen that keep list.
- **Logs are not a storage problem.** Container logs are about 5800 lines and 4.4MB a day against a 30Gi PVC. 75%
  of that comes from the three sample workloads.
  - `rabbitmq-messaging-topology-operator` runs with `logLevel: error`. At the default level it wrote about 55% of
    all container logs. `error` also drops WARN lines. Failures still show in CR status conditions, Kubernetes
    events and the `rabbitmq-health` alerts.
  - The collector drops its own logs before it reads them, through `excludeFilter` in `05_victoria_logs`.
  - Talos node logs add about 1.5MB a day per node, with `auditd.log` and `dns-resolve-cache.log` excluded. To cut another loud service, add
    its path to `excludeGlob` next to the `fileCollector` glob. That drops the whole file. There is no per-line
    filter.
- **Two file sources can surprise you: the audit log and Hubble drops.** Both are filtered at the source, not in
  the collector. The apiserver's audit policy filters the audit log. `includeFilters` in `00_cilium` filters the
  Hubble drops. Widening either one is what would fill the store, so size the change before you make it.
- **Envoy access logs show `_msg` as "missing _msg field".** That is harmless. Envoy Gateway's default JSON access
  log has no key the collector maps to `_msg`. All structured fields are queryable, for example
  `response_code:500`. A `telemetry.accessLog` block on the EnvoyProxy CR would fix it, but the fix is cosmetic.

### Loud lines nothing can drop

`excludeFilter` matches container metadata: namespace, pod, container and labels. It runs before the collector
opens the log file, so it cannot match message text. Nothing else in the vlagent and VictoriaLogs ingest path drops
a line by content either. `ignoreFields` drops fields, not lines. So these three patterns stay, about 6000 lines and
1.5MB a day:

| Pattern | Volume | What it is |
|---|---|---|
| kube-apiserver `grpc: addrConn.createTransport failed to connect to 127.0.0.1:2379` | 4300/d | The etcd health probe closes a connection mid-dial, once a minute per apiserver. Check `talosctl etcd members` and service health before you treat it as a fault |
| longhorn-manager `Warning: v1 Endpoints is deprecated in v1.33+` | 1150/d | A client-go warning on Longhorn's own API calls. It goes away when upstream migrates |
| argocd `DiffFromCache error: ... cache: key is missing` | 200/d | Argo CD logs the cache miss at ERROR, then does a full diff |

None of these lines carries a `level` field. So none reaches the `high-error-log-rate` alert, which counts only
`level:error` and `level=error`. Ignore them when you browse vlogs. Do not widen that alert's exclusion list for
them.

### Pinned versions

Each app's `Chart.yaml` holds its chart version. Renovate groups the VictoriaMetrics charts so they bump together.
Two constraints:

- `victoria-metrics-operator-crds` and `victoria-metrics-operator` must ship the same operator app version. Bump
  them together.
- `00_prometheus_operator_crds` is the converter's source. Do not remove it.

## Grafana

Grafana runs from the standalone `grafana/grafana` chart:

| Release | Namespace | Chart | Persistence |
|---|---|---|---|
| `grafana` | `monitoring` | `05_grafana` | none |

It is the dashboards and Explore UI over the two datasources, and it owns alerting. It runs on its own, not as the
k8s-stack subchart, so it versions, syncs and rolls back independently. No feature is lost.

### Provisioned as code

Two datasources:

- VictoriaMetrics: type `prometheus`, uid `VictoriaMetrics`.
- VictoriaLogs: the signed `victoriametrics-logs-datasource` plugin, uid `VictoriaLogs`.

The UIDs match the k8s-stack defaults, so synced dashboards resolve. The datasources sidecar is off, because
`values.yaml` provisions the datasources inline. The dashboards sidecar stays on (`searchNamespace: ALL`). It
ingests the k8s-stack's `grafana_dashboard` ConfigMaps on every start.

Alerting is not inline in `values.yaml`. The contact point, the notification policy and every rule group each live
in their own file under `05_grafana/files/alerts/*.yaml`. The contact point is an ntfy webhook to the self-hosted
`05_ntfy`. The files ship as ConfigMaps labelled `grafana_alert`, and the chart's alerts sidecar loads them. This is
the same model as dashboards. So `values.yaml` stays small, and each group is its own file with its own diff.

The chart reads the files raw through `.Files.Get`, without Helm templating. So the Grafana `{{ $labels.x }}` and
severity templates are plain literals that need no escaping.

Rules survive a restart, because they are provisioned. Alert state resets on restart, because there is no PVC.

### Alert content convention

Every rule carries exactly two annotations. The ntfy payload maps them directly to the push notification:

- **`summary`** becomes the notification title. One line, resource first, saying what is wrong. Lead with the
  faulty object, for example `Redis {{ $labels.namespace }}/{{ $labels.pod }} ...`. An alert about the whole
  cluster names the subsystem instead, for example API server 5xx, CoreDNS down or Cilium agent count.
- **`description`** becomes the notification message. Short `-` bullets in fragments: what is wrong and how to fix
  it. Add a real `kubectl`, `redis-cli` or `cnpg` diagnosis command where it helps. Actionable and brief, no prose.

Two wiring choices make sure the resource name reaches the phone:

- `policies.yaml` uses `group_by: ['...']`, which groups by all labels. So each faulty resource gets its own
  notification.
- `contactpoints.yaml` reads the annotations of each alert through `(index .Alerts 0).Annotations.summary`, not
  `.CommonAnnotations`. `.CommonAnnotations` goes empty without a warning whenever two grouped alerts differ. That
  is when you most need the name.

Add both annotations to every new rule.

### `execErrState: KeepLast` on every rule but one

An evaluation error is not a firing alert. Under `execErrState: Error`, a rule that cannot run its query goes to
Alerting with no query labels. So every `{{ $labels.x }}` in the summary renders as `[no value]`. All rules share
one datasource, so one vmsingle outage flips all of them at once. Example: one node drain sent 51 firing and 51
resolved notifications in five minutes. None of them named a resource, and they buried the two real alerts in the
same window.

So every rule sets `execErrState: KeepLast` and holds its previous state through the gap. The one exception is
`metrics-datasource-down` in `monitoring-health.yaml`, which keeps `Error` on purpose. Its job is to report that
queries fail, so it turns the storm into one notification. Give every new rule `KeepLast`.

The gap this leaves: a rule with a permanently broken query stays silent on its last state instead of alerting. A
metric that a chart bump renamed is an example. The datasource canary does not catch that. It catches only total
failure. Re-check the queries after you bump a chart that renames metrics.

### Alert severity model and the `alert-criticality` label

Alerts carry one of two severities, `critical` or `warning`, never `info`. The ntfy webhook maps them to priority 5
and 4. Severity depends on what broke and on how important the component is:

| What the alert means | Component labelled `alert-criticality: critical` | Not labelled |
|---|---|---|
| Outage: workload down, or broken so it cannot serve | critical | warning |
| Anomaly or about to break: degraded, saturating, restarting, near a limit, capacity | warning | warning |

So `critical` fires only when an outage-class alert triggers on a component that opted in with the label. Every
other alert is `warning`. Two static `critical` alerts sit outside the model. Both are node-level, not workload
alerts:

- `Node NotReady`.
- `node-undervoltage`. It is the one hardware fault that corrupts data instead of only slowing things down.

To opt a component in, put `alert-criticality: critical` on it. The label must reach the object that the firing
alert keys on:

- **Plain Deployments, StatefulSets and DaemonSets:** set it on both the workload `metadata.labels` and the pod
  template `spec.template.metadata.labels`. Then the object and its pods both carry it.
- **CNPG Postgres:** set `alertCritical: true` on the database, per consumer alias. CNPG has no Deployment or
  StatefulSet. The operator's `INHERITED_LABELS: alert-criticality` copies the label from the Cluster CR onto the
  Postgres pods, and the pod path is what pages. The wrapper always stamps the label as critical or warning, so it
  is never absent.
- **Redis:** set `alertCritical: true` on the instance. The OpsTree operator copies the CR label onto the
  StatefulSet and pods. The default is `false`, because a plain cache that is down usually only degrades the app.
- **Ingress:** the EnvoyProxy labels the merged Envoy proxy pods critical (`envoyDeployment.pod.labels`). So a
  crashlooping ingress pod pages critical through `container-waiting-fatal`.

The label value is the plain string `critical`, which explains itself. A numeric value would save nothing.

How the label drives severity:

1. `metricLabelsAllowlist` tells kube-state-metrics to expose the label as a metric dimension. Without that setting
   it emits no `kube_*_labels` at all. So the one setting both creates the join target and adds the
   `label_alert_criticality` dimension.
2. Each outage-class rule joins the label into its series with
   `<expr> * on(<keys>) group_left(label_alert_criticality) kube_<obj>_labels`.
3. A per-instance Grafana label template then sets the severity:

```yaml
severity: '{{`{{ if eq $labels.label_alert_criticality "critical" }}critical{{ else }}warning{{ end }}`}}'
```

An absent label evaluates to `""`, so the severity is `warning`. Anomaly-class rules skip the join and set
`severity: warning` statically.

### The global alert catalog

One rule per problem, all cluster-wide. Each group is its own file under `05_grafana/files/alerts/`.

| Group | Severity | Rules |
|---|---|---|
| `workload-outages` | dynamic | `deployment-not-available`, `statefulset-not-available`, `daemonset-not-available` (all: desired>0, 0 available), `container-waiting-fatal` (stuck 15m+ in CrashLoopBackOff, ImagePullBackOff or config error) |
| `workload-anomalies` | warning | `container-oomkilled`, `-high-restarts`, `-cpu-throttling`, `-memory-near-limit`, `pod-pending`, `pod-not-ready`, `replicaset-degraded`, `deployment-degraded`, `deployment-generation-mismatch`, and 3 HPA rules, dormant until an HPA exists |
| `cluster-health` | warning, `node-not-ready` static critical | `node-disk-space`/`-inodes` (>85%), `node-disk-fill-predict` (24h), `node-high-memory` (>90%), `node-memory-committed` (requests >80% allocatable), `node-high-cpu`, `node-pressure`, `cluster-memory-overcommit` (cannot absorb one node loss), `pvc-nearly-full`, `target-down` |
| `storage-tls-health` | warning | `cert-expiring-soon` (<14d), `cert-not-ready`, `pv-errors`, `pvc-pending` |
| `longhorn-health` | mixed | `longhorn-manager-down` (critical deadman), `-node-down`, `-disk-unschedulable`, `-node-storage-high` (>85%), `-volume-degraded`, `-volume-faulted` (critical, 0 healthy replicas), `-volume-near-full` (>90%) |
| `argocd-health` | warning | `argocd-app-unhealthy` (15m), `argocd-app-out-of-sync` (30m), `argocd-app-comparison-error` |
| `cilium-health` | warning | `cilium-agent-down` (<3), `cilium-bpf-map-pressure` (>80%), `cilium-unreachable-nodes` |
| `control-plane` and `dns` | mixed | `apiserver-error-rate-high` (critical, >5% 5xx), `coredns-down` (<2), `coredns-serverfail-rate` (>2%) |
| `monitoring-health` | mixed | `metrics-datasource-down` (critical, the only `execErrState: Error` rule), `vmsingle-near-read-only` (critical), `vmagent-dropping-samples`, `victorialogs-errors` |
| `sealed-secrets-health` | static critical | `sealed-secrets-not-ready` (10m). A down controller blocks all decryption in the cluster |
| `ingress-http` | mixed, per route | `ingress-5xx-high` (>2%), `-4xx-high` (>25%), `-latency-p95-high` (>2s), `-no-healthy-upstream` (critical, the 503 cause), `-upstream-connect-failures` |
| `cnpg-health` | `cnpg-instance-not-ready` dynamic, rest warning | `-high-connections-*`, `-replication-lag-*`, `-txid-wraparound-*` (>300M, >1B), `-replication-slot-inactive`, `-long-running-transaction`, `-backends-waiting`, `-deadlocks`, `-manual-switchover-required`, `-fencing-on` |
| `rabbitmq-cluster` | static | `-cluster-down` and `-quorum-at-risk` (critical, <2 nodes), `-node-down` (warning, <3), `-memory-alarm` and `-disk-alarm` (critical, publishers already blocked), `-disk-low` |
| `rabbitmq-queues` | warning | `-queue-no-consumer`, `-queue-backlog` and `-queue-unacked` (>100), `-dlq-not-empty`, `-dead-letter-rate` |
| `redis-health` | `redis-down` dynamic, rest warning | `-memory-high` and `-memory-critical` (percent of maxmemory. The policy is noeviction, so writes fail near 100%), `-rejected-connections` and `-connections-high`, `-rdb-save-failing` and `-aof-write-failing`, `-fragmentation-high` |
| `backups` | warning, 2 critical | Redis, Longhorn, CNPG and VM/VL backup failure and staleness, and the two unrecoverable-catalog rules. See [10_backups.md](10_backups.md) |
| `orphan` | warning | orphaned and untracked CNPG, Redis and VM/VL CRs, and the exporter deadman. See [10_backups.md](10_backups.md) |
| `node-hardware` | warning, `node-undervoltage` static critical | `node-undervoltage` (the board's own low-rail alarm), `node-soc-temp-high` (>80C, where an ARM SoC throttles), `node-cpu-temp-high` (>90C, x86, below its ~100C shutdown), `node-cpu-throttled` (the CPU reports that it clocked itself down) |
| `smart-health` | mixed | `smart-device-failing` (critical, the drive's own verdict), `smart-nvme-critical-warning` and `smart-spare-low` (critical), `smart-media-errors` (new errors in 24h), `smart-wear-high` (>80% of rated endurance), `smart-device-temp-high` (>70C), `smart-sata-reallocated` |
| `probes` | warning | `ingress-probe-failing`, `ingress-cert-expiring` (<14d, on the cert the edge serves). See "Synthetic probes" |
| `alerting-path` | warning | `alert-delivery-failing`: Grafana's webhook to ntfy fails, so alerts fire and nobody is told |

Notes:

- `longhorn_volume_robustness` is a state-labelled metric here, `{state="degraded|faulted|..."}=1`, not a numeric
  0 to 3 gauge. So those rules select on `state`.
- `ingress-http` groups by `envoy_cluster_name`, one per ingress chart instance, so alerts are per route. Error
  rules carry a small request-volume floor. Per-virtual-host downstream stats would need `enableVirtualHostStats`.
  That stays off, because the per-cluster stats already give per-route data.
- A down component process fires `target-down`, not a per-app rule. kube-scheduler and kube-controller-manager are
  not scraped, because the Talos machine-config metrics bind does not take effect. So they have no alerts. Fix the
  scrape first.
- CNPG CPU, memory and disk fall to the generic container rules, and to `node-disk-space` and `pvc-nearly-full`.

Coverage:

- An outage always pages critical for labelled Deployment, StatefulSet and DaemonSet workloads.
- It always pages critical for any crashlooping container labelled critical, CNPG included.
- It always pages critical for a labelled CNPG instance that is up but not serving.
- A CNPG pod that is not ready for other reasons pages warning through `pod-not-ready`.
- The Envoy Deployment object carries no label. Only its pods do. So a graceful ingress scale to zero warns and
  does not page.

### No persistence

`persistence.enabled: false` is an explicit requirement. It is safe because Grafana holds no state worth keeping.
Datasources and curated dashboards provision again on each start, and alert rules come from files.

Trade-off: a pod restart loses dashboards and settings created in the UI, and alert state. Add a small `longhorn`
PVC if that ever matters.

Grafana runs one replica. More replicas first need `unified_alerting.ha_*` in `grafana.ini`, or each replica sends
every alert. With persistence off, replicas also do not share silences and annotations made in the UI.

### Anonymous Admin, gated by SSO

Settings: `auth.anonymous.enabled: true` with `org_role: Admin`, `disable_login_form: true`, and basic auth on.
The sidecars reload dashboards and alerts through an admin API that accepts only basic auth.
Every request reaches Grafana already authenticated at the edge, by the Gateway's Google SSO and email allowlist.
So there is no second login.

This is safe only because the edge gates it. Anonymous Admin makes every allowlisted SSO user a full Grafana admin.
That is acceptable for a small trusted allowlist, and the gateway allowlist is the real boundary. Lower
`auth.anonymous.org_role` to `Viewer` if that is ever too broad.

### ntfy alerting, mobile push instead of email

Alerts go to your phone through self-hosted ntfy (`05_ntfy`), not email. Grafana's webhook contact point publishes
to the in-cluster ntfy Service on the `cluster-alerts` topic. The Android app subscribes over the public edge
`ntfy.ops.example.com` (`06_platform_ingress`).

That edge:

- uses `letsencrypt-prod`, because the app validates TLS.
- is not behind Google SSO, on purpose, because the mobile app cannot do a human OAuth login. ntfy's own deny-all
  default, with token and user auth, is the gate.

The webhook payload maps the firing alert's `summary` to the push title and `description` to the push message.
Priority and tag come from `severity`: critical is 5, warning is 4.

ntfy is a private deny-all instance with no declarative user config. So `lib/shell/06_ntfy_auth.sh`
(`make configure-ntfy-auth`) seeds two users on `cluster-alerts`. Run it once after the ntfy pod is up:

- `phone`: read-only. The password comes from `NTFY_PHONE_PASSWORD_SECRET` in `.env`.
- `grafana`: write-only.

The script then mints Grafana's write token and seals it into the `grafana-ntfy` Secret under key `token`. Grafana
reads it as `GF_NTFY_TOKEN` and puts it into the webhook's `authorization_credentials`. That env var is optional, so
Grafana starts before the token is sealed. With `NTFY_PHONE_PASSWORD_SECRET` empty, the script offers to delete the
sealed token, which turns off ntfy alerting.

This is the only imperative script for this step. The VM stack and metrics-server are pure GitOps. The
platform-ingress app at wave 6 serves Grafana's `grafana.ops.example.com` edge, not the `05_grafana` chart. See
[04_ingress.md](04_ingress.md).

#### Watching the alert path itself

The chain is Grafana to ntfy to phone. If it breaks, the part that would tell you is the part that broke. Three
partial checks cover it. All of them run in the cluster, because there is nothing off-cluster to escalate to, on
purpose:

- **ntfy metrics.** ntfy runs a separate metrics listener on `:9091` (`metrics-listen-http`), scraped by a
  PodMonitor. It is separate so the internet-facing `:8080` never serves `/metrics`. A dead ntfy is then a down
  scrape target, so `target-down` covers it and no ntfy-specific rule is needed.
- **`alert-delivery-failing`** counts Grafana's failed webhook POSTs. It catches a wrong topic, an expired token or
  a rejected publish while ntfy itself is healthy.
- **The blackbox probe** of `https://ntfy.ops.example.com/v1/health` covers the public edge the phone uses. The
  in-cluster Service path never touches that edge.

None of these can page you, because each depends on the path it tests. They fire in the Grafana UI and resolve on
their own, so you get a record after the fact. Closing that gap needs a receiver outside the cluster.

### Verify

```bash
kubectl -n monitoring get deploy,pod -l app.kubernetes.io/name=grafana   # Running, no PVC
# Open https://grafana.ops.example.com: Google SSO first, then straight into the UI as anonymous Admin.
# Connections, then Data sources, lists VictoriaMetrics and VictoriaLogs. The curated dashboards are listed.
```

## metrics-server

The observability stack collects custom metrics but does not serve `metrics.k8s.io`. That is the in-tree
resource-metrics API that HPA, `kubectl top` and the scheduler expect from an aggregated APIService.
[metrics-server](https://github.com/kubernetes-sigs/metrics-server) fills that gap. It scrapes each kubelet's
Summary API over HTTPS on `:10250` and registers `v1beta1.metrics.k8s.io`.

It is a thin wrapper chart at `argo_apps/platform/charts/02_metrics_server/`: one replica, 50m CPU and 100Mi
memory, in `kube-system`. It emits a ServiceMonitor for its own `/metrics`. The VM operator's converter picks that
up like every other ServiceMonitor.

### `--kubelet-insecure-tls`

metrics-server verifies the kubelet serving cert by default. On Talos that cert is self-signed, so verification
fails. `--kubelet-insecure-tls` skips the cert identity check. The connection stays TLS-encrypted.

- `--kubelet-preferred-address-types=InternalIP` stays at the chart default. The kubelet serving-cert SANs are node
  IPs, and Talos hostnames are not in DNS.
- `--kubelet-certificate-authority` is not used. It works only if the kubelet cert is CA-signed, and Talos does not
  do that by default.

The secure path gains little here. The hop is pod to kubelet on the cluster's own trusted wired L2 segment, and the
connection is encrypted either way. Only the cert identity goes unchecked. So this setup takes the one-flag route,
with no OS change.

To move to the secure path and drop the flag:

1. Add `rotate-server-certificates: true` to your `cp-patch.yaml` and re-apply it to all three nodes.
2. Add a CSR-approver platform app. Kubernetes never auto-approves `kubernetes.io/kubelet-serving` CSRs. The
   approver Talos documents, `alex1989hu/...`, ships raw kustomize, which breaks the wrapper-chart convention. The
   Helm-native `postfinance/kubelet-csr-approver`, with SAN and IP-regex config, fits.
3. Replace the flag with `--kubelet-certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`.

### Verify

```bash
export KUBECONFIG=.cache/kubeconfig
kubectl get apiservice v1beta1.metrics.k8s.io    # AVAILABLE: True
kubectl top nodes                                # the real end-to-end check
kubectl top pods -A
```

If `kubectl top` shows a TLS error despite `--kubelet-insecure-tls`, move to the secure path. Do not debug the flag.

## Rightsizing (KRR)

Catching over- and undersized containers has two halves:

- **A continuous view.** The Grafana `k8s_views_pods` dashboard shows usage against requests, always on. It does
  not give a concrete number to set.
- **A number to set.** [KRR](https://github.com/robusta-dev/krr) reads usage history from the metrics store. For
  each workload, it prints the current request next to a recommended one, for CPU and memory.

Run KRR on demand:

```bash
make krr                        # table
make krr-json
make krr-yaml
bash lib/shell/krr.sh -n <ns>   # any other flag: the script passes "$@" to KRR unchanged
```

It runs the custom `conservative` strategy by default. The upstream `simple` and `simple-limit` strategies still
work. It scans every namespace, including `kube-system`, which KRR skips by default.

### Why on-demand, not automated

At 3-node homelab scale, with a few workloads and one operator, a weekly in-cluster CronJob with a report store and
a dedicated Robusta UI is too much. `make krr` fits: run it when you want to retune, read the table, then edit the
relevant chart `values.yaml` by hand.

It also fits the repo's tooling conventions:

- KRR runs in Docker.
- It reaches the metrics store over the break-glass port-forward that `05_victoria_metrics_k8s_stack` already
  documents.
- It reaches the kube API through the pinned kubeconfig.
- It reuses `MONITORING_NS`. It adds no cluster workload, no Argo CD app and no SSO host.

### The `conservative` strategy

`lib/krr/conservative.py` is a custom KRR strategy for this cluster's scarce RAM. The built-in `simple` strategy
sets memory `request == limit == peak + buffer`. The scheduler reserves the `request`, so a request at the peak
permanently books memory that is rarely used, and fewer pods fit on a node. `conservative` splits request and
limit:

- **Memory request** = max(average working set, 16Mi). The scheduler packs on typical use, not peak. The 16Mi floor
  matches the idle working set, so the node does not overcommit.
- **Memory limit** = max(peak x 1.5, 32Mi). For a workload OOMKilled during the window, the limit rises to the
  OOMKilled limit plus 25%. This uses `--use-oomkill-data`, on by default. An OOMKill proves the ceiling was too
  low, so the increase lands on the limit, not the request.
- **CPU** is the same as `simple`: the request is the 95th percentile, and there is no limit, because CPU is
  compressible.

The two memory floors differ: 16Mi for the request, 32Mi for the limit. KRR's single `--mem-min` cannot express
that, because it floors request and limit to the same value. So the floors live inside the strategy, and `krr.sh`
runs with `--mem-min 0` to give the strategy control of the floors.

Why two floors:

- The request floor is a scheduling concern. It reserves about the idle footprint. Too low means node overcommit
  and eviction.
- The limit floor is OOM headroom for cold-start and GC spikes. A low request never OOM-kills a pod. Only the limit
  does.
- Both floors are knobs at the top of `krr.sh`.

Trade-off: requests no longer cover the peak. So peaks in several pods at once can exhaust node RAM. That triggers a
kernel or node-pressure OOMKill, even while each pod is under its own limit. That is the price of the density. Keep
node eviction headroom and watch for OOMKills.

The strategy loads without an image rebuild. `lib/shell/krr.sh` bind-mounts `conservative.py` into the image's
`robusta_krr/strategies/` package. It also mounts a shadow `__init__.py` that imports it, so KRR's subclass
discovery registers the strategy. Both files depend on the pinned KRR's internals. Revisit them on an image bump.

### Metrics dependency

`conservative` reads these series:

- `container_cpu_usage_seconds_total`
- `container_memory_working_set_bytes`, through both `max_over_time` and `avg_over_time`
- `kube_pod_container_resource_limits` and `kube_pod_container_status_last_terminated_reason`, for the OOMKill
  floor

vmagent's drop list keeps all four, although it drops a lot otherwise. So `--use-oomkill-data` has data here.
VictoriaMetrics speaks the Prometheus query API, so the queries run unchanged. If a future drop-list change removes
the OOM series, the flag degrades gracefully. That loader sets `warning_on_no_data = False`, so KRR only stops
raising limits.

### Docker networking note

The script runs KRR on the default bridge network, not `--network host`, and points it at
`http://host.docker.internal:<port>`. On Docker Desktop and macOS, a host-network container cannot see the
host-side port-forward. The bridge reaches it through `host.docker.internal`. The kube API VIP is a LAN IP, and the
bridge reaches it through NAT.

### Verify

```bash
make krr    # a KRR table: workload | cpu request vs recommended | mem request vs recommended
# Expect no "metric not found" or connection-refused errors. Compare one row with the
# k8s_views_pods Grafana dashboard: measured usage should sit near KRR's recommended request.
```
