# 16 — Grafana

Standalone **Grafana**, the dashboards/Explore UI for the monitoring core ([15_monitoring.md](15_monitoring.md)).
The kube-prometheus-stack's bundled Grafana was left **off**, but the stack still emits its curated
dashboard + datasource ConfigMaps — so Grafana lands here as its own app and the sidecar picks them up
with zero rework. Grafana's **own login is disabled** (anonymous Admin); the only barrier is **Google
SSO at the shared Gateway**, the same front door as the Prometheus/Alertmanager UIs. **No persistence.**

```
kube-prometheus-stack ConfigMaps          ┌──────────────────────────┐
  grafana_datasource=1  (Prometheus URL)  │  Grafana (1×, no PVC)     │   shared Gateway + Google SSO
  grafana_dashboard=1   (curated boards) ─┼─► sidecar (all-namespace) │◄── grafana.example.com
                                          │  auth OFF → anon Admin     │     (sso: example.com)
                                          └──────────────────────────┘
```

## Decisions

### Standalone chart, not the stack's subchart
Same `grafana/grafana` chart, run on its own (release `grafana`, namespace `monitoring`) — no feature
loss vs. the bundled subchart, but it versions, syncs and rolls back independently of the stack. Thin
wrapper-chart pattern as everywhere else: version pinned in `Chart.yaml` (`grafana/grafana` **10.5.15**,
appVersion **12.3.1**), all config in `values.yaml` under the `grafana:` key, `Chart.lock` committed.
The chart ships **no CRDs**, so — unlike the prometheus-operator — there's nothing to hoist into the
wave-0 CRDs app.

### Datasource + dashboards from the sidecar
`sidecar.datasources` + `sidecar.dashboards` enabled with `searchNamespace: ALL`, matching the stack's
default labels (`grafana_datasource` / `grafana_dashboard`). The stack already emits the Prometheus
datasource (pointing at `http://kube-prometheus-stack-prometheus.monitoring.svc:9090`) and its curated
dashboards, so **nothing is hardcoded here** — the sidecar provisions them on every start.

### No persistence (`persistence.enabled: false`)
Explicit requirement. Safe because Grafana holds no state worth keeping: the datasource and curated
dashboards are re-provisioned from ConfigMaps each start. **Trade-off:** dashboards or settings a user
creates *in the UI* are lost on pod restart. If that ever matters, add a small `longhorn` PVC — but
that's deliberately not done.

### Auth off → Google SSO is the only gate
`auth.anonymous.enabled: true` with `org_role: Admin`, `disable_login_form: true`, `auth.basic` off.
Every request reaches Grafana already authenticated at the edge by the Gateway's Google SSO (the
`sso: example.com` HTTPRoute + the `04_google_sso` SecurityPolicy = Google login + the email allowlist),
so there's no second login and the user lands straight in the UI. **Anonymous Admin** means everyone on
the SSO allowlist gets full Grafana admin (edit/delete dashboards, add datasources) — acceptable for a
small, trusted allowlist; the gateway allowlist is the real boundary. Identical posture to the
Prometheus/Alertmanager UIs, which also have no login of their own.

### Exposure reuses 07_monitoring_ingress
Grafana is just one more host on the existing monitoring edge: a `grafana` entry in
`07_monitoring_ingress/values.yaml` renders the Certificate (HTTP-01), the `sso`-labelled HTTPRoute, and
extends the cross-namespace ReferenceGrant to the `grafana` Service — no template changes. The matching
`:443` listener is the `grafana` entry added to `03_gateway`'s `httpsHosts`. `letsencrypt-staging` until
the cert issues, then flip the shared `issuer` in `07_monitoring_ingress` to `letsencrypt-prod`.

### sync-wave 7
Same wave as the stack it reads ConfigMaps from (`07_kube_prometheus_stack`) and its own edge route
(`07_monitoring_ingress`). The sidecar is a continuous watcher, so no hard "after the stack" ordering is
needed; co-locating at wave 7 also lets the monitoring-ingress HTTPRoute's `backendRef` resolve the
instant the `grafana` Service appears, instead of sitting `ResolvedRefs:False` across a wave boundary.
The `NN` prefix == the wave, so the app/chart are `07_grafana` (a third wave-7 app).

## Apply / verify

1. Ensure a `grafana.example.com` A-record points at the router (the `*.example.com` forward already
   covers `:80`/`:443` to the Gateway IP).
2. `git add -A && git commit && git push`. ArgoCD syncs the new listener, cert, route and Grafana pod.
3. `kubectl -n argocd get applications` → `grafana` **Synced + Healthy**.
4. `kubectl -n monitoring get deploy,pod -l app.kubernetes.io/name=grafana` → Running;
   `kubectl -n monitoring get pvc` → none for grafana.
5. `kubectl -n gateway get certificate grafana` → `READY=True`; `kubectl -n gateway get httproute grafana`
   → `Accepted` / `ResolvedRefs=True` (briefly False until the pod is up — self-clears).
6. Browse `https://grafana.example.com` → **Google SSO login** first (allowlist enforced); after login,
   Grafana opens straight into the UI with **no Grafana login** (anonymous Admin). Connections → Data
   sources shows Prometheus; the stack's curated dashboards are listed.
7. Once the staging cert issues, flip `07_monitoring_ingress` `issuer` to `letsencrypt-prod`, push, and
   re-verify the cert is trusted.

## Caveats
- **No persistence is intentional** — see the decision above; UI-created content does not survive a
  restart.
- **Anonymous Admin** — every SSO-allowlisted user is a full Grafana admin. Lock down with a `Viewer`
  default role (`auth.anonymous.org_role`) if that's ever too broad.
