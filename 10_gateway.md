# 10 — Ingress Gateway + Let's Encrypt ClusterIssuers

Stand up the cluster's **single ingress point** (a Cilium Gateway on a pinned LoadBalancer IP) and
the **cert-issuance wiring** (Let's Encrypt ClusterIssuers that solve HTTP-01 *through* that Gateway).
After this step the cluster is *ready* to terminate HTTPS — but deliberately does not yet: no HTTPS
listener, no Certificates, no app routes. Those land per-app in later steps.

Delivered purely by ArgoCD:

- `argo_apps/apps/03_gateway.yaml` — the Application, **sync-wave 3**.
- `argo_apps/charts/03_gateway/` — the wrapper chart (Gateway + ClusterIssuers + the `gateway-test`
  echo app).
- plus a one-line enablement in `argo_apps/charts/02_cert_manager/values.yaml`.

And one bootstrap helper (no cluster apply — values propagation only, like `04`'s `config.sh` flow):

- `10_gateway/config.sh` — knobs `LE_EMAIL` + `BASE_DOMAIN` (env-overridable).
- `10_gateway/10_gateway.sh` — writes those into the chart's `values.yaml` (`acme.email` +
  `baseDomain`) via `yq`, so the shell side and ArgoCD render the same. Non-interactive.

## Why this exists / the migration context

The old single Raspberry Pi still receives all `:80`/`:443` from the home router and runs Traefik.
We migrate one hostname at a time to this cluster. For a migrated host the old Pi's Traefik becomes
a dumb forwarder to this Gateway's IP:

- `:443` → **TCP/SNI passthrough** (`HostSNI` + `tls.passthrough`) to the Gateway: the **cluster**
  terminates TLS and owns the cert. The eventual final cutover (repoint the router straight at the
  Gateway IP) is then a no-op on the cluster.
- `:80` → **L7 HTTP forward** (per-host `Host(...)` router) to the Gateway: plaintext has no SNI, so
  port 80 can't be routed per-host at L4. This forward carries the ACME **HTTP-01** challenge into
  the cluster so cert-manager can mint that host's cert, and (later) lets the cluster issue the
  forced http→https redirect.

Two landmines on the old Pi when forwarding `:80` (documented here so the cluster side makes sense):

1. Traefik's **internal ACME router has top priority** and would swallow `/.well-known/acme-challenge/`
   before any forward fires — set `--entrypoints.http.allowACMEByPass=true` on the old Pi.
2. Once a host's `:80` forwards here, the old Pi can no longer satisfy HTTP-01 for it — **remove that
   host from the old Pi's cert SANs list** so its monolithic cert keeps renewing.

## Decisions

### One shared Gateway, pinned IP
A single `Gateway` (`shared-gateway`, namespace `gateway`) is the cluster's lone ingress. Apps attach
`HTTPRoute`s to it cross-namespace (`listener.allowedRoutes.namespaces.from: All`). The IP is pinned
to **`192.168.100.10`** — the start of the Cilium LB-IPAM pool from `04_networking/config.sh`
(`192.168.100.10-250`) — via the Gateway API `spec.addresses` field, which Cilium honours through
LB-IPAM. (The older `io.cilium/lb-ipam-ips` annotation also works but is being deprecated.) This is
the fixed IP the old Pi forwards to; keep it stable.

### Listeners: always-on `:80`, per-app `:443`
The `:80` HTTP listener needs no cert and serves both pre-HTTPS jobs: cert-manager's HTTP-01 solver
routes attach here, and the future forced http→https redirect is just a `RequestRedirect` HTTPRoute on
this same listener. Each `:443` listener carries a `hostname` + `certificateRefs` and is added **with
its app** (a Terminate listener with no cert would sit permanently not-Ready), guarded so it vanishes
if the app is toggled off. The first one is `gateway-test`'s (`gatewayTest.enabled`). The TLS `Secret`s
live in the `gateway` namespace alongside the Gateway, so listener `certificateRefs` need no
ReferenceGrant.

### gateway-test: the echo app that proves the path
`gateway-test` is a throwaway `traefik/whoami` Deployment — the simplest "is the gateway working" echo
(listens on `:80`, echoes the request). It ships the first full app slice on the Gateway: Deployment +
Service + `Certificate` + HTTPS listener + HTTPRoute, all in the `gateway` namespace (so no
cross-namespace ReferenceGrants for the backend or the cert Secret). It exercises the **entire** path
end to end — DNS → old-Pi `:80` forward → Gateway → cert-manager HTTP-01 → issued cert → TLS terminate
→ echo. Its `Certificate` defaults to `letsencrypt-staging` (prove issuance without burning prod
quota; flip `gatewayTest.issuer` to `letsencrypt-prod` for a browser-trusted cert). No `:80` redirect
route for it yet — the http listener stays free for ACME; reach it over https. Set
`gatewayTest.enabled: false` and re-sync to tear the whole thing (including its `:443` listener) down.

### Email + base domain are config.sh-driven
Per `CLAUDE.md`, no values are hardcoded in scripts. `10_gateway/config.sh` holds `LE_EMAIL` and
`BASE_DOMAIN` (env-overridable, no prompting); `10_gateway.sh` writes them into the chart's
`values.yaml` (`acme.email`, `baseDomain`) with `yq` — the same source-of-truth-into-values pattern
`04_cilium.sh` uses for the LB pool. Hostnames are derived `<subdomain>.<baseDomain>` (so
`gateway-test.${BASE_DOMAIN}`). Commit the rewritten `values.yaml` so ArgoCD renders the same.

### Staging + prod ClusterIssuers
Both `letsencrypt-staging` and `letsencrypt-prod` are shipped (cluster-scoped, usable from any
namespace). Always validate a new host against **staging** first — prod's rate limits are tight and a
misconfigured HTTP-01 loop burns the weekly quota fast — then flip the host's `Certificate` to prod.
Each issuer's ACME account key is stored in cert-manager's namespace; the HTTP-01 solver is
`gatewayHTTPRoute` with `parentRefs` to the shared Gateway.

### Enabling Gateway API in cert-manager (the corrected way)
HTTP-01-via-Gateway requires cert-manager to manage `HTTPRoute`s. Since **cert-manager 1.15 this is
no longer the `ExperimentalGatewayAPISupport` feature gate** (that gate is gone) — it's enabled with
the controller file config `config.enableGatewayAPI: true` (set under the `cert-manager:` key in
`02_cert_manager/values.yaml`). The only ordering requirement is that the Gateway API CRDs exist
before the controller starts; they do, because Cilium vendors them at wave 0, long before the wave-2
cert-manager. A values change rolls the controller, so the fresh pod detects the CRDs. If you ever
install the CRDs *after* cert-manager, restart its Deployment.

## Sync-wave: 3

The ClusterIssuers need cert-manager's CRDs **and** a controller with Gateway API enabled (wave 2);
the Gateway needs Cilium's Gateway API (wave 0). Wave 3 is the lowest wave strictly after both. It is
auto-synced (prune + selfHeal) — a safe leaf: pruning drops ingress but, unlike Cilium, can't cut the
cluster off its own network. It owns no CRDs, so a prune never cascade-deletes one.

## Apply / verify

1. Set knobs and propagate them: edit `10_gateway/config.sh` (or env-override), run
   `./10_gateway/10_gateway.sh`, then commit the rewritten `values.yaml`. ArgoCD (wave 3) applies the
   rest.
2. For `gateway-test` to actually get a cert, the host must be reachable from the internet on `:80`:
   point `gateway-test.<baseDomain>` (public DNS) at the home router, and on the old Pi forward `:80`
   for that host to the Gateway IP (`allowACMEByPass=true` + a `Host(...)` HTTP router, per the
   migration mechanics above). Until then the `Certificate` and the `:443` listener stay not-Ready —
   expected, and it blocks nothing (no later waves depend on it).

Checks:

- `kubectl -n gateway get gateway shared-gateway` → `PROGRAMMED=True`, address `192.168.100.10`.
- `kubectl get svc -n gateway` → `cilium-gateway-shared-gateway` has EXTERNAL-IP `192.168.100.10`.
- `kubectl get clusterissuer` → both `letsencrypt-staging` / `letsencrypt-prod` show `READY=True`.
- cert-manager controller logs are clean re: Gateway API (no "gateway API not enabled" warnings).
- once DNS + the old-Pi forward exist: `kubectl -n gateway get certificate gateway-test` → `READY=True`,
  then `curl -kv https://gateway-test.<baseDomain>/` returns the whoami echo (`-k` because staging is
  untrusted; drop it after flipping to prod).

## Next step (not in this chart)

Per real app/host, repeat the `gateway-test` slice: Deployment/Service (or its own namespace +
ReferenceGrants), a `:443` listener + `Certificate`, and an `HTTPRoute`. Add the forced http→https
redirect as a `RequestRedirect` HTTPRoute on the `:80` listener. On the old Pi: add the `:443`
SNI-passthrough + `:80` forward `/rules`, and drop the host from the old SANs list.
