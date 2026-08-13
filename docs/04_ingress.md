# 07: Ingress, TLS and SSO

The GitOps L7 ingress layer, delivered entirely by ArgoCD. Five pieces stack in wave order:

| Wave | App | Role |
|---|---|---|
| 1 | `01_envoy_gateway` | the Gateway API data plane |
| 2 | `02_cert_manager` | issues the X.509 certs |
| 3 | `03_gateway` | the shared `:80` Gateway + the Let's Encrypt ClusterIssuers |
| 4 | `04_google_sso` | the one SecurityPolicy: which hosts are gated, and by whom |
| 6 | `06_platform_ingress` | the platform UIs' edges |

Together they terminate TLS and route and authenticate every ingress host on one pinned LoadBalancer IP. Cilium
([01_networking.md](01_networking.md)) stays the CNI and LB-IPAM provider; only the gateway lives here.

The repeated edge shape (per host a Gateway, HTTPRoute and ReferenceGrant, plus one multi-SAN `Certificate` per
ingress) is rendered once by the shared `ingress` chart in `lib/helm/ingress/`. Envoy Gateway's `mergeGateways`
folds every host's Gateway onto one Envoy and one LoadBalancer Service, so the cluster keeps a single ingress
point on the pinned IP while each ingress is just a values list of hosts.

SSO is NOT part of the edge. It is applied centrally by `04_google_sso`, so charts declare plain edges
and know nothing about SSO.

## Envoy Gateway

Cilium can serve Gateway API, but has no per-route auth hook. Envoy Gateway ships a `SecurityPolicy` CRD with
`targetSelectors` (label-based attachment) and native `oidc`, `jwt` and `authorization`. That single capability,
where labelling a route makes it SSO-protected with no per-host proxy, is worth swapping the data plane for.
Cilium keeps CNI, WireGuard, L2 announcements and LB-IPAM.

Pure GitOps, no imperative script:

- `argo_apps/platform/apps/templates/01_envoy_gateway.yaml`: the Application, wave 1.
- `argo_apps/platform/charts/01_envoy_gateway/`: the controller (upstream `gateway-helm`), the `eg`
  `GatewayClass`, and an `EnvoyProxy` that pins the LB IP.
- A one-line flip in `00_cilium/values.yaml` (`gatewayAPI.enabled: false`) plus removal of the vendored Gateway
  API CRDs.

### Envoy Gateway owns the Gateway API CRDs

`cilium.gatewayAPI.enabled: false` drops the `cilium` `GatewayClass` and Cilium's gateway controller.
`gateway-helm` vendors the Gateway API CRDs at a newer version than the ones Cilium vendored, so we remove
`00_cilium/crds/gateway.networking.k8s.io_*.yaml` and let Envoy Gateway be the single owner.

The handover is safe because Envoy Gateway re-applies the same CRDs via ServerSideApply and takes over ArgoCD
ownership of them, so they stay in the cluster's desired state as ownership moves off Cilium's app. The safety
rests on that transfer, NOT on Cilium refusing to prune: Cilium's app runs `prune: true`.

The ordering matters downstream. Envoy Gateway installs the CRDs at wave 1, before cert-manager's
`enableGatewayAPI` at wave 2 wants them present.

### One Envoy, one pinned LB IP

Each app owns its own Gateway with a single `:443` listener; `shared-gateway` keeps only the `:80` HTTP listener.

By default Envoy Gateway spawns one Envoy Deployment and one LoadBalancer Service PER Gateway, handing out a
fresh external IP per app. `mergeGateways: true` on the `EnvoyProxy` collapses every `eg`-class Gateway onto a
single Envoy Deployment and Service, so the per-app split still presents one ingress point on one IP.

That IP is pinned solely by the `EnvoyProxy` provider annotation `lbipam.cilium.io/ips`, written from `.env`
`INGRESS_LB_IP` by `04_values.sh`. Per-Gateway `spec.addresses` is dropped everywhere, because multiple Gateways
asserting an address on the one merged Service would conflict. It must stay inside the LB-IPAM pool, which
`04_values.sh` enforces, and it is the IP your router forwards to, so keep it stable.

### Cutover: free the pinned IP

Cilium's old gateway controller created `cilium-gateway-shared-gateway`, a LoadBalancer holding `.10`. With
Cilium's gateway controller disabled nothing reconciles that Service, so it can linger and hold the IP, blocking
Envoy Gateway's new Service from getting it.

Flipping `mergeGateways` similarly makes Envoy Gateway tear down its old per-Gateway data-plane Services and
recreate one merged Service (`envoy-gateway-system/envoy-eg-<hash>`), so a stale per-Gateway Service can also hold
the IP.

After the change, verify exactly one `LoadBalancer` Service holds the pinned IP. If an orphan still holds it,
delete it so LB-IPAM reassigns, e.g. `kubectl -n gateway delete svc cilium-gateway-shared-gateway`. One-off, at
apply time only.

### Proxy metrics and per-route HTTP alerts

The merged proxy serves Prometheus stats on `:19001/stats/prometheus`, on by default with no `EnvoyProxy`
`telemetry` config needed. A PodMonitor (`01_envoy_gateway/templates/podmonitor.yaml`) scrapes it so `envoy_*`
reaches VictoriaMetrics.

Envoy's upstream-cluster stats are labelled `envoy_cluster_name="httproute/<gw-ns>/<route>/rule/N"`, one cluster
per HTTPRoute rule, so the `ingress-http` Grafana alerts (5xx and 4xx rate, p95 latency, no-healthy-upstream,
connect failures) are per route with no extra config. See [06_monitoring.md](06_monitoring.md).

### The `ingress-http` dashboard

`05_grafana/files/dashboards/ingress-http.json`, uid `ingress-http`. Same metrics as the alerts, five rows:
per-route rate/errors/latency, backend health, edge listeners, and the Google SSO handshake.

This is where cluster HTTP observability lives, NOT in Hubble. Hubble's L7 HTTP metrics need `httpV2` plus an
L7 `http` rule in a CiliumNetworkPolicy to pull matched traffic through the Envoy L7 proxy, which for the
ingress path means a second proxy hop to recount what the edge already counts. `httpV2` stays off, and Cilium's
bundled "L7 HTTP metrics by workload" dashboard stays out of Grafana with it. See
[01_networking.md](01_networking.md).

Three things about these metrics that read as bugs and are not:

- A route's request counters only exist after its FIRST request. An idle route is absent, not zero, which is why
  the route dropdown reads `envoy_cluster_membership_healthy` (always present, one series per configured route)
  instead of a request counter.
- The listener row counts everything that arrived at `:80`/`:443`, including the HTTPS redirect and every SSO
  bounce that never reaches a backend, so it is always higher than the per-route rows. The route dropdown does
  not filter it.
- `oauth_unauthorized_rq` climbing is normal: that is a logged-out browser with no session cookie being sent to
  Google. `oauth_failure` is the one that matters.

The SSO panels match on the metric NAME (`envoy_securitypolicy_.+_oauth_.*`), because Envoy builds one metric
family per SecurityPolicy and puts the policy's namespace and name in the metric name rather than a label.
Renaming or adding a policy would silently empty a hardcoded query.

### Verify

```bash
kubectl get gatewayclass eg                       # ACCEPTED=True
kubectl -n gateway get gateway shared-gateway     # PROGRAMMED=True, address 192.168.100.10
kubectl -n envoy-gateway-system get pods          # controller Running; envoy-* appears once a Gateway is programmed
```

## cert-manager

Issues and renews the X.509 certs behind the `:443` listeners. This step installs the CONTROLLER only: no
`Issuer` or `ClusterIssuer` ships here, because those need a domain, public reachability, and a staging-vs-prod
decision settled first. cert-manager is independently useful, so it lands on its own.

Pure GitOps, a plain wave-2 leaf:

- `argo_apps/platform/apps/templates/02_cert_manager.yaml`: the Application, wave 2.
- `argo_apps/platform/charts/02_cert_manager/`: the wrapper chart, pinning cert-manager from
  `charts.jetstack.io`, all config under the `cert-manager:` key.

### CRDs installed by the chart, kept on prune

`values.yaml` sets `crds.enabled: true` so the chart owns and installs them, plus `crds.keep: true`. The
Application runs `prune: true`, and `keep` matters because a prune that removed a CRD would cascade-delete every
`Certificate`, `Issuer` and `Order` depending on it.

Cilium's app has no such guard; its gateway CRDs are instead kept safe by Envoy Gateway owning and re-applying
them, as above. `ServerSideApply=true` because the CRDs are too big for client-side apply's manifest annotation.
Runs in its own namespace (`CreateNamespace=true`).

### Wave 2, with nic-keeper and sealed-secrets

cert-manager, nic-keeper ([https://github.com/yama6a/talos-raspberry-pi5-cluster/blob/main/docs/03_operating_system.md](https://github.com/yama6a/talos-raspberry-pi5-cluster/blob/main/docs/03_operating_system.md)) and sealed-secrets
([03_secrets.md](03_secrets.md)) are independent leaves, so they share wave 2: the "after the CNI and ArgoCD are
in place" slot.

### Verify

```bash
kubectl -n cert-manager get pods          # controller / webhook / cainjector Running
kubectl get crd | grep cert-manager.io    # the CRDs are present
```

Optional smoke test with no external deps: apply a `selfSigned` `Issuer` and a `Certificate` in a throwaway
namespace, watch `READY=True`, then delete the namespace.

## Shared Gateway and ClusterIssuers

The ACME ingress platform: the `shared-gateway` `:80` HTTP listener, which is the cert-issuance entry point, and
the Let's Encrypt ClusterIssuers that solve HTTP-01 through it. This chart owns no apps and no `:443` listeners;
every HTTPS host lives on its own per-app Gateway, all merged onto the one Envoy.

- `argo_apps/platform/apps/templates/03_gateway.yaml`: the Application, wave 3.
- `argo_apps/platform/charts/03_gateway/`: the `:80` Gateway plus the ClusterIssuers.
- A one-line `enableGatewayAPI: true` in `02_cert_manager/values.yaml`.
- `lib/shell/04_values.sh`: writes `.env`'s `LE_EMAIL` into `acme.email` and propagates
  `CLOUDFLARE_WILDCARD_DOMAINS` into `acme.cloudflare.zones` here AND the ingress chart's `cloudflareZones`.
  Values only, no cluster access, so it runs early at bootstrap step 7, before ArgoCD. Non-interactive; commit
  the rewritten files. Writes go through `ys_set`/`ys_set_list`, not `yq -i`: see 02_gitops.md.
- `lib/shell/04_cloudflare_token.sh`: seals `CLOUDFLARE_API_TOKEN_SECRET` into `cert-manager`. Split out because
  sealing needs the live sealed-secrets controller, so it runs AFTER ArgoCD is up. `make
  configure-cloudflare-token`. Skips and cleans up if the token is empty.

### The `:80` ACME listener, the HTTP-01 fallback

`shared-gateway` owns just the `:80` HTTP listener: no cert, no `:443`. It serves cert-manager's HTTP-01 solver
routes, since the ClusterIssuers point at it by name, and the future forced http-to-https redirect. With no cert
refs it is Programmed immediately, independent of any app.

HTTP-01 is the fallback for any domain not on Cloudflare. Those hosts get a `:443` listener PER HOST, because
HTTP-01 cannot do wildcards, living on the per-host Gateways rather than here. For an HTTP-01 domain each ingress
issues ONE multi-SAN cert covering all its hosts, and its listeners sit not-Ready until that cert issues. So hosts
within an ingress are coupled, and a single failing SAN blocks them together, but different ingresses are
independent and none blocks the platform's `:80`.

### Staging then prod ClusterIssuers

Both `letsencrypt-staging` and `letsencrypt-prod` ship, cluster-scoped. Always validate a new host against
staging first, because prod's rate limits are tight, then flip that host's `Certificate` issuer to prod, or for
the shared wildcards flip `acme.cloudflare.wildcardIssuer`.

Each issuer's HTTP-01 solver is `gatewayHTTPRoute` with `parentRefs` to `shared-gateway`. When Cloudflare zones
are configured each issuer ALSO gets a `dns01.cloudflare` solver, and cert-manager picks per dnsName.

### Cloudflare DNS-01 and wildcards

We have Cloudflare for only some domains, so DNS-01 is optional and per-domain. One list drives it:
`CLOUDFLARE_WILDCARD_DOMAINS` in `.env`, space-separated host tiers on Cloudflare, gated by
`CLOUDFLARE_API_TOKEN_SECRET` (a scoped API token, Zone:DNS:Edit + Zone:Read). Empty means DNS-01 off and HTTP-01
for everything. `04_values.sh` writes the zones into two places:

- `03_gateway`: each ClusterIssuer gets a `dns01.cloudflare` solver scoped `selector.dnsZones: <zones>` plus the
  existing `http01` catch-all. cert-manager picks the most-specific matching solver per dnsName, so names under a
  Cloudflare zone including wildcards go DNS-01 and everything else falls to HTTP-01. No new issuer names, so the
  per-ingress `issuer:` values and the chart's issuer allowlist are untouched. `03_gateway` also mints ONE shared
  wildcard `Certificate` per zone (`*.<zone>` plus apex, into `wildcard-<zone-dashed>-tls`, at
  `acme.cloudflare.wildcardIssuer`), reusable across every ingress on that tier.
- The ingress chart (`cloudflareZones`): an ingress whose `domain` is a Cloudflare zone points its listeners at
  the shared `wildcard-<domain>-tls` and SKIPS its own per-ingress `Certificate`. Any other domain keeps the
  per-host multi-SAN HTTP-01 cert. Automatic and per-domain, with no per-ingress flag.

Wildcards match one label only, so we mint per tier (`*.ops.<base>`, `*.app.<base>`, `*.<base>`), not a single
`*.<base>`.

cert-manager runs a DNS self-check before validation. It is pointed at public resolvers
(`dns01RecursiveNameservers` in `02_cert_manager`) so a split-horizon home DNS cannot wedge issuance, and its
NetworkPolicy allows egress on `:53` and `:443` to the world for the Cloudflare API and that check.

After changing the ingress chart you must re-vendor its consumers with `helm dependency update` per consumer.
`04_values.sh` prints the exact loop.

### Enabling Gateway API in cert-manager

HTTP-01-via-Gateway needs cert-manager to manage `HTTPRoute`s. That is the controller file config
`config.enableGatewayAPI: true`, NOT a feature gate, set under the `cert-manager:` key. The Gateway API CRDs must
exist before the controller starts; they do, because Envoy Gateway installs them at wave 1. If you ever install
the CRDs after cert-manager, restart its Deployment.

### Verify

```bash
kubectl -n gateway get gateway            # shared-gateway PROGRAMMED=True, plus one per host, all on the pinned IP
kubectl get svc -n envoy-gateway-system   # one Envoy LoadBalancer (envoy-eg-<hash>) holding the pinned IP
kubectl get clusterissuer                 # letsencrypt-staging + letsencrypt-prod both READY=True
```

## The shared ingress chart

The per-host edge lives in ONE `type: application` chart, `lib/helm/ingress/`, instead of being hand-copied into
every app chart. For a list of `ingresses[]`, each a group of subdomains under one `domain`, it renders:

- A Gateway, HTTPRoute and ReferenceGrant per host. ReferenceGrants only for cross-namespace backends.
- For a non-Cloudflare domain, ONE multi-SAN `Certificate` per ingress covering all its hosts, into one shared
  Secret every listener references.
- For a Cloudflare domain, nothing: the listeners point at the shared `wildcard-<domain>-tls` minted by
  `03_gateway`.
- No SSO. That is central in `04_google_sso`.

The cluster wiring (gateway namespace `gateway`, gateway class `eg`, fallback issuer) is hardcoded, NOT a
per-consumer value, because those are platform invariants. A consumer's only cert knob is `ingresses[].issuer`.

Consumers are thin: a `file://` dependency and an `ingress:` values block, with NO template of their own. Being
`file://`-only they are lockless and gitignore their `Chart.lock`. The one exception is `04_google_sso`, which
builds its callback hosts by calling the `ingress.renderIngress` named template inline, interleaved with its own
SecurityPolicy, so it carries the dependency but keeps its own template.

Consumers today: `06_platform_ingress`, each workload chart, and `04_google_sso`.

Each ingress declares exactly one registrable `domain`, and every host gives a `subdomain` under it, so the host
is `<subdomain>.<domain>` and `subdomain: "@"` means the apex. The chart `fail`s the render, so ArgoCD reports it
and nothing applies, if an ingress has no `domain`, a host has no `subdomain`, or a `subdomain` looks like a full
hostname because it already ends with the domain. That last one is the classic copy-paste slip. Per-host resource
names derive from the full host, with dots turned to dashes.

Two tiers under the one base domain: platform UIs under `*.ops.<base>` and workloads under `*.app.<base>`. Each is
still one registrable `domain` from the chart's point of view, so without Cloudflare they get separate
per-ingress multi-SAN certs, and with Cloudflare each tier gets one shared `*.<tier>` wildcard reused across its
ingresses. SSO keeps them under a single `example.com` entry, below.

## Google SSO

One policy for the domain, gating a listed set of hosts. Google login plus a per-host email allowlist, applied CENTRALLY
in `argo_apps/platform/charts/04_google_sso` (wave 4). Per domain it renders one Envoy Gateway `SecurityPolicy`
that `targetRefs` the domain's shared callback route AND every gated app route, plus the shared
`google-sso.<domain>` callback host, a tiny whoami, and the sealed OAuth client secret.

Why one policy per domain rather than per app, which is the constraint that shapes all of this: Envoy's OAuth2
filter signs its CSRF-nonce cookie under a name suffixed per SecurityPolicy (`OauthNonce-<hash>`), and Envoy
Gateway gives no way to pin it. So the login handshake only completes if the SAME policy both starts the flow on
the app host and finishes it on the callback host. A shared callback host with separate per-app policies fails
with `CSRF token validation failed`.

Hence one policy per domain covering the app routes and the callback route, giving one cookie identity, so the
flow completes. `cookieDomain: <domain>` then lets the nonce set on `grafana.<domain>` be read when the callback
lands on `google-sso.<domain>`, since they share a registrable domain.

Per-host allowlists live in that one policy. Authorization is a list of rules, and each rule ANDs a host match
(`principal.headers` on the `:authority` request header) with the email claim, so different hosts get different
allowlists. `defaultAction: Deny`, so a host with no rule, including the callback whoami, is denied. The
`/oauth2/callback` path is handled by the `oidc` filter BEFORE authorization, so login still works.

```
argocd.D (no session) -> [sso-D policy: oidc] 302 to Google -> callback to google-sso.D/oauth2/callback
                      -> [SAME sso-D policy] validates nonce, exchanges code, sets id-token cookie (.D) -> back to argocd.D
argocd.D (with cookie)-> [sso-D: oidc] pass -> [jwt] validate -> [authz] :authority==argocd.D AND email allowlisted? -> backend
```

Google needs exactly ONE redirect URI per domain (`google-sso.<domain>/oauth2/callback`). One OAuth client, a
`clientID` plus one sealed `client-secret`, serves everything.

### Workloads configure nothing SSO

A chart declares only its ingress: domain, hosts and backends. Plain edges. Which hosts are protected, and by
whom, is the central `hosts` list in `04_google_sso/values.yaml`:

```yaml
domain: example.com        # written by 04_values.sh from .env BASE_DOMAIN
issuer: letsencrypt-prod
allowlist:                 # written by 04_values.sh from .env SSO_ALLOWLIST
  - you@example.com
hosts:
  - subdomain: argocd.ops                    # a platform UI
  - subdomain: sample-user-manager-sso.app   # a workload host, gated centrally
```

Each `subdomain` composes against `domain` into the FQDN its ingress renders. The policy `targetRefs` that host's
route by name, using the full host with dots turned to dashes, so it attaches to routes created by ANY chart. To
protect a host, add its subdomain here; its route exists wherever its ingress lives. A host not listed stays
open. `sample-user-manager.app.example.com` is the open control, not listed; `sample-user-manager-sso.app` is
listed and therefore gated.

ONE domain, deliberately. It gates hosts across both the `ops.` and `app.` tiers, because `cookieDomain` and the
`google-sso.<domain>` callback are a parent of each, so no per-tier policy or redirect-URI split is needed. Every
subdomain MUST sit under `domain`: the policy sets one cookieDomain, and a cookie only ever reaches that domain
and its subdomains, so a host outside it never receives the id token and loops through Google forever.

### Bypassing SSO for a path (the ArgoCD webhook)

Because the policy attaches by route name, the same trick that leaves a whole host open also leaves a single PATH
open: give it its own `HTTPRoute` with a name the policy does not target.

That is how the ArgoCD GitHub webhook works. `06_platform_ingress/templates/argocd-webhook-route.yaml` renders a
second route on the argocd host, same Gateway and listener, but named `argocd-<domain>-webhook` rather than
`argocd-<domain>`, matching only the Exact path `/api/webhook`:

```
argocd.D/               -> route argocd-D          (targeted by sso-D)       -> Google SSO gate
argocd.D/api/webhook    -> route argocd-D-webhook  (NOT in sso-D targetRefs) -> straight to argocd-server
```

Gateway API prefers the more-specific path, so `/api/webhook` lands on the ungated route and everything else on
the gated one.

Safe because ArgoCD authenticates that path itself via the GitHub HMAC signature (`webhook.github.secret`), and
the match is `type: Exact` so ONLY the webhook endpoint escapes SSO, never the rest of the admin API. That last
part matters here, since ArgoCD's anonymous user is admin. No `ReferenceGrant` is added: the chart's existing
`gateway-routes-to-argocd-<domain>` grant already allows any route in `gateway` to reach `argocd-server`. Setup
and the secret live in [02_gitops.md](02_gitops.md#webhook-driven-sync-and-the-poll-fallback).

The whole platform ingress is on `letsencrypt-prod`, not staging, precisely so GitHub's webhook SSL verification
trusts `argocd.<domain>`. The `google-sso.<domain>` callback edge is separate and follows its own `issuer`.

### Adding a host or domain

| You add | Google Console | Cluster |
|---|---|---|
| a subdomain to an existing ingress | nothing, if the domain is already gated | add `{ subdomain, targetService, targetPort }` to that ingress's `hosts:` |
| protection for a host | nothing | add a `subdomain` to `04_google_sso` `hosts` |
| change who may log in | nothing | set `SSO_ALLOWLIST` in `.env`, run `make configure-values` |
| a different base domain | one redirect URI, plus the apex under "Authorized domains" | set `BASE_DOMAIN` in `.env`, run `make configure-values`, then `04_google_sso.sh` |

Moving to a base domain `example.org`:

1. Set `BASE_DOMAIN="example.org"` in `.env` and run `make configure-values`. Every host in every chart follows.
2. Point `google-sso.example.org` and each gated host at the router, with the `:80` forward for HTTP-01.
3. In Google, add `example.org` under Authorized domains and
   `https://google-sso.example.org/oauth2/callback` as a redirect URI.
4. Run `lib/shell/04_google_sso.sh`, which prints the URIs, writes `clientID` and re-seals the secret. Commit and
   push.
5. Flip `issuer` to `letsencrypt-prod` once the staging callback cert issues.

### Allowlists central, only the client secret sealed

Envoy Gateway's `authorization` takes allowed emails as inline literals and cannot read them from a Secret, so
they live in `04_google_sso/values.yaml` under `allowlist`, written there from `.env` `SSO_ALLOWLIST` by
`04_values.sh`. Change access with `make configure-values` then push; no script prompts for them. Only the OAuth client secret is sealed, see
[03_secrets.md](03_secrets.md).

### Fail-closed until sealed

Until `04_google_sso.sh` seals the client secret and you commit it, the policy references a missing Secret and the
placeholder `clientID` denies everyone. A half-configured policy never leaks access. Run the script first.

### Apply and verify

1. Put `GOOGLE_SSO_CLIENT_ID` and `GOOGLE_SSO_CLIENT_SECRET` in the gitignored `.env`, then run
   `lib/shell/04_google_sso.sh`, which needs the cluster for `kubeseal`. It reads the domains from
   `04_google_sso/values.yaml`, prints the redirect URIs, writes `clientID`, and seals the secret. Edit the
   `hosts` list and the `allowlist` by hand.
2. Register each printed redirect URI on the one OAuth client, and add each apex under "Authorized domains".
   Publish the consent screen: in "Testing" only listed test users log in, regardless of the allowlist.
3. Commit and push. ArgoCD applies `04_google_sso` at wave 4. The app routes it targetRefs may not exist until
   their own charts sync, and Envoy Gateway attaches the policy when they appear.

Checks:

- `kubectl -n gateway get securitypolicy` shows one `sso-<domainslug>` per domain with `Accepted=True`. Not
  Accepted means the client-secret Secret is missing, so run the script and push.
- Browse a gated host: Google login, bounce through `google-sso.<domain>`, and an account on the allowlist
  reaches the app while one off it is denied. The open control host loads with no login.
- Login failing with `CSRF token validation failed` means the app route is not covered by the same policy as the
  callback. Confirm its subdomain is in `hosts` so the policy targetRefs it, and that the route name matches.
