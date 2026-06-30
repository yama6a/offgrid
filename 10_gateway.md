# 10 — Ingress Gateway + Let's Encrypt ClusterIssuers

Stand up the cluster's **single ingress point** — the shared Gateway on a pinned LoadBalancer IP — and
the **cert-issuance wiring** (Let's Encrypt ClusterIssuers that solve HTTP-01 *through* that Gateway).
The Gateway runs on the **Envoy Gateway `eg` class** (the data plane + class come from the
`01_envoy_gateway` app — see [11_envoy_gateway.md](11_envoy_gateway.md)).

This chart is the ACME ingress **platform only — it owns no apps and no `:443` listeners**. It declares
the `shared-gateway` reduced to its **`:80` HTTP listener** (the cert-issuance entry point) and the
ClusterIssuers. Each app now ships its **own Gateway** (a single `:443` listener) **plus** its
`Certificate` + `HTTPRoute` (+ workload) in a later wave: the sample workload in
[`sample-workload`](13_sample_workload.md), the SSO callback hosts in [`04_google_sso`](12_google_sso.md),
argocd in [`06_argocd_ingress`](14_argocd_ingress.md), the monitoring UIs each in their own stack chart
(`07_grafana`, `07_victoria_logs`, `07_victoria_metrics_k8s_stack`), real apps in their own charts. Every
one of those Gateways is folded onto **one** Envoy + LoadBalancer
via Envoy Gateway's `mergeGateways` (see [11_envoy_gateway.md](11_envoy_gateway.md)), so the cluster
still has a **single ingress point on the pinned IP** — but the platform Gateway no longer depends on any
app's cert.

Delivered purely by ArgoCD:

- `argo_apps/platform/apps/03_gateway.yaml` — the Application, **sync-wave 3**.
- `argo_apps/platform/charts/03_gateway/` — the wrapper chart (the `:80` Gateway + ClusterIssuers).
- plus a one-line enablement (`enableGatewayAPI: true`) in `argo_apps/platform/charts/02_cert_manager/values.yaml`.

And one bootstrap helper (no cluster apply — values propagation only):

- `.env` — knobs `LE_EMAIL` + `BASE_DOMAIN`.
- `10_gateway/10_gateway.sh` — writes those into the chart's `values.yaml` (`acme.email` + `baseDomain`)
  via `yq`, so the shell side and ArgoCD render the same. Non-interactive.

## Why this exists / the migration context

The old single Raspberry Pi still receives all `:80`/`:443` from the home router and runs Traefik. We
migrate one hostname at a time to this cluster. For a migrated host the old Pi's Traefik becomes a dumb
forwarder to this Gateway's IP:

- `:443` → **TCP/SNI passthrough** (`HostSNI` + `tls.passthrough`) to the Gateway: the **cluster**
  terminates TLS and owns the cert. The eventual final cutover (repoint the router straight at the
  Gateway IP) is then a no-op on the cluster.
- `:80` → **L7 HTTP forward** (per-host `Host(...)` router) to the Gateway: plaintext has no SNI, so
  port 80 can't be routed per-host at L4. This forward carries the ACME **HTTP-01** challenge into the
  cluster so cert-manager can mint that host's cert, and (later) lets the cluster issue the forced
  http→https redirect.

Two landmines on the old Pi when forwarding `:80`:

1. Traefik's **internal ACME router has top priority** and would swallow `/.well-known/acme-challenge/`
   before any forward fires — set `--entrypoints.http.allowACMEByPass=true` on the old Pi.
2. Once a host's `:80` forwards here, the old Pi can no longer satisfy HTTP-01 for it — **remove that
   host from the old Pi's cert SANs list** so its monolithic cert keeps renewing.

## Decisions

### One Envoy + one pinned IP, many Gateways (mergeGateways)
The cluster has **one ingress point** — a single data-plane Envoy + `LoadBalancer` Service pinned to
**`192.168.100.10`** (the start of the Cilium LB-IPAM pool from `.env`) — but it is
fed by **many Gateways**, not one. Envoy Gateway's `mergeGateways: true` (on the `eg` class's EnvoyProxy)
collapses every `eg` Gateway onto that single Envoy/Service. The IP is pinned **solely** by the EnvoyProxy
`lbipam.cilium.io/ips` annotation now — per-Gateway `spec.addresses` is dropped (it would conflict on the
one shared Service under merge). This is the fixed IP the old Pi forwards to; keep it stable. (The merge
flag + pinning live in the `01_envoy_gateway` chart — see [11_envoy_gateway.md](11_envoy_gateway.md).)

### This chart's Gateway: the `:80` ACME listener only
`shared-gateway` now owns just the `:80` HTTP listener — no cert, no `:443`. It serves both pre-HTTPS
jobs: cert-manager's HTTP-01 solver routes attach here (the ClusterIssuers point at `shared-gateway` by
name), and the future forced http→https redirect is a `RequestRedirect` HTTPRoute on this same listener.
With no cert refs it is **Programmed immediately**, independent of any app — the platform Gateway is no
longer held back by app issuance. (One Gateway + HTTP-01 still means a `:443` listener per host overall —
there's no wildcard without DNS-01, which we don't have — but those `:443` listeners now live on the
per-app Gateways below, not here.)

### Apps own their Gateway + listener + cert + route
Each HTTPS host is now self-contained in its app's chart: its **own `Gateway`** with a single `:443`
listener, its `Certificate`, and its `HTTPRoute` (parentRef → its own Gateway). All in the `gateway`
namespace (so the SSO `SecurityPolicy` label-selection and the ReferenceGrants are unchanged), all merged
onto the one Envoy. Adding a host is now a **one-place edit** in the app's chart — no `httpsHosts` entry
to keep in step here. That host's `:443` listener sits **not-Ready until its cert is issued** (needs the
host to resolve + the old Pi to forward `:80`), but under merge listeners are independent — one app's
missing cert never blocks another, nor the platform. The sample workload lives in
[`sample-workload`](13_sample_workload.md); the `google-sso.<domain>` callback hosts in
[`04_google_sso`](12_google_sso.md); argocd in [`06_argocd_ingress`](14_argocd_ingress.md); the
monitoring UIs each in their own stack chart (`07_grafana`, `07_victoria_logs`, `07_victoria_metrics_k8s_stack`).

### Email + base domain are .env-driven
Per [CLAUDE.md](CLAUDE.md), no values are hardcoded in scripts. `.env` holds `LE_EMAIL`
and `BASE_DOMAIN`; `10_gateway.sh` writes them into the chart's `values.yaml` (`acme.email`,
`baseDomain`) with `yq`. `baseDomain` is now informational (the cluster serves more than one domain, so
hostnames are spelled out explicitly in each app's per-app values). Commit the rewritten
`values.yaml` so ArgoCD renders the same.

### Staging + prod ClusterIssuers
Both `letsencrypt-staging` and `letsencrypt-prod` are shipped (cluster-scoped). Always validate a new
host against **staging** first — prod's rate limits are tight — then flip that host's `Certificate`
issuer to prod. The HTTP-01 solver is `gatewayHTTPRoute` with `parentRefs` to the shared Gateway.

### Enabling Gateway API in cert-manager (the corrected way)
HTTP-01-via-Gateway requires cert-manager to manage `HTTPRoute`s. Since **cert-manager 1.15 this is no
longer the `ExperimentalGatewayAPISupport` feature gate** (that gate is gone) — it's enabled with the
controller file config `config.enableGatewayAPI: true` (set under the `cert-manager:` key in
`02_cert_manager/values.yaml`). The Gateway API CRDs must exist before the controller starts; they do,
because Envoy Gateway installs them at wave 1, before the wave-2 cert-manager. If you ever install the
CRDs *after* cert-manager, restart its Deployment.

## Sync-wave: 3

The ClusterIssuers need cert-manager's CRDs **and** a controller with Gateway API enabled (wave 2); the
Gateway needs the `eg` GatewayClass (wave 1). Wave 3 is the lowest wave after both. Auto-synced (prune +
selfHeal) — a safe leaf: pruning drops ingress but, unlike the CNI, can't cut the cluster off its own
network. It owns no CRDs, so a prune never cascade-deletes one.

## Apply / verify

1. Set knobs and propagate: edit `.env`, run `./10_gateway/10_gateway.sh`,
   commit the rewritten `values.yaml`. ArgoCD (wave 3) applies the Gateway + ClusterIssuers.
2. Per host (demo, SSO, real app): point the hostname's public DNS at the home router and forward `:80`
   for it to the Gateway IP on the old Pi (`allowACMEByPass=true` + a `Host(...)` HTTP router) so
   cert-manager's HTTP-01 challenge can reach the cluster. Until then that host's `Certificate` + its
   own Gateway's `:443` listener stay not-Ready — expected, and it blocks nothing.

Checks:

- `kubectl -n gateway get gateway` → `shared-gateway` `PROGRAMMED=True` immediately, plus one per-app
  Gateway per host (argocd, vmui, vlogs, grafana, google-sso-*, sample-workload*) — all with address
  `192.168.100.10` (merge gives every Gateway the shared Service's IP).
- `kubectl get svc -n envoy-gateway-system` → **one** Envoy `LoadBalancer` Service (`envoy-eg-<hash>`)
  with EXTERNAL-IP `192.168.100.10` (mergeGateways → a single shared data plane).
- `kubectl get clusterissuer` → both `letsencrypt-staging` / `letsencrypt-prod` show `READY=True`.
- A per-app Gateway's `:443` listener shows `Ready` only once its cert is issued — not-Ready before that
  is expected, not an error, and isolated to that Gateway.

## Next step

Apps attach by merging their own Gateway onto this one's Envoy. The sample workload is
[13_sample_workload.md](13_sample_workload.md); optional Google SSO is [12_google_sso.md](12_google_sso.md).
Per real app/host: ship its **own `Gateway`** (one `:443` listener) **plus** its `Certificate` +
`HTTPRoute` (+ workload) in its own chart — one place, no edit here. The forced http→https redirect is
still deferred — a `RequestRedirect` HTTPRoute on this chart's `:80` listener.
