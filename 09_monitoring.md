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
Both VMSingle and VLSingle PVCs use the `longhorn` (replica-3) class. Metrics retention 180d, logs 60d
(logs are bulkier, their own shorter window). Metrics start fresh (no `vmctl` backfill). The logs store is
the operator `VLSingle` CR (one operator for everything), not the standalone logs chart. node-exporter and
the log collector are DaemonSets with `tolerations: [{operator: Exists}]` — this is an all-control-plane
cluster, so a `node-role.kubernetes.io/control-plane: DoesNotExist` selector would match ZERO nodes.

Each UI (vmui, vlogs) is exposed by the consolidated platform-ingress app (wave 8) behind Google SSO,
not by its own chart; see [07_ingress.md](07_ingress.md).

### Pinned versions

| Chart | Version | appVersion |
|-------|---------|------------|
| `victoria-metrics-operator-crds` | 0.12.0 | v0.72.0 |
| `victoria-metrics-operator`      | 0.65.1 | v0.72.0 |
| `victoria-metrics-k8s-stack`     | 0.85.5 | v1.146.0 |
| `victoria-logs-collector`        | 0.3.6  | v1.51.0 |

The CRDs chart's appVersion must match the operator version (both `v0.72.0`); bump together. `00_prometheus_operator_crds`
(v0.92.0) is kept as the converter's source — do not remove it.

## Grafana

Standalone `grafana/grafana` chart (release `grafana`, ns `monitoring`, chart `07_grafana`, no persistence):
the dashboards/Explore UI over the two datasources and the owner of alerting. Run on its own rather than as
the k8s-stack subchart so it versions/syncs/rolls back independently, no feature loss.

### Provisioned as code
- Two datasources: VictoriaMetrics (type `prometheus`, uid `VictoriaMetrics`) and VictoriaLogs (the signed
  `victoriametrics-logs-datasource` plugin, uid `VictoriaLogs`). UIDs match the k8s-stack defaults so synced
  dashboards resolve. The **datasources sidecar is OFF** (provisioned directly); the **dashboards sidecar
  stays ON** (`searchNamespace: ALL`) and ingests the k8s-stack's `grafana_dashboard` ConfigMaps on every
  start.
- Contact point (Gmail email), notification policy, and an alert rule group (node NotReady, high node
  mem/CPU, pod CrashLoopBackOff, PVC >85%, target down, plus a VictoriaLogs error-rate alert). Rules are
  file-provisioned (survive restart); alert *state* resets on restart (no PVC).

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

### SMTP secret
Grafana's Gmail app-password comes from `SMTP_GOOGLE_APP_PASSWORD_SECRET` in the gitignored `.env`; `09_monitoring/09_grafana_smtp.sh`
seals it into the `grafana-smtp` Secret (key `password`), surfaced as `GF_SMTP_PASSWORD` (optional, so Grafana starts
before it's sealed). Leave the var empty and the script offers to delete the sealed file (disables outgoing email).
Host/user/from are non-secret in the values. This is the only imperative script for this step; the VM stack
and metrics-server are pure GitOps.

Grafana's `grafana.example.com` edge (Gateway + Certificate + SSO HTTPRoute) is served by the consolidated
platform-ingress app (wave 8), not the `07_grafana` chart; see [07_ingress.md](07_ingress.md).

### Verify
```bash
kubectl -n monitoring get deploy,pod -l app.kubernetes.io/name=grafana   # Running; no PVC
# Browse https://grafana.example.com -> Google SSO first, then straight into the UI (anonymous Admin).
# Connections -> Data sources shows VictoriaMetrics + VictoriaLogs; curated dashboards listed.
```

## metrics-server

The observability stack collects rich custom metrics but does **not** serve `metrics.k8s.io`, the narrow
in-tree resource-metrics contract that HPA, `kubectl top`, and the scheduler expect from an aggregated
APIService. [metrics-server](https://github.com/kubernetes-sigs/metrics-server) fills exactly that gap: it
scrapes each kubelet's Summary API over HTTPS (`:10250`) and registers `v1beta1.metrics.k8s.io`. Thin
wrapper chart at `argo_apps/platform/charts/02_metrics_server/` (`3.13.1` → metrics-server `v0.8.1`),
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
export KUBECONFIG=03_operating_system/talos-cluster/kubeconfig
kubectl get apiservice v1beta1.metrics.k8s.io    # AVAILABLE: True
kubectl top nodes                                # the real end-to-end check
kubectl top pods -A
```
A TLS error from `kubectl top` despite `--kubelet-insecure-tls` is the signal to move to the secure path,
not to debug the flag.
