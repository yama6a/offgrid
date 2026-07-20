# 07: Ingress, TLS & SSO

The GitOps L7 ingress layer, delivered entirely by ArgoCD. Components stack in wave order: Envoy
Gateway (the Gateway API data plane), cert-manager (issues the X.509 certs), the shared Gateway +
Let's Encrypt ClusterIssuers (the ACME ingress platform), the central **Google-SSO** (one policy per
domain, wave 4), and the **platform ingress** edges (wave 6). Together they terminate TLS and
route/authenticate every ingress host on one pinned LoadBalancer IP. Cilium
([04_networking.md](04_networking.md)) stays the CNI and LB-IPAM provider; only the gateway lives here.

The repeated **edge** shape — per host a Gateway + HTTPRoute + ReferenceGrant, one multi-SAN `Certificate`
per ingress — is rendered once by the shared `ingress` library chart (`lib/helm/ingress/`,
see [the wrapper-chart conventions](../CLAUDE.md)); Envoy Gateway's `mergeGateways` folds every host's Gateway
onto one Envoy + one LoadBalancer Service. So the cluster keeps a single ingress point on the pinned IP while
each ingress is just a values list of hosts. **SSO is not part of the edge** — it's applied centrally per
domain by `04_google_sso` (one `SecurityPolicy` with per-host allowlists), so charts declare plain edges and
know nothing about SSO ([10_sample_workload.md](10_sample_workload.md)).

## Envoy Gateway

The Gateway API data plane. Cilium *can* serve Gateway API, but has no per-route auth hook; Envoy
Gateway ships a `SecurityPolicy` CRD with `targetSelectors` (label-based attachment) and native
`oidc` + `jwt` + `authorization`. That single capability (label a route -> it's SSO-protected, no
per-host proxy) is worth swapping the data plane for. Cilium keeps CNI, WireGuard, L2 announcements,
LB-IPAM; Envoy Gateway becomes the one thing that terminates and routes ingress.

Pure GitOps, no imperative script:

- `argo_apps/platform/apps/01_envoy_gateway.yaml`: the Application, sync-wave 1.
- `argo_apps/platform/charts/01_envoy_gateway/`: the wrapper chart: the envoy-gateway controller
  (upstream `gateway-helm`), the `eg` `GatewayClass`, and an `EnvoyProxy` that pins the LB IP.
- a one-line flip in `argo_apps/platform/charts/00_cilium/values.yaml` (`gatewayAPI.enabled: false`)
  + removal of the vendored Gateway API CRDs.

### Envoy Gateway owns the Gateway API CRDs
`cilium.gatewayAPI.enabled: false` drops the `cilium` `GatewayClass` and Cilium's gateway
controller. `gateway-helm` vendors the Gateway API CRDs (a newer version than the ones Cilium
vendored), so we remove `argo_apps/platform/charts/00_cilium/crds/gateway.networking.k8s.io_*.yaml`
and let Envoy Gateway be the single owner. The handover is safe because Envoy Gateway re-applies the
same CRDs via ServerSideApply and takes over ArgoCD ownership of them, so they stay present in the
cluster's desired state as ownership moves off Cilium's app — the safety rests on that transfer, NOT
on Cilium refusing to prune (Cilium's app runs `prune: true`). This ordering matters downstream: Envoy Gateway
installs the CRDs at wave 1, before cert-manager's `enableGatewayAPI` (wave 2) wants them present.

### One Envoy, one pinned LB IP (mergeGateways)
Each app owns its own Gateway with a single `:443` listener; `shared-gateway` keeps only the `:80`
HTTP listener. By default Envoy Gateway spawns one Envoy Deployment + one LoadBalancer Service *per
Gateway*, handing out a fresh external IP per app. `mergeGateways: true` on the `EnvoyProxy`
collapses every `eg`-class Gateway onto a single Envoy Deployment + single LoadBalancer Service, so
the per-app split still presents one ingress point on one IP. That IP is pinned solely by the
`EnvoyProxy` provider annotation `lbipam.cilium.io/ips: 192.168.100.10` (Cilium LB-IPAM honours it
on >= 1.15); per-Gateway `spec.addresses` is dropped everywhere (multiple Gateways asserting an
address on the one merged Service would conflict). The IP must stay inside the LB-IPAM pool
(`192.168.100.10-250`, from `.env`) — it's the fixed IP the old Pi forwards to (see below), keep it
stable.

### Cutover: free the pinned IP (orphan-Service gotcha)
Cilium's old gateway controller created `cilium-gateway-shared-gateway` (LoadBalancer, IP `.10`).
With Cilium's gateway controller disabled nothing reconciles that Service, so it can linger and
hold `192.168.100.10`, blocking Envoy Gateway's new Service from getting it. Flipping `mergeGateways`
similarly makes Envoy Gateway tear down its old per-Gateway data-plane Services and recreate one
merged Service (`envoy-gateway-system/envoy-eg-<hash>`), so a stale per-Gateway EG Service can also
hold the IP. After the change, verify exactly one `LoadBalancer` Service holds `192.168.100.10`; if
an orphan still holds it, delete it so LB-IPAM reassigns, e.g.
`kubectl -n gateway delete svc cilium-gateway-shared-gateway`. One-off, apply-time only.

### Verify
- `kubectl get gatewayclass eg` -> `ACCEPTED=True`.
- `kubectl -n gateway get gateway shared-gateway` -> `PROGRAMMED=True`, address `192.168.100.10`.
- `kubectl -n envoy-gateway-system get pods` -> controller Running; a data-plane `envoy-*` pod
  appears once a Gateway is programmed, its Service EXTERNAL-IP `192.168.100.10`.

### Proxy metrics & per-route HTTP alerts
The merged proxy serves Prometheus stats on `:19001/stats/prometheus` (on by default — no EnvoyProxy
`telemetry` config needed). A PodMonitor (`01_envoy_gateway/templates/podmonitor.yaml`, `metrics.podMonitor` knob;
VM operator → VMPodScrape) scrapes it so `envoy_*` reaches VictoriaMetrics. Envoy's upstream-cluster stats are
labelled `envoy_cluster_name="httproute/<gw-ns>/<route>/rule/N"` — one cluster per HTTPRoute rule (i.e. per
ingress-chart instance) — so the `ingress-http` Grafana alerts (5xx/4xx rate, p95 latency, no-healthy-upstream,
connect failures) are **per route** with no extra config. See [09_monitoring.md](09_monitoring.md).

## cert-manager

The controller that issues and renews the X.509 certs behind the `:443` listeners, ultimately Let's
Encrypt certificates fetched and rotated automatically. This step installs the *controller only* —
no `Issuer`/`ClusterIssuer` ships here (those land in the next section, once a domain, public
reachability, and staging-vs-prod are settled). cert-manager is independently useful, so it lands on
its own.

Pure GitOps, a plain wave-2 leaf, no imperative script:

- `argo_apps/platform/apps/02_cert_manager.yaml`: the Application, sync-wave 2.
- `argo_apps/platform/charts/02_cert_manager/`: the wrapper chart (`Chart.yaml` pins cert-manager
  from `charts.jetstack.io`; all config under the `cert-manager:` key in `values.yaml`).

### CRDs installed by the chart, kept on prune
`values.yaml` sets `crds.enabled: true` (the chart owns/installs the CRDs) and `crds.keep: true`.
The Application runs `prune: true`; `keep` matters because a prune that removed a CRD would
cascade-delete every `Certificate`/`Issuer`/`Order` depending on it. Cilium's app has no such guard
(it runs `prune: true`); its gateway CRDs are instead kept safe by Envoy Gateway owning/re-applying
them (see "Envoy Gateway owns the Gateway API CRDs" above).
`ServerSideApply=true` because the CRDs are large enough to blow the client-side
last-applied-annotation limit (same reason `01_argocd` uses SSA). Runs in its own `cert-manager`
namespace (`CreateNamespace=true`).

### Wave 2, with nic-keeper and sealed-secrets
cert-manager, nic-keeper ([03_operating_system.md](03_operating_system.md)) and sealed-secrets
([06_secrets.md](06_secrets.md)) are independent leaves, so they share sync-wave `2` — the "after
the platform (CNI + ArgoCD) is in place" slot.

### Verify
```bash
kubectl -n cert-manager get pods          # controller / webhook / cainjector Running
kubectl get crd | grep cert-manager.io    # the CRDs are present
```
Optional smoke test, prove issuance with no external deps: apply a `selfSigned` `Issuer` + a
`Certificate` in a throwaway ns and watch `READY=True`, then delete the ns.

## Shared Gateway & ClusterIssuers

The ACME ingress platform: the `shared-gateway` (its `:80` HTTP listener, the cert-issuance entry
point) and the Let's Encrypt ClusterIssuers that solve HTTP-01 through it. This chart owns no apps
and no `:443` listeners — every HTTPS host lives on its own per-app Gateway (the pattern in the
intro), all merged onto the one Envoy.

Pure GitOps plus one values-propagation helper (no cluster apply):

- `argo_apps/platform/apps/03_gateway.yaml`: the Application, sync-wave 3.
- `argo_apps/platform/charts/03_gateway/`: the wrapper chart (the `:80` Gateway + ClusterIssuers).
- a one-line enablement (`enableGatewayAPI: true`) in
  `argo_apps/platform/charts/02_cert_manager/values.yaml`.
- `lib/shell/07_gateway.sh`: writes `.env`'s `LE_EMAIL` into the chart's `values.yaml` (`acme.email`)
  via `yq`, and propagates `CLOUDFLARE_WILDCARD_DOMAINS` (into `acme.cloudflare.zones` here **and** the ingress
  library's `cloudflareZones`). PURE `yq`, no cluster — runs early (bootstrap step 7, before ArgoCD).
  Non-interactive. Commit the rewritten files.
- `lib/shell/07_cloudflare_token.sh`: seals `CLOUDFLARE_API_TOKEN_SECRET` into `cert-manager` (see
  "Cloudflare DNS-01 & wildcards" below). Split out because sealing needs the live sealed-secrets
  controller, so it runs **after** ArgoCD is up (bootstrap step 12, beside the SSO/webhook re-seals);
  `make configure-cloudflare-token`. Skips + cleans up if the token is empty.

### The `:80` ACME listener (HTTP-01 fallback)
`shared-gateway` owns just the `:80` HTTP listener, no cert, no `:443`. It serves cert-manager's
HTTP-01 solver routes (the ClusterIssuers point at `shared-gateway` by name) and the future forced
http->https redirect (a `RequestRedirect` HTTPRoute on this same listener). With no cert refs it's
Programmed immediately, independent of any app. HTTP-01 is now the **fallback** for any domain not on
Cloudflare (see below): those hosts get a `:443` listener **per host** (HTTP-01 can't do wildcards),
living on the per-host Gateways, not here. For an HTTP-01 domain each ingress issues ONE multi-SAN cert
covering all its hosts; its listeners sit not-Ready until that cert issues (so hosts within an ingress
are coupled — a single failing SAN blocks them together), but different ingresses are independent, and
none blocks the platform's `:80`.

### Staging then prod ClusterIssuers
Both `letsencrypt-staging` and `letsencrypt-prod` ship (cluster-scoped). Always validate a new host
against staging first (prod's rate limits are tight), then flip that host's `Certificate` issuer to
prod (or, for the shared wildcards, flip `acme.cloudflare.wildcardIssuer`). Each issuer's HTTP-01 solver
is `gatewayHTTPRoute` with `parentRefs` to `shared-gateway`; when Cloudflare zones are configured each
issuer ALSO gets a `dns01.cloudflare` solver (below), and cert-manager picks per dnsName.

### Cloudflare DNS-01 & wildcards (per-domain, HTTP-01 fallback)
We have Cloudflare for only *some* domains, so DNS-01 is **optional and per-domain**. One list drives it:
`CLOUDFLARE_WILDCARD_DOMAINS` in `.env` (space-separated host tiers on Cloudflare, e.g.
`"ops.example.com app.example.com example.com"`), gated by `CLOUDFLARE_API_TOKEN_SECRET` (a scoped API
token, Zone:DNS:Edit + Zone:Read). Empty ⇒ DNS-01 off, HTTP-01 for everything (unchanged). `07_gateway.sh`
writes the zones into two places (`07_cloudflare_token.sh` seals the token separately, after the
controller is up):

- **`03_gateway`** — each ClusterIssuer gets a `dns01.cloudflare` solver scoped `selector.dnsZones: <zones>`
  *plus* the existing `http01` catch-all. cert-manager picks the most-specific matching solver per dnsName,
  so names under a Cloudflare zone (incl. wildcards) go DNS-01 and everything else falls to HTTP-01 — no new
  issuer names, so the per-ingress `issuer:` values and the library's issuer allowlist are untouched.
  `03_gateway` also mints ONE **shared wildcard `Certificate` per zone** (`*.<zone>` + apex, into
  `wildcard-<zone-dashed>-tls`, at `acme.cloudflare.wildcardIssuer`) — reusable across every ingress on that
  tier (e.g. `platform` and `ntfy` both share `wildcard-ops-example-com-tls`).
- **the ingress library** (`cloudflareZones`) — an ingress whose `domain` is a Cloudflare zone points its
  listeners at the shared `wildcard-<domain>-tls` and **skips** its own per-ingress `Certificate`; any other
  domain keeps the per-host multi-SAN HTTP-01 cert. Automatic, per-domain — no per-ingress flag.

Wildcards match one label only, so we mint per tier (`*.ops.<base>`, `*.app.<base>`, `*.<base>`), not a
single `*.<base>`. cert-manager runs a DNS self-check before validation; it's pointed at public resolvers
(`dns01RecursiveNameservers` in `02_cert_manager`) so a split-horizon home DNS can't wedge issuance, and its
NetworkPolicy allows egress `:53`/`:443` to the world for the Cloudflare API + that check. **After changing
the ingress library you must re-vendor its consumers** (`helm dependency update` per consumer) — `07_gateway.sh`
prints the exact loop. Once `ntfy` rides the shared `ops` wildcard (prod), its separate-ingress workaround
(a prod cert off the staging SAN set) is no longer needed and it can fold back into `platform`.

### Enabling Gateway API in cert-manager
HTTP-01-via-Gateway needs cert-manager to manage `HTTPRoute`s. Since cert-manager 1.15 this is the
controller file config `config.enableGatewayAPI: true` (**not** the old `ExperimentalGatewayAPISupport`
feature gate, which is gone), set under the `cert-manager:` key in `02_cert_manager/values.yaml`. The
Gateway API CRDs must exist before the controller starts; they do, because Envoy Gateway installs
them at wave 1. If you ever install the CRDs after cert-manager, restart its Deployment.

### Old-Pi Traefik migration
The old single Raspberry Pi still receives all `:80`/`:443` from the home router and runs Traefik.
Migrated hosts move here one at a time; for a migrated host Traefik becomes a dumb forwarder to this
Gateway's IP:

- `:443` -> TCP/SNI passthrough (`HostSNI` + `tls.passthrough`) — the cluster terminates TLS and
  owns the cert; the eventual router-straight-to-Gateway cutover is then a no-op on the cluster.
- `:80` -> per-host `Host(...)` L7 forward, carrying the ACME HTTP-01 challenge in so cert-manager
  can mint that host's cert (plaintext has no SNI, so it can't be routed per-host at L4).

Two old-Pi landmines when forwarding `:80`: set `--entrypoints.http.allowACMEByPass=true` (else
Traefik's ACME router swallows `/.well-known/acme-challenge/` before the forward fires), and remove
the migrated host from the old Pi's cert SANs (it can no longer satisfy HTTP-01 for it, and its
monolithic cert must keep renewing).

### Verify
- `kubectl -n gateway get gateway` -> `shared-gateway` `PROGRAMMED=True` immediately, plus one
  per-app Gateway per host, all with address `192.168.100.10`.
- `kubectl get svc -n envoy-gateway-system` -> one Envoy `LoadBalancer` (`envoy-eg-<hash>`),
  EXTERNAL-IP `192.168.100.10`.
- `kubectl get clusterissuer` -> both `letsencrypt-staging` / `letsencrypt-prod` `READY=True`.

## The ingress library

The per-host edge used to be four hand-copied templates in every app chart. It now lives in ONE
`type: library` chart, `lib/helm/ingress/`, which renders — for a list of `ingresses[]`, each a
group of subdomains under one `domain` — a Gateway + HTTPRoute + ReferenceGrant per host and, for a
non-Cloudflare domain, ONE multi-SAN `Certificate` per ingress (covering all its hosts, into one shared
Secret every listener references). For a Cloudflare domain (its `domain` in `cloudflareZones`) it instead
points the listeners at the shared `wildcard-<domain>-tls` minted by `03_gateway` and emits no per-ingress
cert (see "Cloudflare DNS-01 & wildcards"). It renders **no SSO** — Google-SSO is applied centrally per
domain by `04_google_sso` (below). The cluster
wiring (gateway namespace `gateway`, gateway class `eg`, fallback issuer) is hardcoded in the library, NOT a
per-consumer value — those are platform invariants, so a consumer's only cert knob is `ingresses[].issuer`.
Consumers are thin: a `file://` dependency on the library, a one-line template
(`{{ include "ingress.render" . }}`), and an `ingress:` values block. See [CLAUDE.md](../CLAUDE.md) for the
library-chart + `file://` + committed-`Chart.lock` convention.

Consumers: `06_platform_ingress` (the platform UIs' edges), each workload chart, and `04_google_sso` (its
callback hosts' edges). ReferenceGrants are emitted only for cross-namespace backends.

Each ingress declares exactly one registrable `domain`; every host gives a `subdomain` under it
(host = `<subdomain>.<domain>`; `subdomain: "@"` = the apex). The library `fail`s the render (so ArgoCD
reports it, nothing applies) if an ingress has **no `domain`**, a host has **no `subdomain`**, or a
`subdomain` **looks like a full hostname** (already ends with the domain — the classic copy-paste slip).
Per-host resource names derive from the full host (`argocd.ops.example.com` -> `argocd-ops-example-com`).

Two tiers under the one base domain: **platform UIs** (`06_platform_ingress`) sit under `*.ops.<base>`,
**workloads** under `*.app.<base>` (e.g. `grafana.ops.example.com`, `sample-user-manager.app.example.com`).
Each is still one registrable `domain` from the library's point of view (`ops.example.com` / `app.example.com`),
so without Cloudflare they get separate per-ingress multi-SAN certs; with Cloudflare each tier gets one shared
`*.<tier>` wildcard reused across its ingresses. SSO keeps them under a single `example.com` entry (below).

## Google SSO — one policy per domain, per-host allowlists

Google login + a per-host email allowlist, applied **centrally** in `argo_apps/platform/charts/04_google_sso`
(wave 4). Per domain it renders ONE Envoy Gateway `SecurityPolicy` that `targetRefs` the domain's shared
callback route **and** every gated app route, plus the shared `google-sso.<domain>` callback host (edge via
the library) + a tiny whoami + the sealed OAuth client secret.

**Why one policy per domain, not per app (the constraint that shapes this).** Envoy's OAuth2 filter signs its
CSRF-nonce cookie under a name suffixed **per SecurityPolicy** (`OauthNonce-<hash>`), and EG gives no
way to pin it. So the login handshake only completes if the **same** policy both starts the flow (on the app
host) and finishes it (on the callback host) — a shared callback host with *separate* per-app policies fails
with `CSRF token validation failed`. Hence: one policy per domain covering the app routes **and** the callback
route → one cookie identity → the flow completes. `cookieDomain: <domain>` then lets the nonce set on
`grafana.<domain>` be read when the callback lands on `google-sso.<domain>` (same registrable domain).

**Per-host allowlists in that one policy.** Authorization is a list of rules; each rule ANDs a host match
(`principal.headers` on the `:authority` request header) with the email claim, so different hosts get
different allowlists. `defaultAction: Deny`, so a host with no rule (including the callback whoami) is denied;
the `/oauth2/callback` path is handled by the `oidc` filter *before* authorization, so login still works.

```
argocd.D (no session) -> [sso-D policy: oidc] 302 to Google -> callback to google-sso.D/oauth2/callback
                      -> [SAME sso-D policy] validates nonce, exchanges code, sets id-token cookie (.D) -> back to argocd.D
argocd.D (with cookie)-> [sso-D: oidc] pass -> [jwt] validate -> [authz] :authority==argocd.D AND email allowlisted? -> backend
```

Google needs exactly **one** redirect URI per domain (`google-sso.<domain>/oauth2/callback`). One OAuth
client (`clientID` + one sealed `client-secret`) serves everything.

### Workloads/packages configure NOTHING SSO
A chart declares only its ingress (domain + hosts + backends) — plain edges. Which hosts are protected, and by
whom, is the **central `domains[].hosts` map** in `04_google_sso/values.yaml`:

```yaml
domains:
  - domain: example.com                          # ONE entry gates both tiers (ops. + app.): cookieDomain/callback are its parent
    issuer: letsencrypt-prod
    hosts:
      - host: argocd.ops.example.com             # a platform UI (*.ops.<base>)
        allowlist: [admin@…]
      - host: sample-workload-sso.app.example.com   # a workload host (*.app.<base>), gated centrally
        allowlist: [user@…]
```

The policy `targetRefs` each host's route **by name** (the full host, dots -> dashes — the library's naming),
so it attaches to routes created by *any* chart. To protect a host: add it here with its allowlist (its route
exists wherever its ingress lives). A host not listed stays open. `sample-workload.app.example.com` is the open
control (not listed); `sample-workload-sso.app.example.com` is listed → gated. Note the single `example.com`
domain entry gates hosts across *both* the `ops.` and `app.` tiers — `cookieDomain: example.com` and the
`google-sso.example.com` callback are a parent of each, so no per-tier policy/redirect-URI split is needed.

### Bypassing SSO for a path (the ArgoCD webhook)

Because the policy attaches **by route name**, the same trick that leaves a whole host open also leaves a single
*path* open: give it its own `HTTPRoute` with a name the policy doesn't target. That's how the ArgoCD GitHub
webhook works. `06_platform_ingress/templates/argocd-webhook-route.yaml` renders a second route on the argocd
host — same Gateway/listener, but named `argocd-<domain>-webhook` (not `argocd-<domain>`) and matching only the
Exact path `/api/webhook`:

```
argocd.D/               -> route argocd-D          (targeted by sso-D)      -> Google SSO gate
argocd.D/api/webhook    -> route argocd-D-webhook  (NOT in sso-D targetRefs) -> straight to argocd-server
```

Gateway API prefers the more-specific path, so `/api/webhook` lands on the ungated route and everything else on
the gated one. Safe because ArgoCD authenticates that path itself via the GitHub HMAC signature
(`webhook.github.secret`), and the match is `type: Exact` so **only** the webhook endpoint escapes SSO — never
the rest of the admin API (which matters here: ArgoCD's anonymous user is admin). No `ReferenceGrant` is added:
the library's existing `gateway-routes-to-argocd-<domain>` grant already allows any route in `gateway` →
`argocd-server`. Setup + the secret live in [05_gitops.md](05_gitops.md#webhook-driven-sync-and-the-poll-fallback).

> The whole platform ingress (`06_platform_ingress`) is on `letsencrypt-prod`, not staging, precisely so GitHub's
> webhook SSL verification trusts `argocd.<domain>`. (The `google-sso.<domain>` callback edge below is separate
> and still follows its own `issuer`.)

### Adding a host / domain

| You add | Google Console | Cluster |
|---|---|---|
| a subdomain to an existing ingress | nothing (if already-gated domain) | add `{ subdomain, targetService, targetPort }` to that ingress's `hosts:` |
| protection for a host | nothing | add `{ host, allowlist }` to `04_google_sso` `domains[].hosts` |
| change who may log in | nothing | edit that host's `allowlist` in `04_google_sso` |
| a brand-new SSO domain | +1 redirect URI + the apex under "Authorized domains" | add a `domains[]` entry (with its `hosts`), run `07_google_sso.sh` |

**Adding an SSO domain `example.org`:** add a `domains:` entry to `04_google_sso/values.yaml` (`domain`,
`issuer`, its gated `hosts` + allowlists); point `google-sso.example.org` (+ each gated host) at the router
with the `:80` forward for HTTP-01; in Google add `example.org` under Authorized domains and
`https://google-sso.example.org/oauth2/callback` as a redirect URI; run `lib/shell/07_google_sso.sh`
(prints the URIs, writes `clientID`, re-seals the secret); commit + push. Flip `issuer` to `letsencrypt-prod`
once the staging callback cert issues.

### Allowlists central, only the client secret sealed
Envoy Gateway's `authorization` takes allowed emails as inline literals (can't come from a Secret), so they
live in `04_google_sso/values.yaml` `domains[].hosts[].allowlist` (low-sensitivity email in a private repo) —
edit + push to change access, not prompted by any script. Only the OAuth client secret is sealed
([06_secrets.md](06_secrets.md)).

### Fail-closed until sealed
Until `07_google_sso.sh` seals the client secret and you commit it, the policy references a missing Secret and
the placeholder `clientID` denies everyone — a half-configured policy never leaks access. Run the script first.

### Apply / verify
1. Put `GOOGLE_SSO_CLIENT_ID` + `GOOGLE_SSO_CLIENT_SECRET` in the gitignored `.env`; run
   `lib/shell/07_google_sso.sh` (needs the cluster for `kubeseal`). It reads the domains from
   `04_google_sso/values.yaml`, prints the redirect URIs, writes `clientID`, and seals the secret. Edit the
   `domains[].hosts` allowlists by hand.
2. Register each printed redirect URI on the one OAuth client; add each apex under "Authorized domains".
   Publish the consent screen (in "Testing" only listed test users log in, regardless of the allowlist).
3. Commit + push; ArgoCD applies `04_google_sso` (wave 4). The app routes it targetRefs may not exist until
   their own charts sync (platform-ingress wave 6, workloads later); EG attaches the policy when they appear.

Checks:
- `kubectl -n gateway get securitypolicy` -> one `sso-<domainslug>` per domain (`sso-example-com`),
  `Accepted=True` (not Accepted -> the client-secret Secret is missing; run the script + push).
- Browse a gated host -> Google login -> bounce through `google-sso.<domain>` -> an account on THAT host's
  allowlist reaches the app; one off it is denied. The open control host loads with no login.
- If login fails with `CSRF token validation failed`: the app route isn't covered by the same policy as the
  callback — confirm it's in `domains[].hosts` (so the policy `targetRefs` it) and the route name matches.
