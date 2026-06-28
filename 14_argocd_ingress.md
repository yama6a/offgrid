# 14 — ArgoCD UI behind Google SSO

Expose the **ArgoCD UI** through the shared Gateway, fronted by the same Google SSO we built in
[12_google_sso.md](12_google_sso.md) — **without** touching ArgoCD's own auth. Two independent layers:

```
browser → Gateway :443 (argocd.example.com) → HTTPRoute (sso: example.com)
        → [Envoy OIDC gate]  Google login + allowlist     (OUTER — network gate)
        → argocd-server :80  → [ArgoCD admin login]        (INNER — unchanged)
```

The Google gate only decides *who can reach the UI*; ArgoCD stays in **local-admin** mode (no Dex, no
OIDC, no RBAC). You log in twice — Google, then the ArgoCD admin you already use.

Delivered purely by ArgoCD:

- `argo_apps/platform/apps/06_argocd_ingress.yaml` — the Application, **sync-wave 6**.
- `argo_apps/platform/charts/06_argocd_ingress/` — a `Certificate` + an `sso`-labelled `HTTPRoute` (cross-namespace
  backendRef to `argocd-server`) + a `ReferenceGrant`. No `Chart.lock`.
- the `argocd` entry in `03_gateway`'s `httpsHosts` — the `:443` listener for `argocd.example.com`.

## Why it's almost free
`argocd.example.com` is a subdomain of `example.com`, so the **existing** example.com `SecurityPolicy`,
the shared `google-sso.example.com` callback, and `cookieDomain: example.com` already cover it — **no new
Google redirect URI, no new policy**. You just label the route `sso: "example.com"` and it's gated; if
you're already signed into another `*.example.com` app the Google step is silent.

## Decisions

### ArgoCD is untouched — the gate is purely at the edge
ArgoCD keeps `server.insecure: true` (it already does — [05_gitops.md](05_gitops.md)) and serves HTTP on
`argocd-server:80`; the Gateway terminates TLS. We add only the Certificate + HTTPRoute + ReferenceGrant.
`01_argocd` doesn't change.

### Route in `gateway` ns + cross-namespace backendRef
A `SecurityPolicy` selects routes in its own namespace, so the route lives in `gateway` (under the
example.com policy) and reaches `argocd-server` in the `argocd` namespace via a `ReferenceGrant` — the
namespaced-app pattern. The Certificate also lives in `gateway` (so the listener can read its Secret).

### `logoutPath` moved off `/logout`
Envoy Gateway's OIDC filter defaults its logout to `/logout`, which an app could also use. The example.com
policy now sets `logoutPath: /oauth2/sign_out` so the gate doesn't swallow ArgoCD's own `/logout`. (One
field on the shared policy; harmless for the other example.com apps.)

### Sync-wave 6
After the gateway (wave 3 — the `argocd` listener) and the SSO policy (wave 4 — so the UI is gated the
instant its labelled route appears). `ServerSideDiff` so the Gateway API resources don't show perpetual
OutOfSync.

## The CLI + break-glass
The Google gate **blocks the `argocd` CLI** — the CLI speaks gRPC and can't run the browser OIDC flow.
Keep using **port-forward for the CLI**, which is also your **break-glass**: it goes straight to the pod,
bypassing the Gateway *and* the SSO gate, so a broken route/policy never locks you out:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80   # UI + CLI, no gate
```

## Apply / verify

1. Add an A-record `argocd.example.com` → your router (the old-Pi `*.example.com` forward already covers
   `:80`/`:443`, so the cert issues and traffic reaches the Gateway).
2. `git add -A && git commit && git push` — ArgoCD (wave 6) applies the cert, route and grant.
3. Once issued, flip `issuer` to `letsencrypt-prod` in the chart values for a browser-trusted cert (the
   UI is browser-facing; example.com's HTTP-01 path is already validated).

Checks:

- `kubectl -n gateway get certificate argocd` → `READY=True`.
- `kubectl -n gateway get httproute argocd` → `Accepted=True`, `ResolvedRefs=True` (the latter needs the
  ReferenceGrant).
- Browse `https://argocd.example.com/` → Google login (or silent if already signed in) → the ArgoCD
  login page → log in with admin.

## Caveats

- **CLI via port-forward only** (above).
- **Self-management** — ArgoCD manages the app that exposes ArgoCD; a bad push is reverted by selfHeal,
  and port-forward is the escape hatch if you ever wedge it.
- **Optional `server.url`** — if any UI redirect/link misbehaves behind the proxy, set
  `server.url: https://argocd.example.com` in `01_argocd`'s values (`argocd-cm`). Not needed for local
  admin login, so left unset.
- **Staging cert = browser warning** until you flip `issuer` to prod.
