# 07: Ingress, TLS & SSO

The GitOps L7 ingress layer, delivered entirely by ArgoCD. Components stack in wave order: Envoy
Gateway (the Gateway API data plane), cert-manager (issues the X.509 certs), the shared Gateway +
Let's Encrypt ClusterIssuers (the ACME ingress platform), the Google-SSO callback plumbing, and the
consolidated **platform ingress** (wave 8). Together they terminate TLS and route/authenticate every
ingress host on one pinned LoadBalancer IP. Cilium ([04_networking.md](04_networking.md)) stays the CNI
and LB-IPAM provider; only the gateway implementation lives here.

The repeated shape — **per host a Gateway + HTTPRoute + ReferenceGrant, one multi-SAN `Certificate` per
ingress, plus an optional per-ingress SSO `SecurityPolicy`** — is rendered once by the shared `ingress-edge`
library chart (`argo_apps/_lib/ingress-edge/`, see [the wrapper-chart conventions](CLAUDE.md)); Envoy
Gateway's `mergeGateways` folds every host's Gateway onto one Envoy + one LoadBalancer Service. So the cluster
keeps a single ingress point on the pinned IP while each ingress is just a values list. An **ingress** is
a group of (sub)domains sharing one optional SSO allowlist: the platform-ingress app groups every
platform UI under one allowlist; each workload owns its ingress(es) with its own allowlist
([10_sample_workload.md](10_sample_workload.md)).

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
- `07_ingress/07_gateway.sh`: writes `.env`'s `LE_EMAIL` + `BASE_DOMAIN` into the chart's
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

## The ingress-edge library & the platform ingress

The per-host edge used to be four hand-copied templates in every app chart (argocd-ingress + each
monitoring chart + the sample workload + the callbacks), six copies in three dialects. It now lives in ONE
`type: library` chart, `argo_apps/_lib/ingress-edge/`, which renders — for a list of `ingresses[]`, each a
group of subdomains + an optional SSO allowlist — a Gateway + HTTPRoute + ReferenceGrant per host, ONE
multi-SAN `Certificate` per ingress (covering all its hosts, into one shared Secret every listener
references), and one `SecurityPolicy` per SSO-enabled ingress. Consumers are thin: a `file://` dependency on
the library, a one-line template (`{{ include "ingress-edge.render" . }}`), and an `ingress-edge:` values block.
See [CLAUDE.md](CLAUDE.md) for the library-chart + `file://` + committed-`Chart.lock` convention.

Three charts consume it: `08_platform_ingress` (the consolidated platform edge), each workload chart, and
`04_google_sso` (the callback hosts). ReferenceGrants are emitted only for cross-namespace backends, so the
same-namespace callback host gets none.

- `argo_apps/platform/apps/08_platform_ingress.yaml` (wave 8): the Application. Last wave, so every backend
  (argocd wave 1, monitoring wave 7) exists when its route is created and the SSO callback + secret (wave 4)
  are up. The route and its `SecurityPolicy` are created together, so a protected UI is never briefly exposed.
- `argo_apps/platform/charts/08_platform_ingress/values.yaml`: ONE `platform` ingress, `sso.enabled`, one
  allowlist, four hosts (argocd, grafana, vmui, vlogs). Add a platform UI = add a host here; change who may log
  in = edit the one `allowlist`. The four hosts share ONE multi-SAN cert in the `platform-tls` Secret — so on
  cutover cert-manager issues a fresh 4-name cert (the old per-UI `argocd-tls`/`grafana-tls`/… secrets are
  pruned); validate against staging first, then flip `issuer` to prod.

## Google SSO

An optional auth layer: Google login + an email allowlist, applied **per ingress**. Each ingress owns
its own list of allowed emails, so the platform UIs (one allowlist) and a workload on the *same* domain
(a different allowlist) no longer share one list. SSO is one optional block in the shared `ingress-edge`
library (see [the wrapper-chart conventions](CLAUDE.md)); enabling it on an ingress emits that ingress's
own `SecurityPolicy` alongside its routes. Proven on `sample-workload-sso.<domain>` (protected, its own
allowlist) vs `sample-workload.<domain>` (open).

Two moving parts, both GitOps, plus one secret helper:

- `argo_apps/_lib/ingress-edge/`: renders each SSO ingress's `SecurityPolicy` (`_securitypolicy.tpl`) and
  holds the shared, non-secret OIDC config (`values.yaml` `ingressEdge.oidc`: clientID, cookie names,
  TTLs, `authSubdomain`, denyRedirect) — the single place those live.
- `argo_apps/platform/charts/04_google_sso/` (wave 4): the SHARED per-domain callback hosts
  `google-sso.<domain>` (each rendered by the same library as an SSO ingress in front of one tiny shared
  whoami) + the sealed OAuth client secret.
- `07_ingress/07_google_sso.sh`: writes the shared `clientID` into the library values and seals the client
  secret. It does **not** touch allowlists (see below).

### Per-ingress policy, shared callback host
Each SSO ingress stamps `ingress-group: <ingressName>` on its `HTTPRoute`s and emits ONE `SecurityPolicy`
selecting exactly that label. The policy runs three filters at the Envoy edge: `oidc` (no session ->
302 to Google; the callback lands on `google-sso.<domain>` and sets an ID-token cookie scoped to the
domain via `cookieDomain`), `jwt` (validate the ID token against Google JWKS, read the email claim),
`authorization` (email in THIS ingress's allowlist? `defaultAction: Deny`).

```
app.D (no session) -> [app policy: oidc] 302 to Google -> callback to google-sso.D/oauth2/callback
                   -> [callback policy: oidc] exchanges code, sets ID-token cookie scoped to .D -> back to app.D
app.D (with cookie)-> [app policy: oidc] pass -> [jwt] validate -> [authorization] in THIS allowlist? -> backend
```

The callback always lands on the fixed `google-sso.<domain>` host, so Google needs exactly **one** redirect
URI per domain, never per app or per ingress. That host is stood up ONCE per domain by `04_google_sso` and
gets its OWN `SecurityPolicy` (via the library, `redirectURL` deriving to itself) whose only job is to
complete the token exchange and set the domain-scoped session cookie. A single OAuth client (one `clientID`
+ one sealed `client-secret`) serves everything; `redirectURL`/`cookieDomain` are derived from the ingress's
domain.

**One login, per-ingress authorization.** The session cookie is scoped to `cookieDomain` (the registrable
domain), so a single Google login covers every subdomain on that domain. Each ingress's policy still
independently re-checks its *own* allowlist against the token, so a shared cookie never widens access: a
user allowed on the platform UIs but absent from a workload's allowlist is signed in yet denied at that
workload. Across *different* registrable domains cookies don't cross, so the first visit re-runs OIDC but
you're already signed into Google (silent redirect), same identity throughout.

Because `cookieDomain` and the callback host are per registrable domain, **an SSO ingress must stay within
one registrable domain** — all its hosts under `sso.domain`. The library enforces this: it `fail`s the
render (so ArgoCD reports the error, nothing applies) if an SSO ingress names a host outside its `sso.domain`,
or sets `sso.enabled` without a `sso.domain`. Split a cross-domain group into one ingress per domain, or drop
the `sso` block to leave it open (an *open* ingress's SAN cert may span domains — cert SANs have no such rule).

### Adding a host / ingress / domain

| You add | Google Console | Cluster |
|---|---|---|
| a subdomain to an existing ingress | nothing | add a host to that ingress's `hosts:` |
| a new protected ingress on an existing domain | nothing | a new `ingresses:` entry with an `sso:` block + its own `allowlist` (platform UIs -> `08_platform_ingress`; a workload -> its own chart) |
| a brand-new root domain | +1 redirect URI (`google-sso.<newdomain>/oauth2/callback`) | a callback `ingresses:` entry in `04_google_sso` + register the URI via `07_google_sso.sh` |

### Allowlists are per-ingress values, only the client secret sealed
Envoy Gateway's `authorization` takes allowed emails as inline literals — they can't come from a Secret. So
each ingress keeps its `allowlist` inline in its own `values.yaml` (low-sensitivity email in a private repo);
change who may log in by editing that list and pushing — it is **not** prompted by any script. Only the OAuth
client secret is sealed ([06_secrets.md](06_secrets.md)). `SecurityPolicy` is namespaced, so protected routes
stay in the `gateway` namespace (a policy only targets routes in its own namespace).

### Fail-closed until sealed
Until `07_google_sso.sh` seals the client secret and you commit it, every policy references a missing Secret;
the placeholder `clientID` also denies everyone — so a half-configured policy never leaks access. Run the
script first.

### Apply / verify
1. Put the shared `GOOGLE_SSO_CLIENT_ID` + `GOOGLE_SSO_CLIENT_SECRET` in the gitignored `.env`, then run
   `./07_ingress/07_google_sso.sh` (needs the cluster reachable for `kubeseal`). It reads the callback domains
   from `04_google_sso/values.yaml`, prints the redirect URIs to register, writes the shared `clientID` into the
   library values, and seals the secret. Edit each ingress's `allowlist` by hand in its `values.yaml`.
2. Register each printed redirect URI on the one OAuth client; add each apex under "Authorized domains".
   Publish the consent screen (in "Testing" only listed test users log in, regardless of the allowlist).
3. Commit + push; ArgoCD applies the callback hosts (wave 4) and each ingress's policy.

Checks:
- `kubectl -n gateway get securitypolicy` -> one `sso-<ingressName>` per SSO ingress (`sso-platform`,
  `sso-google-sso-<slug>`, `sso-sample-workload-sso`, ...), each `Accepted=True` (not Accepted means the
  client-secret Secret is missing — run the script + push).
- Browse a protected host -> Google login -> bounce through `google-sso.<domain>` -> an account on THAT
  ingress's allowlist reaches the app; one off it is denied. The open control host loads with no login.
- **Verify the split on the live cluster (the one thing `helm template` can't prove):** because the token
  exchange now happens under the callback host's policy while each app is a *separate* policy, confirm login
  actually completes end-to-end after the first sync. If it loops: confirm the ID-token cookie name lines up
  between `oidc.cookieNames.idToken` and `jwt.extractFrom.cookies` (the riskiest wiring), the `client-secret`
  is identical everywhere (it is — one sealed Secret), and each domain's callback URI is registered exactly.
  Changing `cookieDomain` on a live policy needs browser cookies cleared first, or stale host-scoped cookies
  take precedence and break the flow.
