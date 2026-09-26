# Ingress, TLS and SSO

Argo CD delivers the L7 ingress layer as five apps, in wave order:

| Wave | App | Role |
|---|---|---|
| 1 | `01_envoy_gateway` | the Gateway API data plane |
| 2 | `02_cert_manager` | issues the X.509 certs |
| 3 | `03_gateway` | the shared `:80` Gateway and the Let's Encrypt ClusterIssuers |
| 4 | `04_google_sso` | one SecurityPolicy per domain: which hosts are gated, and who may log in |
| 6 | `06_platform_ingress` | the edges of the platform UIs |

Together they terminate TLS, then route and authenticate every ingress host on one pinned LoadBalancer IP. Cilium
stays the CNI and the LB-IPAM provider, see [01_networking.md](01_networking.md). LB-IPAM is the Cilium allocator
for LoadBalancer IPs.

- **Edge**: the objects that expose one host. Per host that is a Gateway, an HTTPRoute and a ReferenceGrant. Per
  ingress it adds one multi-SAN `Certificate`, a single cert that lists every host of that ingress.
- **Rendering**: the shared `ingress` chart in `lib/helm/ingress/` renders every edge.
- **One ingress point**: the Envoy Gateway setting `mergeGateways` folds the Gateway of every host onto one Envoy
  and one LoadBalancer Service. The cluster keeps one ingress point on the pinned IP. Each ingress is only a values
  list of hosts.
- **SSO**: not part of the edge. `04_google_sso` applies it centrally, so charts declare plain edges and know
  nothing about SSO.

## Envoy Gateway

Cilium can serve Gateway API but has no per-route auth hook. Envoy Gateway ships a `SecurityPolicy` CRD with
native `oidc`, `jwt` and `authorization`. Its `targetSelectors` attach a policy by label. So a label on a route
puts that route behind SSO, with no proxy per host. That is the reason Envoy Gateway is the data plane. Cilium
keeps the CNI, WireGuard, L2 announcements and LB-IPAM.

Pure GitOps, no imperative script:

- `argo_apps/platform/apps/templates/01_envoy_gateway.yaml`: the Application, wave 1.
- `argo_apps/platform/charts/01_envoy_gateway/`: the controller (upstream `gateway-helm`), the `eg`
  `GatewayClass`, and an `EnvoyProxy` that pins the LB IP.
- `gatewayAPI.enabled: false` in `00_cilium/values.yaml`, so Cilium runs no gateway controller.

### Envoy Gateway owns the Gateway API CRDs

- `gateway-helm` installs the Gateway API CRDs. The Cilium chart ships none.
- `cilium.gatewayAPI.enabled: false` removes the `cilium` `GatewayClass` and the Cilium gateway controller.
- Envoy Gateway installs the CRDs at wave 1. cert-manager needs them at wave 2 for `enableGatewayAPI`.

### One Envoy, one pinned LB IP

Each app owns a Gateway with one `:443` listener. `shared-gateway` keeps only the `:80` HTTP listener.

By default Envoy Gateway creates one Envoy Deployment and one LoadBalancer Service per Gateway. Each app would get
its own external IP. `mergeGateways: true` on the `EnvoyProxy` puts every `eg`-class Gateway on one Envoy
Deployment and one Service. The apps keep separate Gateways but share one ingress point on one IP.

- Only the `EnvoyProxy` provider annotation `lbipam.cilium.io/ips` pins the IP. `04_values.sh` writes it from
  `INGRESS_LB_IP` in `.env`.
- No Gateway sets `spec.addresses`. Several Gateways that claim an address on the one merged Service would
  conflict.
- The IP must stay inside the LB-IPAM pool. `04_values.sh` checks this.
- Your router forwards to this IP, so keep it stable.

### Stale Service holding the pinned IP

A LoadBalancer Service that nothing reconciles can keep the pinned IP. The merged Envoy Service
(`envoy-gateway-system/envoy-eg-<hash>`) then gets no IP. Two Services can do this:

- `cilium-gateway-shared-gateway`, from the Cilium gateway controller. With that controller off, nothing deletes
  it.
- A per-Gateway Envoy Service from before `mergeGateways`. Envoy Gateway replaces those with the one merged
  Service, but a stale one can hold the IP.

Check that exactly one `LoadBalancer` Service holds the pinned IP. Delete any other one, and LB-IPAM reassigns the
IP:

```bash
kubectl get svc -A | grep LoadBalancer
kubectl -n gateway delete svc cilium-gateway-shared-gateway
```

### Proxy metrics and per-route HTTP alerts

- The merged proxy serves Prometheus stats on `:19001/stats/prometheus`. This is on by default and needs no
  `telemetry` config on the `EnvoyProxy`.
- A PodMonitor in `01_envoy_gateway/templates/podmonitor.yaml` scrapes it, so `envoy_*` reaches VictoriaMetrics.
- Envoy labels its upstream-cluster stats `envoy_cluster_name="httproute/<gw-ns>/<route>/rule/N"`. There is one
  cluster per HTTPRoute rule.
- So the `ingress-http` Grafana alerts work per route with no extra config. They cover the 5xx rate, the 4xx rate,
  p95 latency, no healthy upstream, and connect failures. See [06_monitoring.md](06_monitoring.md).

### The `ingress-http` dashboard

`05_grafana/files/dashboards/ingress-http.json`, uid `ingress-http`. It uses the same metrics as the alerts, in five
rows: overview, per route, upstream health, edge listeners, and the Google SSO handshake.

Cluster HTTP observability lives in this dashboard, not in Hubble:

- Hubble's L7 HTTP metrics need `httpV2` and an L7 `http` rule in a CiliumNetworkPolicy.
- That rule pulls matched traffic through the Cilium Envoy L7 proxy. On the ingress path this adds a second proxy
  hop that counts what the edge already counts.
- So `httpV2` stays off. The bundled Cilium dashboard "L7 HTTP metrics by workload" stays out of Grafana too. See
  [01_networking.md](01_networking.md).

Three behaviours of these metrics look like bugs but are correct:

- **Idle routes are absent.** The request counters of a route exist only after its first request. An idle route
  has no series, not a zero. So the route dropdown reads `envoy_cluster_membership_healthy`, which always has one
  series per configured route.
- **The listener row counts more than the route rows.** It counts everything that reaches `:80` or `:443`. That
  includes every SSO bounce that never reaches a backend. The route dropdown does not filter it.
- **`oauth_unauthorized_rq` climbs.** Each count is a logged-out browser with no session cookie that Envoy sends to
  Google. Watch `oauth_failure` instead.

The SSO panels match on the metric name, `envoy_securitypolicy_.+_oauth_.*`. Envoy builds one metric family per
SecurityPolicy and puts the policy namespace and name in the metric name, not in a label. A hardcoded query would
go empty, with no error, when someone renames or adds a policy.

### Verify

```bash
kubectl get gatewayclass eg                       # ACCEPTED=True
kubectl -n gateway get gateway shared-gateway     # PROGRAMMED=True, address is INGRESS_LB_IP, e.g. 192.168.100.10
kubectl -n envoy-gateway-system get pods          # controller Running. envoy-* appears once a Gateway is programmed
```

## cert-manager

cert-manager issues and renews the X.509 certs behind the `:443` listeners. This app installs the controller only.
No `Issuer` or `ClusterIssuer` ships here. Those need a domain, public reachability and a choice between staging
and prod first. `03_gateway` ships them. cert-manager is useful on its own, so it is a separate app.

Pure GitOps, wave 2, no dependency on the other wave-2 apps:

- `argo_apps/platform/apps/templates/02_cert_manager.yaml`: the Application, wave 2.
- `argo_apps/platform/charts/02_cert_manager/`: the wrapper chart. It pins cert-manager from `charts.jetstack.io`
  and holds all config under the `cert-manager:` key.

### CRDs installed by the chart, kept on prune

| Setting | Why |
|---|---|
| `crds.enabled: true` | the chart owns and installs the CRDs |
| `crds.keep: true` | the Application runs `prune: true`. A prune that removed a CRD would cascade-delete every `Certificate`, `Issuer` and `Order` that depends on it |
| `ServerSideApply=true` | the CRDs are too big for the annotation that client-side apply writes |
| `CreateNamespace=true` | cert-manager runs in its own namespace |

The Gateway API CRDs are not in this chart. Envoy Gateway owns them, see above.

### Wave 2, with sealed-secrets

cert-manager and sealed-secrets ([03_secrets.md](03_secrets.md)) do not depend on each other, so both sit in wave 2.
Wave 2 is the slot after the CNI and Argo CD are in place.

### Verify

```bash
kubectl -n cert-manager get pods          # controller, webhook and cainjector Running
kubectl get crd | grep cert-manager.io    # the CRDs are present
```

Optional smoke test with no external dependencies:

1. Apply a `selfSigned` `Issuer` and a `Certificate` in a throwaway namespace.
2. Wait for `READY=True`.
3. Delete the namespace.

## Shared Gateway and ClusterIssuers

`03_gateway` holds the ACME side of ingress. ACME is the protocol Let's Encrypt uses to issue certs. The chart
holds:

- the `:80` HTTP listener of `shared-gateway`, where cert issuance enters.
- the Let's Encrypt ClusterIssuers, which solve HTTP-01 challenges through that listener.

The chart owns no apps and no `:443` listeners. Every HTTPS host lives on its own per-app Gateway, and all of them
merge onto the one Envoy.

- `argo_apps/platform/apps/templates/03_gateway.yaml`: the Application, wave 3.
- `argo_apps/platform/charts/03_gateway/`: the `:80` Gateway and the ClusterIssuers.
- `enableGatewayAPI: true` in `02_cert_manager/values.yaml`.
- `lib/shell/04_values.sh`: writes `LE_EMAIL` from `.env` into `acme.email`. It writes
  `CLOUDFLARE_WILDCARD_DOMAINS` into `acme.cloudflare.zones` here and into `cloudflareZones` of the ingress chart.
  It writes values only and needs no cluster access. So it runs early, at bootstrap step 7, before Argo CD. It asks
  no questions. Commit the files it rewrites. It writes through `ys_set` and `ys_set_list`, never `yq -i`. See
  [02_gitops.md](02_gitops.md).
- `lib/shell/04_cloudflare_token.sh`: seals `CLOUDFLARE_API_TOKEN_SECRET` into the `cert-manager` namespace.
  Sealing needs the live sealed-secrets controller, so this script runs after Argo CD is up, through
  `make configure-cloudflare-token`. With an empty token it skips and cleans up.

### The `:80` ACME listener, the HTTP-01 fallback

`shared-gateway` owns only the `:80` HTTP listener, with no cert and no `:443`. It serves the cert-manager HTTP-01
solver routes, because the ClusterIssuers name it. With no cert refs it is Programmed at once, and no app can block
it.

HTTP-01 is the fallback for any domain not on Cloudflare. HTTP-01 cannot issue wildcards, so each such host gets its
own `:443` listener. Those listeners live on the per-host Gateways, not here. For an HTTP-01 domain, each ingress
issues one multi-SAN cert for all its hosts. Its listeners stay not-Ready until that cert issues. So:

- the hosts of one ingress share a fate. One failing SAN blocks all of them.
- different ingresses do not affect each other.
- no ingress blocks the platform `:80` listener.

### Staging then prod ClusterIssuers

Both `letsencrypt-staging` and `letsencrypt-prod` ship, cluster-scoped. Prod has tight rate limits, so validate
every new host against staging first. Then switch to prod:

- **One host**: set the issuer of its `Certificate` to prod.
- **The shared wildcards**: set `acme.cloudflare.wildcardIssuer`.
- **One new zone, while the other zones keep prod certs**: list it in `acme.cloudflare.wildcardIssuerOverrides`.
  Remove it once issuance works.

The HTTP-01 solver of each issuer is `gatewayHTTPRoute` with `parentRefs` to `shared-gateway`. With Cloudflare
zones configured, each issuer also gets a `dns01.cloudflare` solver. cert-manager picks a solver per dnsName.

### Cloudflare DNS-01 and wildcards

Only some domains are on Cloudflare, so DNS-01 is optional and set per domain. One list drives it:
`CLOUDFLARE_WILDCARD_DOMAINS` in `.env`. It holds the host tiers on Cloudflare, space-separated. A tier is a domain
level that holds hosts, such as `ops.example.com`.

- `CLOUDFLARE_API_TOKEN_SECRET` gates the list. It is a scoped API token with `Zone:DNS:Edit` and `Zone:Read`.
- An empty list turns DNS-01 off, and every host uses HTTP-01.

`04_values.sh` writes the zones into two places:

- **`03_gateway`**: each ClusterIssuer gets a `dns01.cloudflare` solver with `selector.dnsZones: <zones>`, next to
  the existing `http01` catch-all.
  - cert-manager picks the most specific matching solver per dnsName. Names under a Cloudflare zone go DNS-01,
    wildcards included. Everything else falls back to HTTP-01.
  - The issuer names stay the same. So the per-ingress `issuer:` values and the issuer allowlist of the chart
    stay untouched.
  - `03_gateway` also mints one shared wildcard `Certificate` per zone. It covers `*.<zone>` and the apex, and
    lands in `wildcard-<zone-dashed>-tls`. It uses `acme.cloudflare.wildcardIssuer`, or the entry of that zone in
    `wildcardIssuerOverrides`. Every ingress on that tier reuses it.
  - A zone need not sit under `BASE_DOMAIN`. The token needs `Zone:DNS:Edit` and `Zone:Read` on every zone in the
    list.
- **The ingress chart** (`cloudflareZones`): an ingress whose `domain` is a Cloudflare zone points its listeners at
  the shared `wildcard-<domain>-tls`. It skips its own per-ingress `Certificate`. Any other domain keeps the
  per-host multi-SAN HTTP-01 cert. This works per domain with no per-ingress flag.

A wildcard matches one label only. So the repo mints one wildcard per tier, such as `*.ops.<base>`, `*.app.<base>`
and `*.<base>`, not a single `*.<base>`.

One Secret backs every listener on a zone, across every chart. A wildcard that never issues takes down the whole
zone at once, not one host. The usual cause is a zone in the list on which the API token has no `Zone:DNS:Edit`.
Neither the Gateway nor the Certificate names the token. The Cloudflare error shows up in
`kubectl -n cert-manager get challenges`.

cert-manager runs a DNS self-check before validation. `dns01RecursiveNameservers` in `02_cert_manager` points it at
public resolvers, so a split-horizon home DNS cannot block issuance. Its NetworkPolicy allows egress to the world on
`:53` and `:443`, for the Cloudflare API and that check.

After you change the ingress chart, re-vendor each consumer with `helm dependency update`. `04_values.sh` prints
the exact loop.

### Enabling Gateway API in cert-manager

To solve HTTP-01 through a Gateway, cert-manager must manage `HTTPRoute`s. The setting is
`config.enableGatewayAPI: true` under the `cert-manager:` key. It is controller file config, not a feature gate.

The Gateway API CRDs must exist before the controller starts. Envoy Gateway installs them at wave 1, so they do. If
the CRDs are ever installed after cert-manager, restart the cert-manager Deployment.

### Verify

```bash
kubectl -n gateway get gateway            # shared-gateway PROGRAMMED=True, plus one per host, all on the pinned IP
kubectl get svc -n envoy-gateway-system   # one Envoy LoadBalancer (envoy-eg-<hash>) holding the pinned IP
kubectl get clusterissuer                 # letsencrypt-staging and letsencrypt-prod both READY=True
```

## The shared ingress chart

`lib/helm/ingress/` is one `type: application` chart that renders the edge of every host. App charts do not copy
the edge by hand. The input is a list of `ingresses[]`. Each ingress is a group of subdomains under one `domain`.
The chart renders:

- a Gateway, an HTTPRoute and a ReferenceGrant per host. A ReferenceGrant only for a backend in another namespace.
- for a host with `redirectTo`: a 301 at the edge instead of a backend, and no ReferenceGrant.
- for a domain not on Cloudflare: one multi-SAN `Certificate` per ingress for all its hosts. It lands in one shared
  Secret that every listener of the ingress references.
- for a Cloudflare domain: no `Certificate`. The listeners point at the shared `wildcard-<domain>-tls` that
  `03_gateway` mints.
- no SSO. `04_google_sso` applies SSO centrally.

The cluster wiring is hardcoded: gateway namespace `gateway`, gateway class `eg`, and the fallback issuer. These
are platform invariants, not per-consumer values. The only cert knob of a consumer is `ingresses[].issuer`.

Consumers are thin: a `file://` dependency and an `ingress:` values block, with no template of their own. With
`file://` dependencies only, they have no lock and gitignore their `Chart.lock`. `04_google_sso` is the exception.
It builds its callback hosts with the `ingress.renderIngress` named template, inline next to its own
SecurityPolicy. So it carries the dependency and keeps its own template.

Consumers: `06_platform_ingress`, each workload chart, and `04_google_sso`.

Host names:

- Each ingress declares exactly one registrable `domain`. Every host gives a `subdomain` under it. The host is
  `<subdomain>.<domain>`. `subdomain: "@"` means the apex.
- The chart `fail`s the render when an ingress has no `domain`, when a host has no `subdomain`, or when a
  `subdomain` already ends with the domain. The last one is a common copy-paste slip. Argo CD shows a failed
  render, and nothing applies.
- Per-host resource names come from the full host, with dots turned to dashes. So hosts never collide across
  domains.
- The ingress `name` can collide. It becomes `<name>-tls` in the shared `gateway` namespace. On a domain not on
  Cloudflare it must be unique across all consumer charts, not only within one.

The base domain has two tiers: platform UIs under `*.ops.<base>` and workloads under `*.app.<base>`. The chart
sees each tier as one registrable `domain`. Without Cloudflare, each ingress gets its own multi-SAN cert. With
Cloudflare, each tier gets one shared `*.<tier>` wildcard, reused across its ingresses. SSO covers both tiers with
a single `example.com` entry, see [Google SSO](#google-sso).

### Redirect hosts

A host sets either `targetService` and `targetPort`, or `redirectTo`. Both or neither `fail`s the render.

`redirectTo` gives the host a `RequestRedirect` filter and no `backendRefs`. Envoy answers with a 301 itself, and
no pod is involved. Path and query survive, because `requestRedirect` rewrites only the fields it names. The main
use is apex to www:

```yaml
hosts:
  - subdomain: "@"
    redirectTo: www.example.com
  - subdomain: www
    targetService: web
    targetPort: 3000
```

- **301, not 308**: the targets are canonical hostnames that browsers and search engines should cache for good.
  301 is also what apex redirects in the wild send.
- **Full edge**: a redirect host still gets its own Gateway, `:443` listener and cert SAN. So the TLS handshake
  completes before Envoy sends the redirect. Without them the browser shows a certificate error and does not
  follow the redirect.

### Request headers

`requestHeaders` is a map of headers that Envoy sets on the request before it goes to the backend. Response
headers stay untouched. `set` replaces any value the client sent, so a client cannot smuggle its own value through.

```yaml
hosts:
  - subdomain: www
    targetService: web
    targetPort: 3000
    requestHeaders:
      X-Forwarded-Port: "443"
```

`X-Forwarded-Port` is the reason this exists:

- Envoy sends `x-forwarded-proto` and `x-forwarded-for`, but not `x-forwarded-port`. It passes `Host` through
  without a port.
- A framework that builds absolute URLs from the request then has no port to read. It falls back to the port its
  own server listens on.
- Redirects then point at something like `https://www.example.com:3000/`. That port is not public. Behind
  Cloudflare it is not even a proxied port. So the redirect goes nowhere.

Next.js is the known case. `getHostname` strips the port from `Host`, but `NextURL` still carries the listen port.
So every `NextResponse.redirect` built from `request.nextUrl` inherits it. Traefik sets this header, so a Next.js
app that worked behind Traefik shows the problem only behind Envoy.

`requestHeaders` on a redirect host `fail`s the render. Envoy forwards nothing upstream there, so the headers would
go nowhere.

## Google SSO

`argo_apps/platform/charts/04_google_sso` (wave 4) applies Google login centrally, with an email allowlist per
host. One policy per domain gates a listed set of hosts. Per domain the chart renders:

- one Envoy Gateway `SecurityPolicy`. Its `targetRefs` cover the shared callback route of the domain and every
  gated app route.
- the shared callback host `google-sso.<domain>`.
- a small whoami backend.

The chart also holds the sealed OAuth client secret.

### One policy per domain

One policy per domain, not one per app. This constraint shapes the whole design:

- The Envoy OAuth2 filter signs its CSRF nonce cookie under a name with a per-SecurityPolicy suffix,
  `OauthNonce-<hash>`. Envoy Gateway cannot pin that name.
- So the login handshake completes only if the same policy starts the flow on the app host and finishes it on the
  callback host.
- A shared callback host with separate per-app policies fails with `CSRF token validation failed`.

One policy per domain covers the app routes and the callback route. That gives one cookie identity, so the flow
completes. `cookieDomain: <domain>` lets the callback on `google-sso.<domain>` read the nonce set on
`grafana.<domain>`. Both hosts share a registrable domain.

Per-host allowlists live in that one policy:

- Authorization is a list of rules. Each rule ANDs a host match with the email claim. The host match is
  `principal.headers` on the `:authority` request header. So each host can have its own allowlist.
- `defaultAction: Deny`. A host with no rule is denied, the callback whoami included.
- The `oidc` filter handles `/oauth2/callback` before authorization runs, so login still works.

```
argocd.D (no session) -> [sso-D policy: oidc] 302 to Google -> callback to google-sso.D/oauth2/callback
                      -> [same sso-D policy] validates nonce, exchanges code, sets id-token cookie (.D) -> back to argocd.D
argocd.D (with cookie)-> [sso-D: oidc] pass -> [jwt] validate -> [authz] :authority==argocd.D AND email allowlisted? -> backend
```

Google needs exactly one redirect URI per domain, `google-sso.<domain>/oauth2/callback`. One OAuth client serves
everything: a `clientID` and one sealed `client-secret`.

### Session length

A session lasts `sessionTTL`, 24h, not the 1h of the Google id token. Envoy renews the id token with a refresh
token. Google issues a refresh token only when the auth request carries `access_type=offline` and the consent
screen showed.

- So the policy pins `authorizationEndpoint` with `access_type=offline&prompt=consent`.
- The cost is one confirm click per login.
- Without `prompt=consent`, the first login after a session expires gets no refresh token, and nothing reports
  it. Sessions then last 1h until you revoke the app under myaccount.google.com/permissions.

### Workloads configure no SSO

A chart declares only its ingress: domain, hosts and backends. The central `hosts` list in
`04_google_sso/values.yaml` sets which hosts are protected, and for whom:

```yaml
domain: example.com        # written by 04_values.sh from .env BASE_DOMAIN
issuer: letsencrypt-prod
allowlist:                 # written by 04_values.sh from .env SSO_ALLOWLIST
  - you@example.com
hosts:
  - subdomain: argocd.ops                    # a platform UI
  - subdomain: sample-user-manager-sso.app   # a workload host, gated centrally
    allowlist: [ops@example.com]             # optional, replaces the list above for this host only
```

- Each `subdomain` combines with `domain` into the FQDN its ingress renders.
- The policy `targetRefs` the route of that host by name, which is the full host with dots turned to dashes. So it
  attaches to routes that any chart creates.
- To protect a host, add its subdomain here. Its route exists wherever its ingress lives.
- A host not listed stays open. `sample-user-manager.app.example.com` is the open control and is not listed.
  `sample-user-manager-sso.app` is listed, so it is gated.

One entry gates hosts in both the `ops.` and `app.` tiers. `cookieDomain` and the `google-sso.<domain>` callback
sit above both tiers. So no per-tier policy and no per-tier redirect URI is needed.

Every subdomain in `hosts` must sit under `domain`. The policy sets one `cookieDomain`, and a cookie reaches only
that domain and its subdomains. A host outside it never receives the id token and loops through Google forever.
So each other domain gets its own policy, see the next section.

### Adding a registrable domain

Use `extraDomains` in the same `04_google_sso/values.yaml`. Each entry gets its own `SecurityPolicy`,
`google-sso.<domain>` callback and cookie scope. You write these entries by hand. `04_values.sh` does not stamp
them, because `.env` holds one `BASE_DOMAIN` only.

```yaml
extraDomains:
  - domain: example.edu
    issuer: letsencrypt-staging   # optional, defaults to the top-level issuer
    hosts:
      - subdomain: api
        allowlist: [ops@example.edu]
```

Once per domain:

1. Add the entry above. List gated subdomains only. Leave a public `www` out.
2. Add an `ingresses[]` entry with `domain: example.edu` to the workload chart. List every host, gated or not. One
   entry holds one registrable domain, so a chart on two domains carries two entries.
3. On the same Google client, add `https://google-sso.example.edu/oauth2/callback` as a redirect URI. Add
   `example.edu` under Authorized domains. `04_google_sso.sh` prints both and needs no cluster.
4. Point DNS for each host and for `google-sso.example.edu` at `INGRESS_LB_IP`. Forward `:80` for HTTP-01.
5. Optional, for a wildcard cert: add `example.edu` to `CLOUDFLARE_WILDCARD_DOMAINS` in `.env`. Widen the zones of
   the token in Cloudflare. Run `make configure-values`. The token string stays the same, so no re-seal is needed.
   Without this step each host gets an HTTP-01 cert.
6. Commit and push.
7. Once the staging cert issues, set the `issuer` of the entry to `letsencrypt-prod`. If you did step 5, set its
   `wildcardIssuerOverrides` line too. Push again. Browsers reject a staging cert, so the host is unusable until
   you do this.

Not needed:

- a re-seal. There is one client, and the Secret is sealed to a name and namespace.
- `helm dependency update`. The ingress chart does not change.
- `make configure-values`, unless step 5 edited `.env`.

The render `fail`s on a duplicate domain, on an entry with no `domain` or no `hosts`, or on a `subdomain` that is
already a full hostname.

These parts stay on the base domain only:

- **`06_platform_ingress` and `sample_user_manager` values**: do not put another domain there. `04_values.sh`
  rewrites `domain` on every `ingresses[]` item in them. The next `make configure-values` overwrites your domain
  with no warning. Other charts are safe.
- **Blackbox probes**: they cover the `ops.` and `app.` tiers only, so a second domain gets no synthetic
  monitoring. A hand-added URL fails the verify step of `04_values.sh`.

### Bypassing SSO for a path (the ArgoCD webhook)

The policy attaches by route name. So the trick that leaves a whole host open also leaves a single path open: give
the path its own `HTTPRoute` with a name the policy does not target.

The Argo CD GitHub webhook works this way. `06_platform_ingress/templates/argocd-webhook-route.yaml` renders a
second route on the argocd host, on the same Gateway and listener. Its name is `argocd-<domain>-webhook`, not
`argocd-<domain>`. It matches only the Exact path `/api/webhook`:

```
argocd.D/               -> route argocd-D          (targeted by sso-D)       -> Google SSO gate
argocd.D/api/webhook    -> route argocd-D-webhook  (not in sso-D targetRefs) -> straight to argocd-server
```

Gateway API prefers the more specific path. So `/api/webhook` lands on the ungated route, and everything else on
the gated one.

This is safe for two reasons:

- Argo CD authenticates that path itself, with the GitHub HMAC signature in `webhook.github.secret`.
- The match is `type: Exact`, so only the webhook endpoint escapes SSO, never the rest of the admin API. This
  matters because the anonymous user of Argo CD is admin.

No `ReferenceGrant` is added. The existing grant of the chart, `gateway-routes-to-argocd-<domain>`, already lets
any route in `gateway` reach `argocd-server`. Setup and the secret are in
[02_gitops.md](02_gitops.md#webhook-driven-sync-and-the-poll-fallback).

The whole platform ingress uses `letsencrypt-prod`, not staging, so that the GitHub webhook SSL check trusts
`argocd.<domain>`. The `google-sso.<domain>` callback edge is separate and follows its own `issuer`.

### Adding a host or domain

| You add | Google Console | Cluster |
|---|---|---|
| a subdomain to an existing ingress | nothing, if the domain is already gated | add `{ subdomain, targetService, targetPort }` to the `hosts:` of that ingress |
| protection for a host | nothing | add a `subdomain` to the `hosts` of that domain in `04_google_sso` |
| a change to who may log in | nothing | set `SSO_ALLOWLIST` in `.env` and run `make configure-values`. Or set the `allowlist` of one host |
| another registrable domain | one more redirect URI, and its apex under "Authorized domains" | add an `extraDomains` entry, see [Adding a registrable domain](#adding-a-registrable-domain) |
| a different base domain | one redirect URI, and the apex under "Authorized domains" | set `BASE_DOMAIN` in `.env`, run `make configure-values`, then `04_google_sso.sh` |

To move to the base domain `example.org`:

1. Set `BASE_DOMAIN="example.org"` in `.env` and run `make configure-values`. Every host in every chart follows.
2. Point `google-sso.example.org` and each gated host at the router. Forward `:80` for HTTP-01.
3. In Google, add `example.org` under Authorized domains. Add `https://google-sso.example.org/oauth2/callback` as a
   redirect URI.
4. Run `lib/shell/04_google_sso.sh`. It prints the URIs, writes `clientID` and re-seals the secret. Commit and push.
5. Set `issuer` to `letsencrypt-prod` once the staging callback cert issues.

### Allowlists central, only the client secret sealed

The Envoy Gateway `authorization` takes allowed emails as inline literals. It cannot read them from a Secret.

- So the emails live under `allowlist` in `04_google_sso/values.yaml`.
- `04_values.sh` writes them there from `SSO_ALLOWLIST` in `.env`.
- To change access, run `make configure-values`, then push. No script prompts for emails.

Only the OAuth client secret is sealed, see [03_secrets.md](03_secrets.md).

### Fail-closed until sealed

Until you run `04_google_sso.sh` and commit the sealed client secret, the policy references a missing Secret. The
placeholder `clientID` denies everyone. A half-configured policy never leaks access. Run the script first.

### Apply and verify

1. Put `GOOGLE_SSO_CLIENT_ID` and `GOOGLE_SSO_CLIENT_SECRET` in the gitignored `.env`. Run
   `lib/shell/04_google_sso.sh`, which needs the cluster for `kubeseal`. It reads the domains from
   `04_google_sso/values.yaml`, prints the redirect URIs, writes `clientID`, and seals the secret. Edit the `hosts`
   list and the `allowlist` by hand.
2. Register each printed redirect URI on the one OAuth client. Add each apex under "Authorized domains". Publish
   the consent screen. In "Testing" mode only listed test users can log in, whatever the allowlist says.
3. Commit and push. Argo CD applies `04_google_sso` at wave 4. The app routes that the policy targets may not exist
   until their own charts sync. Envoy Gateway attaches the policy when they appear.

Checks:

- `kubectl -n gateway get securitypolicy` shows one `sso-<domainslug>` per domain with `Accepted=True`. If it is
  not Accepted, the client-secret Secret is missing. Run the script and push.
- Browse a gated host. You get the Google login and a bounce through `google-sso.<domain>`. An account on the
  allowlist reaches the app, and an account off it is denied. The open control host loads with no login.
- `CSRF token validation failed` on login means the same policy does not cover the app route and the callback.
  Check that its subdomain is in `hosts`, so the policy targets it, and that the route name matches.
