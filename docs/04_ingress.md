# Ingress, TLS and SSO

Procedures are in [runbooks/04_ingress.md](runbooks/04_ingress.md).

Argo CD delivers the L7 ingress layer as five apps, in wave order:

| Wave | App | Role |
|---|---|---|
| 1 | `01_envoy_gateway` | the Gateway API data plane |
| 2 | `02_cert_manager` | issues the X.509 certs |
| 3 | `03_gateway` | the shared `:80` Gateway and the Let's Encrypt ClusterIssuers |
| 4 | `04_google_sso` | one SecurityPolicy per domain: which hosts are gated, and who may log in |
| 6 | `06_platform_ingress` | the edges of the platform UIs |

Together they terminate TLS, then route and authenticate every host on one pinned LoadBalancer IP. Cilium stays the
CNI and the LB-IPAM provider, see [01_networking.md](01_networking.md). LB-IPAM is the Cilium allocator for
LoadBalancer IPs.

- **Edge**: the objects that expose one host. Per host a Gateway, an HTTPRoute and a ReferenceGrant. Per ingress
  one multi-SAN `Certificate`, a single cert that lists every host of that ingress.
- **Rendering**: the shared `ingress` chart in `lib/helm/ingress/` renders every edge.
- **SSO**: not part of the edge. `04_google_sso` applies it centrally, so charts declare plain edges and know
  nothing about SSO.

## Envoy Gateway

Cilium can serve Gateway API but has no per-route auth hook. Envoy Gateway ships a `SecurityPolicy` CRD with native
`oidc`, `jwt` and `authorization`, attached to routes by name or label. So one policy puts any route behind SSO,
with no proxy per host. That is the reason Envoy Gateway is the data plane.

- Cilium keeps the CNI, WireGuard, L2 announcements and LB-IPAM. `gatewayAPI.enabled: false` in `00_cilium` turns
  its gateway controller off.
- Envoy Gateway owns the Gateway API CRDs. It installs them at wave 1, before cert-manager needs them at wave 2.

### One Envoy, one pinned LB IP

By default Envoy Gateway creates one Envoy and one LoadBalancer Service per Gateway, so each app would get its own
external IP. `mergeGateways: true` puts every Gateway on one Envoy and one Service instead.

- Each app keeps its own Gateway with its own `:443` listener.
- The cluster keeps one ingress point. Your router forwards to that IP, so keep it stable.
- The IP comes from `INGRESS_LB_IP` in `.env` and must sit inside the LB-IPAM pool.

### HTTP observability at the edge

Per-route HTTP metrics and the `ingress-http` alerts come from the Envoy proxy stats, with no extra config. See
[06_monitoring.md](06_monitoring.md).

Hubble's L7 HTTP metrics stay off. They need an L7 `http` rule in a CiliumNetworkPolicy, which pulls traffic through
the Cilium Envoy proxy. On the ingress path that adds a second proxy hop that counts what the edge already counts.

Three things on the `ingress-http` dashboard look like bugs but are correct:

- **Idle routes are absent.** A route has request series only after its first request. So the route dropdown reads
  `envoy_cluster_membership_healthy`, which has one series per configured route.
- **The listener row counts more than the route rows.** It also counts every SSO bounce that never reaches a
  backend.
- **`oauth_unauthorized_rq` climbs.** Each count is a logged-out browser that Envoy sends to Google. Watch
  `oauth_failure` instead.

The SSO panels match `envoy_securitypolicy_.+_oauth_.*` by metric name. Envoy puts the policy name into the metric
name, not a label. A hardcoded query goes empty with no error when a policy is renamed or added.

## cert-manager

cert-manager issues and renews the certs behind the `:443` listeners. `02_cert_manager` installs the controller only.
The ClusterIssuers need a domain, public reachability and a choice between staging and prod, so `03_gateway` ships
them.

## Shared Gateway and ClusterIssuers

`03_gateway` holds the ACME side of ingress. ACME is the protocol Let's Encrypt uses to issue certs.

- `shared-gateway` has only the `:80` HTTP listener, where HTTP-01 challenges enter. It has no cert, so it is
  Programmed at once and no app can block it.
- Two ClusterIssuers ship: `letsencrypt-staging` and `letsencrypt-prod`. Prod has tight rate limits, so every new
  host starts on staging. The ingress chart defaults to staging.

### HTTP-01 is the fallback

A domain not on Cloudflare uses HTTP-01. HTTP-01 cannot issue wildcards, so each ingress gets one multi-SAN cert for
all its hosts. Its listeners stay not-Ready until that cert issues:

- the hosts of one ingress share a fate. One failing SAN blocks all of them.
- different ingresses do not affect each other.
- no ingress blocks the platform `:80` listener.

### Cloudflare DNS-01 and wildcards

Only some domains are on Cloudflare, so DNS-01 is optional and set per domain. `CLOUDFLARE_WILDCARD_DOMAINS` in
`.env` lists the host tiers on Cloudflare. A tier is a domain level that holds hosts, such as `ops.example.com`. An
empty list turns DNS-01 off.

- Each ClusterIssuer gets a `dns01.cloudflare` solver for the listed zones, next to the `http01` catch-all.
  cert-manager picks the most specific solver per name. The issuer names stay the same, so no ingress changes.
- `03_gateway` mints one shared wildcard cert per zone, `*.<zone>` plus the apex. Every ingress on that zone reuses
  it and skips its own `Certificate`.
- A wildcard matches one label only. So the repo mints one per tier, such as `*.ops.<base>` and `*.app.<base>`, not
  a single `*.<base>`.

The cost: one Secret backs every listener on a zone. A wildcard that never issues takes down the whole zone at once.
The usual cause is a zone the API token has no `Zone:DNS:Edit` on.

## The shared ingress chart

`lib/helm/ingress/` renders the edge of every host, so app charts do not copy the edge by hand. A consumer is a
`file://` dependency plus an `ingress:` values block. Consumers: `06_platform_ingress`, each workload chart, and
`04_google_sso`. The input format is in [`values.yaml`](../lib/helm/ingress/values.yaml).

- The gateway namespace, gateway class and fallback issuer are hardcoded. They are platform invariants, not
  per-consumer values.
- Each ingress holds exactly one registrable `domain`. Per-host resource names come from the full host, so hosts never
  collide across domains.
- The base domain has two tiers: platform UIs under `*.ops.<base>` and workloads under `*.app.<base>`. With
  Cloudflare each tier gets one wildcard. SSO covers both tiers with one entry, see [Google SSO](#google-sso).

### Redirect hosts

A host sets either a backend or `redirectTo`. The main use is apex to www.

- **301, not 308**: the targets are canonical hostnames that browsers and search engines should cache for good.
- **Full edge**: a redirect host still gets its own Gateway, `:443` listener and cert SAN. Without them the TLS
  handshake fails before Envoy can send the redirect.

### Request headers

`requestHeaders` sets headers on the request to the backend. It exists for `X-Forwarded-Port`:

- Envoy sends `x-forwarded-proto` but not `x-forwarded-port`. A framework that builds absolute URLs then falls back
  to its own listen port, and redirects point at a port that is not public.
- Next.js is the known case. Traefik sets this header, so an app that worked behind Traefik breaks only behind Envoy.

## Google SSO

`04_google_sso` (wave 4) applies Google login centrally, with an email allowlist per host. Per domain it renders one
`SecurityPolicy`, the shared callback host `google-sso.<domain>`, and a small whoami backend for that host.

### One policy per domain

One policy per domain, not one per app. This constraint shapes the whole design:

- The Envoy OAuth2 filter names its CSRF nonce cookie with a per-policy suffix, and Envoy Gateway cannot pin it.
- So the login completes only if the same policy starts the flow on the app host and finishes it on the callback
  host. Separate per-app policies fail with `CSRF token validation failed`.
- `cookieDomain: <domain>` lets the callback on `google-sso.<domain>` read the nonce set on the app host.

Per-host allowlists live in that one policy. Each authorization rule ANDs a host match with the email claim, and
`defaultAction: Deny` denies any host with no rule.

```
argocd.D (no session) -> [sso-D policy: oidc] 302 to Google -> callback to google-sso.D/oauth2/callback
                      -> [same sso-D policy] validates nonce, exchanges code, sets id-token cookie (.D) -> back to argocd.D
argocd.D (with cookie)-> [sso-D: oidc] pass -> [jwt] validate -> [authz] :authority==argocd.D AND email allowlisted? -> backend
```

Google needs one redirect URI per domain, `google-sso.<domain>/oauth2/callback`. One OAuth client serves every
domain.

A cookie reaches only its domain and subdomains. So every gated host must sit under the policy domain, and each
other registrable domain gets its own policy through `extraDomains`.

### Session length

A session lasts `sessionTTL`, 24h, not the 1h of the Google id token. Envoy renews the id token with a refresh token.
Google issues one only with `access_type=offline` and `prompt=consent`, so the policy pins both. The cost is one
confirm click per login.

### Workloads configure no SSO

A chart declares only its ingress. The central `hosts` list in `04_google_sso/values.yaml` sets which hosts are gated
and for whom. The policy targets routes by name, so it attaches to routes that any chart creates. A host not listed
stays open.

### Allowlists in values, only the client secret sealed

Envoy Gateway `authorization` takes allowed emails as inline literals and cannot read them from a Secret. So the
emails live in `values.yaml`, written from `SSO_ALLOWLIST` in `.env`. Only the OAuth client secret is sealed, see
[03_secrets.md](03_secrets.md).

Until the sealed client secret exists, the policy references a missing Secret and the placeholder `clientID` denies
everyone. A half-configured policy never leaks access.

### Bypassing SSO for a path (the ArgoCD webhook)

The policy attaches by route name. So a path gets past SSO when it has its own `HTTPRoute` with a name the policy
does not target. The Argo CD GitHub webhook uses this:

```
argocd.D/               -> route argocd-D          (targeted by sso-D)       -> Google SSO gate
argocd.D/api/webhook    -> route argocd-D-webhook  (not in sso-D targetRefs) -> straight to argocd-server
```

This is safe for two reasons:

- Argo CD checks the GitHub HMAC signature on that path itself.
- The match is `type: Exact`, so only the webhook endpoint skips SSO. The anonymous Argo CD user is admin, so a wider
  match would expose the admin API.

Setup and the secret are in [02_gitops.md](02_gitops.md#webhook-driven-sync-and-the-poll-fallback).
