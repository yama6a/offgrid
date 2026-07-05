# 07: Ingress, TLS & SSO

The GitOps L7 ingress layer, delivered entirely by ArgoCD. Components stack in wave order: Envoy
Gateway (the Gateway API data plane), cert-manager (issues the X.509 certs), the shared Gateway +
Let's Encrypt ClusterIssuers (the ACME ingress platform), the central **Google-SSO** (one policy per
domain, wave 4), and the **platform ingress** edges (wave 8). Together they terminate TLS and
route/authenticate every ingress host on one pinned LoadBalancer IP. Cilium
([04_networking.md](04_networking.md)) stays the CNI and LB-IPAM provider; only the gateway lives here.

The repeated **edge** shape — per host a Gateway + HTTPRoute + ReferenceGrant, one multi-SAN `Certificate`
per ingress — is rendered once by the shared `ingress-edge` library chart (`lib/helm/ingress-edge/`,
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
controller. `gateway-helm` vendors the Gateway API CRDs (v1.5.1, newer than the v1.4.1 Cilium
vendored), so we remove `argo_apps/platform/charts/00_cilium/crds/gateway.networking.k8s.io_*.yaml`
and let Envoy Gateway be the single owner. The handover is safe: Cilium's app is `prune: false`, so
dropping the CRD files never cascade-deletes the live CRDs; Envoy Gateway re-applies them via
ServerSideApply and adopts field ownership. This ordering matters downstream: Envoy Gateway
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

## cert-manager

The controller that issues and renews the X.509 certs behind the `:443` listeners, ultimately Let's
Encrypt certificates fetched and rotated automatically. This step installs the *controller only* —
no `Issuer`/`ClusterIssuer` ships here (those land in the next section, once a domain, public
reachability, and staging-vs-prod are settled). cert-manager is independently useful, so it lands on
its own.

Pure GitOps, a plain wave-2 leaf, no imperative script:

- `argo_apps/platform/apps/02_cert_manager.yaml`: the Application, sync-wave 2.
- `argo_apps/platform/charts/02_cert_manager/`: the wrapper chart (`Chart.yaml` pins cert-manager
  `v1.20.2` from `charts.jetstack.io`; all config under the `cert-manager:` key in `values.yaml`).

### CRDs installed by the chart, kept on prune
`values.yaml` sets `crds.enabled: true` (the chart owns/installs the CRDs) and `crds.keep: true`.
The Application runs `prune: true`; `keep` matters because a prune that removed a CRD would
cascade-delete every `Certificate`/`Issuer`/`Order` depending on it. Same "never cascade-delete
CRDs" posture Cilium takes (there via `prune: false`; here, more narrowly, via `crds.keep`).
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
- `lib/shell/07_gateway.sh`: writes `.env`'s `LE_EMAIL` + `BASE_DOMAIN` into the chart's
  `values.yaml` (`acme.email` + `baseDomain`) via `yq`, so the shell side and ArgoCD render the same.
  Non-interactive. Commit the rewritten `values.yaml`.

### The `:80` ACME listener only, no wildcard
`shared-gateway` owns just the `:80` HTTP listener, no cert, no `:443`. It serves cert-manager's
HTTP-01 solver routes (the ClusterIssuers point at `shared-gateway` by name) and the future forced
http->https redirect (a `RequestRedirect` HTTPRoute on this same listener). With no cert refs it's
Programmed immediately, independent of any app. HTTP-01 means a `:443` listener **per host** (no
wildcard cert — that would need DNS-01, which we don't have), but those `:443` listeners live on
the per-host Gateways, not here. Each ingress issues ONE multi-SAN cert covering all its hosts; its
listeners sit not-Ready until that cert issues (so hosts within an ingress are coupled — a single failing
SAN blocks them together), but different ingresses are independent, and none blocks the platform's `:80`.

### Staging then prod ClusterIssuers
Both `letsencrypt-staging` and `letsencrypt-prod` ship (cluster-scoped). Always validate a new host
against staging first (prod's rate limits are tight), then flip that host's `Certificate` issuer to
prod. The HTTP-01 solver is `gatewayHTTPRoute` with `parentRefs` to `shared-gateway`.

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

## The ingress-edge library

The per-host edge used to be four hand-copied templates in every app chart. It now lives in ONE
`type: library` chart, `lib/helm/ingress-edge/`, which renders — for a list of `ingresses[]`, each a
group of subdomains under one `domain` — a Gateway + HTTPRoute + ReferenceGrant per host and ONE multi-SAN
`Certificate` per ingress (covering all its hosts, into one shared Secret every listener references). It
renders **no SSO** — Google-SSO is applied centrally per domain by `04_google_sso` (below). Consumers are
thin: a `file://` dependency on the library, a one-line template (`{{ include "ingress-edge.render" . }}`),
and an `ingress-edge:` values block. See [CLAUDE.md](../CLAUDE.md) for the library-chart + `file://` +
committed-`Chart.lock` convention.

Consumers: `08_platform_ingress` (the platform UIs' edges), each workload chart, and `04_google_sso` (its
callback hosts' edges). ReferenceGrants are emitted only for cross-namespace backends.

Each ingress declares exactly one registrable `domain`; every host gives a `subdomain` under it
(host = `<subdomain>.<domain>`; `subdomain: "@"` = the apex). The library `fail`s the render (so ArgoCD
reports it, nothing applies) if an ingress has **no `domain`**, a host has **no `subdomain`**, or a
`subdomain` **looks like a full hostname** (already ends with the domain — the classic copy-paste slip).
Per-host resource names derive from the full host (`argocd.example.com` -> `argocd-example-com`).

## Google SSO — one policy per domain, per-host allowlists

Google login + a per-host email allowlist, applied **centrally** in `argo_apps/platform/charts/04_google_sso`
(wave 4). Per domain it renders ONE Envoy Gateway `SecurityPolicy` that `targetRefs` the domain's shared
callback route **and** every gated app route, plus the shared `google-sso.<domain>` callback host (edge via
the library) + a tiny whoami + the sealed OAuth client secret.

**Why one policy per domain, not per app (the constraint that shapes this).** Envoy's OAuth2 filter signs its
CSRF-nonce cookie under a name suffixed **per SecurityPolicy** (`OauthNonce-<hash>`), and EG (v1.8.1) gives no
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
  - domain: example.com
    issuer: letsencrypt-staging
    hosts:
      - host: argocd.example.com
        allowlist: [admin@…]
      - host: sample-workload-sso.example.com   # a workload host, gated centrally
        allowlist: [user@…]
```

The policy `targetRefs` each host's route **by name** (the full host, dots -> dashes — the library's naming),
so it attaches to routes created by *any* chart. To protect a host: add it here with its allowlist (its route
exists wherever its ingress lives). A host not listed stays open. `sample-workload.example.com` is the open
control (not listed); `sample-workload-sso.example.com` is listed → gated.

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
   their own charts sync (platform-ingress wave 8, workloads later); EG attaches the policy when they appear.

Checks:
- `kubectl -n gateway get securitypolicy` -> one `sso-<domainslug>` per domain (`sso-example-com`),
  `Accepted=True` (not Accepted -> the client-secret Secret is missing; run the script + push).
- Browse a gated host -> Google login -> bounce through `google-sso.<domain>` -> an account on THAT host's
  allowlist reaches the app; one off it is denied. The open control host loads with no login.
- If login fails with `CSRF token validation failed`: the app route isn't covered by the same policy as the
  callback — confirm it's in `domains[].hosts` (so the policy `targetRefs` it) and the route name matches.
