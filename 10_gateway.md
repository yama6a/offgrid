# 10 — Ingress Gateway + Let's Encrypt ClusterIssuers

Stand up the cluster's **single ingress point** — the shared Gateway on a pinned LoadBalancer IP — and
the **cert-issuance wiring** (Let's Encrypt ClusterIssuers that solve HTTP-01 *through* that Gateway).
The Gateway runs on the **Envoy Gateway `eg` class** (the data plane + class come from the
`01_envoy_gateway` app — see [11_envoy_gateway.md](11_envoy_gateway.md)).

This chart is the ingress **platform only — it owns no apps**. It declares the Gateway, the list of
HTTPS hostnames the Gateway terminates TLS for (one `:443` listener each), and the ClusterIssuers. Each
app brings its own `Certificate` + `HTTPRoute` (+ workload) in a later wave: the demo apps in
[`gateway-test`](13_gateway_test.md), the SSO callback hosts in [`04_google_sso`](12_google_sso.md),
real apps in their own charts.

Delivered purely by ArgoCD:

- `argo_apps/platform/apps/03_gateway.yaml` — the Application, **sync-wave 3**.
- `argo_apps/platform/charts/03_gateway/` — the wrapper chart (Gateway + `httpsHosts` listeners + ClusterIssuers).
- plus a one-line enablement (`enableGatewayAPI: true`) in `argo_apps/platform/charts/02_cert_manager/values.yaml`.

And one bootstrap helper (no cluster apply — values propagation only):

- `10_gateway/config.sh` — knobs `LE_EMAIL` + `BASE_DOMAIN` (env-overridable).
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

### One shared Gateway, pinned IP
A single `Gateway` (`shared-gateway`, namespace `gateway`) is the cluster's lone ingress. Apps attach
`HTTPRoute`s to it cross-namespace (`listener.allowedRoutes.namespaces.from: All`). Envoy Gateway
materialises it as a data-plane Envoy Deployment + `LoadBalancer` Service, pinned to **`192.168.100.10`**
(the start of the Cilium LB-IPAM pool from `04_networking/config.sh`) via the EnvoyProxy
`lbipam.cilium.io/ips` annotation **and** the Gateway's `spec.addresses` — both honoured by Cilium
LB-IPAM. This is the fixed IP the old Pi forwards to; keep it stable. (Pinning mechanism lives in the
`01_envoy_gateway` chart — see [11_envoy_gateway.md](11_envoy_gateway.md).)

### Listeners: always-on `:80`, one `:443` per host
The `:80` HTTP listener needs no cert and serves both pre-HTTPS jobs: cert-manager's HTTP-01 solver
routes attach here, and the future forced http→https redirect is a `RequestRedirect` HTTPRoute on this
same listener. Then **one HTTPS `:443` listener per entry in `.Values.httpsHosts`** — a flat list of
`{name, hostname, tlsSecretName}`. Each terminates TLS for a hostname using a cert Secret an app fills
via HTTP-01, so a listener sits **not-Ready until that cert is issued** (needs the host to resolve + the
old Pi to forward `:80`). One Gateway + HTTP-01 means **a listener per host** — there is no wildcard
listener without DNS-01, which we don't have.

### The Gateway owns no apps — only listeners
The listener can only live on the one Gateway resource, so `httpsHosts` enumerates every hostname
(demo, SSO callbacks, real apps). But the *app* — its `Certificate` + `HTTPRoute` + workload — lives in
the app's own chart/wave. Coordination across charts (the price of one Gateway + per-host HTTP-01): an
app's `HTTPRoute.parentRefs.sectionName` must equal the `httpsHosts` entry's `name`, its `hostname` must
equal `hostname`, and its `Certificate.secretName` must equal `tlsSecretName`. The demo apps live in
[`gateway-test`](13_gateway_test.md); the `google-sso.<domain>` callback hosts in
[`04_google_sso`](12_google_sso.md).

### Email + base domain are config.sh-driven
Per [CLAUDE.md](CLAUDE.md), no values are hardcoded in scripts. `10_gateway/config.sh` holds `LE_EMAIL`
and `BASE_DOMAIN`; `10_gateway.sh` writes them into the chart's `values.yaml` (`acme.email`,
`baseDomain`) with `yq`. `baseDomain` is now informational (the cluster serves more than one domain, so
hostnames are spelled out explicitly in `httpsHosts` and per-app values). Commit the rewritten
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

1. Set knobs and propagate: edit `10_gateway/config.sh` (or env-override), run `./10_gateway/10_gateway.sh`,
   commit the rewritten `values.yaml`. ArgoCD (wave 3) applies the Gateway + ClusterIssuers.
2. Per host (demo, SSO, real app): point the hostname's public DNS at the home router and forward `:80`
   for it to the Gateway IP on the old Pi (`allowACMEByPass=true` + a `Host(...)` HTTP router) so
   cert-manager's HTTP-01 challenge can reach the cluster. Until then that host's `Certificate` + its
   `:443` listener stay not-Ready — expected, and it blocks nothing.

Checks:

- `kubectl -n gateway get gateway shared-gateway` → `PROGRAMMED=True`, address `192.168.100.10`.
- `kubectl get svc -n gateway` → the Envoy Gateway `LoadBalancer` Service has EXTERNAL-IP `192.168.100.10`.
- `kubectl get clusterissuer` → both `letsencrypt-staging` / `letsencrypt-prod` show `READY=True`.
- listeners show `Ready` only once their app's cert is issued (per-host) — not-Ready before that is
  expected, not an error.

## Next step

Apps attach here. The demo echo apps are [13_gateway_test.md](13_gateway_test.md); optional Google SSO is
[12_google_sso.md](12_google_sso.md). Per real app/host: add a `httpsHosts` entry (the listener), and
ship its `Certificate` + `HTTPRoute` (+ workload) in its own chart. The forced http→https redirect is
still deferred — a `RequestRedirect` HTTPRoute on the `:80` listener.
