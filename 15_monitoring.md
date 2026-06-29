# 15 — Monitoring

> **2026-06 migration — now an all-VictoriaMetrics stack.** The metrics core moved off
> kube-prometheus-stack to **VictoriaMetrics + VictoriaLogs**, with **alerting owned by the standalone
> Grafana** (no Alertmanager, no vmalert). The section immediately below is the current design; the
> "(prior design) — kube-prometheus-stack" narrative further down is kept as the **prior** decision record
> (history).

## VictoriaMetrics / VictoriaLogs (current)

```
node-exporter (DS, all 3 nodes) ┐                         ┌─ VMSingle  (1×, 50Gi Longhorn PVC, 180d)  ── vmui  ─┐
kube-state-metrics ┐            │  VMServiceScrape/        │                                                    │
cilium/hubble, argocd, cert-mgr,│  VMPodScrape (converted │  vmagent (Deploy, selectAllByDefault) ─scrapes─────┤  per-UI Gateways
longhorn, sealed-secrets ───────┼─ from ServiceMonitors)  │                                                    ├─ + Google SSO
control-plane (etcd/sched/kcm) ─┘  (cluster-wide)         └─ VLSingle (1×, 30Gi Longhorn PVC, 60d)  ── vlogs ──┤  (sso: example.com)
                                                              ▲                                                 │
victoria-logs-collector (DS, all 3 nodes) ─ remote-write ─────┘     Grafana (1×, no PVC) ── alerts (email) ─────┘
                                                                       └ datasources: VictoriaMetrics + VictoriaLogs
vm operator ── reconciles VM*/VL* CRs AND converts prometheus-operator objects (ServiceMonitor→VMServiceScrape, …)
```

**Why VictoriaMetrics.** One operator covers both metrics (VM*) and logs (VL*); far lighter than
Prometheus+Loki on 8GB Pi 5 nodes; PromQL-compatible so dashboards/queries port unchanged. The operator's
**prometheus-operator converter** turns every existing `ServiceMonitor`/`PodMonitor`/`PrometheusRule`/`Probe`
(cilium, argocd, cert-manager, longhorn, sealed-secrets, …) into the VM equivalent **with no rewrites** —
that's why the `monitoring.coreos.com` CRDs are **preserved** (the wave-0 `00_prometheus_operator_crds` app
stays; it's the converter's source). The converter stamps ArgoCD-ignore annotations on its output
(`operator.prometheus_converter_add_argocd_ignore_annotations: true`) so ArgoCD never fights or prunes
operator-created objects.

**Shape B — Grafana owns alerting.** `vmalert` and `vmalertmanager` are OFF; Grafana provisions the contact
point + notification policy + alert rules as code ([16_grafana.md](16_grafana.md)). Dropping vmalert means
the stack's default recording/alerting **VMRules are not created** (`defaultRules.create: false`) — Grafana
alert expressions are inlined PromQL instead.

**Decisions (this migration).** Both VMSingle and VLSingle PVCs use the existing **`longhorn` (replica-3)**
class. Metrics retention **180d**, logs retention **60d** (logs are bulkier → their own shorter window).
Metrics start **fresh** (no `vmctl` backfill — the cluster was nearly empty). VictoriaLogs store is the
operator **`VLSingle` CR** (one operator for everything), not the standalone logs chart. node-exporter and
the log collector are **DaemonSets with `tolerations: [{operator: Exists}]`** — this is an all-control-plane
cluster, so a `node-role.kubernetes.io/control-plane: DoesNotExist` selector would match ZERO nodes.

**Wave consolidation.** Only three waves are touched: **0** = CRDs (`00_prometheus_operator_crds` preserved
+ `00_victoria_metrics_operator_crds`, both prune:false); **1** = the VM operator (admission webhook); **7**
= everything data-plane (`07_victoria_metrics_k8s_stack`, `07_victoria_logs`, `07_grafana`) together. Each of
those three **also owns its own edge** — the per-UI `Gateway` + `Certificate` + `sso`-labelled `HTTPRoute` +
`ReferenceGrant` live in the same chart as the Service they front (`ingress:` block in each `values.yaml`,
`templates/edge-*.yaml`), folded in from the retired standalone `07_monitoring_ingress`. Shipping the route
beside its backend means its `backendRef` resolves the instant the Service appears, and co-wave apps never
artificially block each other. By the time the root reaches wave 7 the operator (wave 1) is long Healthy, so
its webhook validates the VMSingle/VLSingle/VMAgent CRs; brief cross-app `ResolvedRefs:False` /
datasource-down states self-clear.

**Talos control-plane scrapes.** kube-controller-manager (:10257, https, self-signed → insecureSkipVerify),
kube-scheduler (:10259, same), etcd (:2381, plain http — Talos `listen-metrics-urls`) are exposed via Talos
machine config (applied OUTSIDE ArgoCD) and scraped by static `endpoints` at the CP node IPs
(192.168.10.201-203). kube-proxy is OFF (Cilium replaces it). apiserver/etcd high-cardinality histograms are
dropped via `metricRelabelConfigs`, exactly as the old stack did.

**SMTP.** Grafana's Gmail app-password is sealed by `16_grafana_smtp/16_grafana_smtp.sh` into the
`grafana-smtp` Secret (key `password`), surfaced as `GF_SMTP_PASSWORD` (optional, so Grafana starts before
it's sealed). Host/user/from are non-secret in the 07_grafana values.

### Pinned versions (current)

| Chart | Version | appVersion |
|-------|---------|------------|
| `victoria-metrics-operator-crds` | **0.12.0** | v0.72.0 |
| `victoria-metrics-operator`      | **0.65.1** | v0.72.0 |
| `victoria-metrics-k8s-stack`     | **0.85.5** | v1.146.0 |
| `victoria-logs-collector`        | **0.3.6**  | v1.51.0 |
| VLSingle (operator image)        | —          | v1.51.0 |

The CRDs chart's appVersion **must** match the operator version (both `v0.72.0`). Bump together: change
`Chart.yaml`, `helm dependency build`, commit the refreshed `Chart.lock`. The `00_prometheus_operator_crds`
app (v0.92.0) is **kept** — it is the converter's source; do not remove it.

### Cutover (CRD-safe)

1. Land waves 0–1 (VM CRDs + operator) and the wave-7 VM/VL/grafana apps (each carrying its own edge) additively; confirm
   `kubectl get vmservicescrape,vmpodscrape -A` shows a converted equivalent for every pre-existing
   ServiceMonitor/PodMonitor. The VM stack's node-exporter is gated OFF here
   (`prometheus-node-exporter.enabled: false`) so it doesn't clash with the still-running kube-prometheus
   one on **hostPort 9100**.
2. Clean swap: `git rm` the `07_kube_prometheus_stack` app + chart (the root prunes its Prometheus,
   Alertmanager, node-exporter, KSM) AND flip the VM node-exporter to `enabled: true`. Brief metrics gap is
   acceptable. The `monitoring.coreos.com` CRDs survive (owned by the wave-0 app, not the stack).

---

## (prior design) — kube-prometheus-stack

The cluster's metrics core: **Prometheus + Alertmanager + node-exporter + kube-state-metrics**,
operator-managed, single-replica StatefulSets backed by Longhorn. Bundled **Grafana stays off** (a
standalone one lands later) but the stack still emits its curated dashboard/datasource ConfigMaps.
ServiceMonitors are switched on across the existing components so they're actually scraped. The
Prometheus + Alertmanager UIs are exposed on the shared Gateway behind the same Google SSO as the
ArgoCD UI ([14_argocd_ingress.md](14_argocd_ingress.md)).

```
node-exporter (DS, all 3 nodes) ┐
kube-state-metrics ┐            │
cilium/hubble, argocd, cert-mgr,│  ServiceMonitors   ┌─ Prometheus (1×, 50Gi Longhorn PVC, 120d/40GiB)
longhorn, sealed-secrets ───────┼───────────────────►│
control-plane (etcd/sched/kcm) ─┘  (cluster-wide)    └─ Alertmanager (1×, 1Gi) → email | null
                                                          ▲
prometheus-operator ── manages ───────────────────────────┘  (CRDs from the wave-0 app)
```

## Pinned versions

| Chart | Version | appVersion |
|-------|---------|------------|
| `prometheus-operator-crds` | **30.0.0** | v0.92.0 |
| `kube-prometheus-stack`    | **87.2.1** | v0.92.0 (operator) |

The CRDs chart's appVersion **must** match the operator the stack bundles — both `v0.92.0` here. Bump
them together: change `Chart.yaml`, `helm dependency build`, commit the refreshed `Chart.lock`.

## Layout & waves

The `NN` prefix **is** the sync-wave ([05_gitops.md](05_gitops.md)).

| Wave | App / change | Why here |
|------|--------------|----------|
| `0`  | `00_prometheus_operator_crds` | **Foundational** — CRDs must exist before *any* consumer. The per-component ServiceMonitors we enable sit at waves 0–2; on a cold boot those waves can't go Healthy until the `ServiceMonitor` CRD exists. Mirrors `01_envoy_gateway` owning the Gateway API CRDs early. CRDs with no controller are inert. |
| `2`  | `02_longhorn` (edit) | `nodeDownPodDeletionPolicy` + replica-3 (already set). |
| `0–2`| `00_cilium`, `01_argocd`, `02_cert_manager`, `02_longhorn`, `02_sealed_secrets` (edits) | native ServiceMonitor toggles, co-located with each app. |
| `3`  | `03_gateway` (edit) | `prometheus` + `alertmanager` `httpsHosts` listeners. |
| `7`  | `07_kube_prometheus_stack` | after Longhorn + cert-manager (wave 2 — PVCs + the webhook issuer); CRDs already present from wave 0. |
| `7`  | `07_monitoring_ingress` | per-host `Certificate` + `sso`-labelled `HTTPRoute` + `ReferenceGrant`; after gateway (3) + SSO (4). Same wave as the stack it fronts. |

## Decisions

### CRDs split out, at wave 0
The stack runs `crds.enabled: false`; the CRDs are their own app. Two reasons: CRDs upgrade
independently of the release (Helm never upgrades chart-bundled CRDs), and the operator CRDs are huge
(`ServerSideApply=true`, `prune: false` so a removed CRD never cascade-deletes its CRs). Wave **0**, not
later, because the component ServiceMonitors at waves 0–2 consume them — a later CRD wave would deadlock
a from-scratch bootstrap. On a cold boot the wave-0 cilium ServiceMonitor may retry a few times until
the CRDs register, then converges.

### Grafana off, but its ConfigMaps shipped
`grafana.enabled: false` (a standalone Grafana lands later as its own app — see below), but
`forceDeployDashboards: true` + `forceDeployDatasources: true` so the stack still emits the curated k8s
dashboard ConfigMaps (`grafana_dashboard: "1"`) and the Prometheus datasource ConfigMap
(`grafana_datasource: "1"`). The future Grafana's sidecar ingests them with zero rework.

### Storage — Longhorn, global class, replica 3
Prometheus 50Gi, Alertmanager 1Gi, both on the default `longhorn` class — **no per-app StorageClass**.
`02_longhorn` already sets replica 3 globally (`persistence.defaultClassReplicaCount: 3`,
`defaultSettings.defaultReplicaCount: 3`). With replica 3 on 3 nodes **every node holds a replica**, so
a rescheduled pod always lands next to a local one — no data-locality tuning needed. The class is
`allowVolumeExpansion: true` (Longhorn default) so the PVC can grow later.

The Prometheus PVC comes from the StatefulSet `volumeClaimTemplate`, which is **not** ArgoCD-managed —
it survives app sync/delete, so metrics persist across normal GitOps ops. **Manually** deleting the PVC
destroys the data. Reclaim policy is the class default `Delete`.

### Retention — 120d OR 40GiB, whichever first
`retention: 120d`, `retentionSize: "40GiB"` (≈80% of the 50Gi PVC), `walCompression: true`. The size cap
is the guardrail against a full-PVC crashloop; whichever limit hits first wins.

**Sizing math (do this, don't guess).** The original "180d in 20Gi" assumed ~30k series — but the real
cardinality is ~160k (kube-apiserver/etcd/cAdvisor/kube-state histograms dominate). At ~3.5k samples/s
that's ~0.55 GiB/day, so 16GiB would have capped at **~30 days**, not 180. After the apiserver/etcd
histogram drops (see Cardinality) it's ~90k series ≈ ~0.3 GiB/day, so **40GiB ≈ ~120 days** — hence
`120d` + `40GiB` + `50Gi`. Check your real rate any time:
`rate(prometheus_tsdb_head_samples_appended_total[1h])` × ~2 bytes × 86400 = bytes/day; divide
`retentionSize` by that for days-to-cap. To go longer, cut cardinality further or raise `retentionSize`
+ `storage` together (the Longhorn volume fills the NVMe, so disk isn't the constraint — see
`03d` `minSize`).

### 60s intervals, external label
`scrapeInterval`/`evaluationInterval: 60s` halves sample volume vs 30s for negligible loss at homelab
cardinality. `externalLabels.cluster: raspi-cluster` tags every series (rename if you adopt another
cluster identifier).

### Discover monitors everywhere
All five `*SelectorNilUsesHelmValues` flags are `false`, so Prometheus scrapes ServiceMonitors /
PodMonitors / Rules / Probes / ScrapeConfigs from **any** namespace regardless of labels — which is why
the per-component toggles below "just work" wherever they live.

### Admission webhook on, cert via cert-manager
`admissionWebhooks.certManager.enabled: true` validates PromQL rule syntax in `PrometheusRule` CRs. Its
cert is minted by cert-manager (wave 2) via the operator's **own** self-signed issuer — no dependency on
the ACME ClusterIssuers. cert-manager injects the `caBundle` at runtime, so the stack Application
`ignoreDifferences` it on **both** the Validating and Mutating `...-admission` webhooks (jq path
`.webhooks[].clientConfig.caBundle`) to avoid perpetual OutOfSync. (Alternative: `admissionWebhooks.
enabled: false` for less friction at the cost of rule-syntax validation.)

### kube-proxy ServiceMonitor off
`kubeProxy.enabled: false` — Cilium replaces kube-proxy (`kubeProxyReplacement: true`), so that default
target is dead.

### Resources
Sized for 8GB Pi 5s already running etcd + control plane + Cilium + Longhorn. No CPU limit on Prometheus
(avoid throttling compaction/scrape); memory limits bound the blast radius. Adjust if RAM gets tight.

## Control-plane scrape (Talos machine config — OUTSIDE ArgoCD)

Talos binds kube-controller-manager / kube-scheduler / etcd metrics to **localhost** by default, so
those targets are dead until exposed. We keep their ServiceMonitors **enabled** (`endpoints` = the
control-plane node IPs `192.168.10.201-203`, static/reserved — mirrors
[lib/config.sh](lib/config.sh) `CLUSTER_NODES`; all-control-plane cluster, so every
node runs all three) and expose the metrics with a Talos machine-config patch:

```yaml
# controlplane patch (talosctl — NOT ArgoCD). Fold into step 03's cp-patch or apply directly.
cluster:
  controllerManager:
    extraArgs: { bind-address: 0.0.0.0 }    # metrics on :10257 (https)
  scheduler:
    extraArgs: { bind-address: 0.0.0.0 }    # metrics on :10259 (https)
  etcd:
    extraArgs: { listen-metrics-urls: "http://0.0.0.0:2381" }   # metrics on :2381 (http, no auth)
```

```bash
talosctl patch mc -p @cp-metrics.yaml --nodes 192.168.10.201,192.168.10.202,192.168.10.203
```

kcm/scheduler serve **https with a self-signed cert** on the metrics port → the ServiceMonitors use
`https: true` + `insecureSkipVerify: true`; auth is the Prometheus SA bearer token (its ClusterRole
grants `nonResourceURLs: ["/metrics"]`). etcd is plain http on 2381. **Until the patch is applied these
three targets are DOWN** — apply it, or set `enabled: false` on those three in the stack values, so
there are no permanently-down targets.

## Failover

Single replica each. On node loss the pod reschedules to **any** node; Longhorn re-attaches from a
surviving replica (with replica 3, every node has one locally). Metrics are durable — you lose only the
scrape window during reschedule.

- The 30s `unreachable`/`not-ready` tolerations (stack values) + Longhorn
  `nodeDownPodDeletionPolicy: delete-statefulset-pod` ([02_longhorn](argo_apps/platform/charts/02_longhorn/values.yaml))
  give **~1–2 min** recovery + a matching graph gap, then WAL replay (seconds at this cardinality).
- **Without** those two settings it's ~5–6 min on a hard node failure. The NICs here are flaky
  ([06_nic_keeper.md](06_nic_keeper.md)), so node loss is a real recurring case — **verify the Longhorn
  policy is applied**: `kubectl -n longhorn-system get settings.longhorn.io node-down-pod-deletion-policy`.

## Alertmanager email (reusable bootstrap)

The alert destination is a **runtime choice**, kept out of git. `15_monitoring/15_alertmanager_secret.sh`
([lib/config.sh](lib/config.sh) holds the non-secret knobs):

```bash
KUBECONFIG=03_operating_system/talos-cluster/kubeconfig ./15_monitoring/15_alertmanager_secret.sh
```

- **With creds** (Gmail address + app-password): seals the password into
  `argo_apps/charts/07_kube_prometheus_stack/templates/alertmanager-smtp-sealedsecret.yaml` (strict
  scope, ns `monitoring`, key `password`) and `yq`-writes the **email** receiver into the stack
  `values.yaml` (`alertmanagerSpec.secrets: [alertmanager-smtp]` + an `email_configs` receiver reading
  `/etc/alertmanager/secrets/alertmanager-smtp/password`, `repeat_interval: 4h`).
- **Without creds**: typed-confirm, **deletes** the sealed file, writes the **null** receiver (alerting
  has no destination). Idempotent — re-run to rotate, change recipient, or disable.

Then `git commit && push`; ArgoCD (wave 7) applies the config and the controller
([07_sealed_secrets.md](07_sealed_secrets.md)) unseals the password into Secret `alertmanager-smtp`.

> **Gmail App Password**: a 16-char password (needs 2-Step Verification; the Security-menu entry is
> hidden — use the direct link <https://myaccount.google.com/apppasswords>). It is **revoked when the
> Google account password changes**. Not your account password.

Test end-to-end after sync:
```bash
kubectl -n monitoring exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert add testalert --alertmanager.url=http://localhost:9093   # expect an email within ~30s
```

## ServiceMonitors per component

Each toggle is flipped in **that app's own** chart (co-located, separate commit), never centralized.
Discovered cluster-wide via the selector-nil flags above.

| App | Keys set | Notes |
|-----|----------|-------|
| `00_cilium` | `prometheus.{enabled,serviceMonitor.enabled}`, `operator.prometheus.{enabled,serviceMonitor.enabled}`, `hubble.metrics.{enabled,serviceMonitor.enabled}` | Hubble metrics a lean set (`dns,drop,tcp,flow,icmp,port-distribution`) to bound cardinality; add `httpV2` if wanted. |
| `01_argocd` | `{controller,server,repoServer,applicationSet}.metrics.{enabled,serviceMonitor.enabled}` | notifications stays disabled. |
| `02_cert_manager` | `prometheus.enabled` + `prometheus.servicemonitor.enabled` | note the lowercase `servicemonitor`. |
| `02_longhorn` | `metrics.serviceMonitor.enabled` | Longhorn Manager metrics. |
| `02_sealed_secrets` | `metrics.serviceMonitor.enabled` | seal/unseal + key-age. |

The chart ServiceMonitor templates are guarded on the CRD being present (`.Capabilities.APIVersions`),
so they only render once the wave-0 CRDs exist — which is exactly the ordering we built. **Future
operators** (CNPG, RabbitMQ, Redis) all ship native ServiceMonitor support — enable it when they land.

## Cardinality management

The fixed-PVC design only holds if cardinality stays low. Workflow:

- **Inspect**: Prometheus UI `Status → TSDB Status`; `prometheus_tsdb_head_series`;
  `topk(20, count by (__name__)({__name__=~".+"}))`.
- **Drop at source**: add `metricRelabelings` with `action: drop` on the offending ServiceMonitor /
  PodMonitor (declarative, co-located with its app).
- **Already dropped** (the top offenders, ~70k series): the kube-apiserver request/response/watch/
  flowcontrol/admission `*_bucket` histograms (`kubeApiServer.serviceMonitor.metricRelabelings`) and
  etcd's `etcd_request_duration_seconds_bucket` + `grpc_server_*_total`
  (`kubeEtcd.serviceMonitor.metricRelabelings`). We keep `apiserver_request_total` (request + error
  rates). Because those buckets are gone, the apiserver SLO/burn-rate/histogram rule groups + the etcd
  rules are disabled (`defaultRules.rules.kubeApiserver{Slos,Burnrate,Histogram}: false`, `etcd: false`)
  so they don't evaluate empty; `kubeApiserverAvailability` stays. Next candidates if you need more:
  cAdvisor per-container/per-interface series, verbose `kube-state-metrics`, `workqueue_*_bucket`.
- `retentionSize: 40GiB` trims the window below 120d if cardinality trips the cap first — intended.
  Re-evaluate PVC size / retention (or add a PVC autoscaler) if it trips.

> **Optional PVC autoscaling** (documented, not enabled): native k8s doesn't autoscale PVCs. A
> volume-autoscaler add-on watching PVC usage + `retentionSize` near the max gives "start small, grow to
> 50Gi". Trade-off: an extra component and a lag risk (if the disk fills faster than it expands,
> Prometheus crashloops). Viable at this fill rate, but fixed 50Gi + 40GiB cap is simpler and bounded.

## Public exposure

Reuses the shared Gateway ([10_gateway.md](10_gateway.md)) exactly like the ArgoCD UI
([14_argocd_ingress.md](14_argocd_ingress.md)) — per-host HTTP-01 cert (no wildcard), gated by the
label-driven Google SSO ([12_google_sso.md](12_google_sso.md)).

- **Listeners** — `prometheus` + `alertmanager` entries in `03_gateway`'s `httpsHosts`
  (`prometheus.example.com` / `alertmanager.example.com`).
- **`07_monitoring_ingress`** — per host a `Certificate` (gateway ns, `letsencrypt-staging` → flip to
  `letsencrypt-prod` once it issues) + an `sso: example.com`-labelled `HTTPRoute` (gateway ns,
  `sectionName == httpsHosts name`, cross-ns backendRef to the monitoring Service) + one
  `ReferenceGrant` in `monitoring` covering both Services
  (`kube-prometheus-stack-prometheus:9090`, `kube-prometheus-stack-alertmanager:9093`).
- **Auth** — the `sso: example.com` label is the *entire* auth story; the existing example.com
  `SecurityPolicy` attaches Google login + the allowlist. Unlike ArgoCD (which has its own inner login),
  these UIs have **no** login of their own, so the SSO gate is the **only** barrier — never serve them
  unlabelled. `prometheus.`/`alertmanager.example.com` are example.com subdomains, so the existing
  policy/callback/cookie already cover them — no new Google redirect URI.
- **DNS** — both hosts resolve to the Gateway IP via the old-Pi `*.example.com` `:80`/`:443` forward.
- **Break-glass** — `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090`
  bypasses the Gateway + SSO.

## Grafana

Grafana now lands as its own wave-7 app — see **[16_grafana.md](16_grafana.md)**. Standalone
`grafana/grafana` chart, the sidecar ingests the datasource/dashboard ConfigMaps this stack emits
(`grafana_datasource: "1"` / `grafana_dashboard: "1"`, search-all-namespaces). No persistence; Grafana's
own login is **off** (anonymous Admin) and the only gate is the Google SSO front door — the `grafana.example.com`
host's cert + `sso`-labelled HTTPRoute and its **own** `grafana` Gateway (a single `:443` listener, folded
onto the one Envoy via `mergeGateways`) now ship **inside the `07_grafana` chart itself** (`ingress:` block +
`templates/edge-*.yaml`), same as the vmui/vlogs UIs do in their stacks.

## Apply / verify

1. (Optional but recommended) apply the Talos CP-metrics patch (above) so control-plane targets come up.
2. Run `15_monitoring/15_alertmanager_secret.sh` (or skip for a null receiver).
3. Add A-records `prometheus.`/`alertmanager.example.com` → router (the `*.example.com` forward covers
   `:80`/`:443`).
4. `git add -A && git commit && git push`. ArgoCD rolls the waves: CRDs (0) → component monitors (0–2) →
   gateway listeners (3) → stack + ingress (7).
5. Once the certs issue on staging, flip `issuer` to `letsencrypt-prod` in `07_monitoring_ingress` values.

Checks:

- `kubectl get crd | grep monitoring.coreos.com` present **before** the stack syncs; the CRDs app shows
  no apply-size errors.
- `kubectl -n monitoring get prometheus,alertmanager,statefulset,pvc` → Prometheus `1/1`, PVC bound on
  `longhorn` at 50Gi (`kubectl -n longhorn-system get volume` shows 3 replicas).
- node-exporter DaemonSet on **all 3** nodes; kube-proxy target absent.
- Prometheus UI `Status → Targets`: kubelet/cAdvisor, kube-state-metrics, node-exporter up; cilium/hubble,
  argocd, cert-manager, longhorn, sealed-secrets up; control-plane jobs up (after the Talos patch) or
  intentionally disabled — **no permanently-down targets**.
- `kubectl get configmap -A -l grafana_dashboard=1` and `-l grafana_datasource=1` exist (bundled Grafana
  off).
- stack Application `Synced` + `Healthy`, not OutOfSync on the webhook caBundle.
- `kubectl -n gateway get certificate prometheus alertmanager` → `READY=True` (staging, then prod).
- `kubectl -n monitoring get referencegrant`; `kubectl -n gateway get httproute prometheus alertmanager`
  → `Accepted`/`ResolvedRefs=True`; both hosts serve HTTPS and present the **Google SSO login** before
  the UI (same gate as the ArgoCD UI).

## Caveats

- **Control-plane targets need the Talos patch** (outside ArgoCD) or they're down — apply it or disable
  those three ServiceMonitors.
- **No secrets in git** — the SMTP app-password only ever exists as a SealedSecret from the bootstrap
  script; the values file holds a file-path reference, never the secret.
- **Staging cert = browser warning** until you flip `issuer` to prod.
- **Manual PVC delete destroys metrics** — the volumeClaimTemplate PVC is not ArgoCD-managed by design.
- **Pin every chart** — no floating `targetRevision`; bump CRDs + stack together (matched operator
  version).
