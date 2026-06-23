# 12 — Google SSO via Envoy Gateway SecurityPolicy

Add an **optional** auth layer: Google login + an **email allowlist** that attaches to a route by
**label**. Protect a host = put `auth: google-sso` on its `HTTPRoute`; remove the label = it's open
again. No per-host proxy, no per-host upstream. Proven on **`gateway-test-sso`** (protected) vs
**`gateway-test`** (left open).

Delivered (mostly) by ArgoCD:

- `argo_apps/apps/04_google_sso.yaml` — the Application, **sync-wave 4**.
- `argo_apps/charts/04_google_sso/` — one `SecurityPolicy` (+ the sealed client secret). No upstream
  dependency (first-party CRs), so no `Chart.lock`.
- `12_google_sso/12_google_sso.sh` — interactive: prompts for the Google client-id, client-secret and
  the allowed emails; writes the non-secret bits into the chart `values.yaml` and seals the client
  secret.

It builds on [11_envoy_gateway.md](11_envoy_gateway.md) — the `SecurityPolicy` CRD is Envoy Gateway's.

## How it works — three filters at the edge

One `SecurityPolicy` selects every `HTTPRoute` labelled `auth: google-sso` (`targetSelectors`) and runs
three stacked filters at the Envoy edge, in order:

```
request → [oidc] no session? → 302 to Google → callback → stores the ID token in a cookie
        → [jwt] validates that ID token against Google's JWKS, exposes its claims
        → [authorization] Deny by default; Allow only if the `email` claim ∈ the inline allowlist
        → backend (the route's own Service — no proxy in the path)
```

The route still points straight at its app Service; Envoy enforces auth *before* forwarding. Adding a
protected host is purely additive — label its route and it inherits this exact policy.

## Decisions

### Label-selector attachment (the whole point)
`targetSelectors: [{kind: HTTPRoute, matchLabels: {auth: google-sso}}]` means the policy is defined
**once** and protects any route that opts in by label. There is no per-host config here — contrast the
earlier oauth2-proxy approach, which needed a proxy + an upstream entry per host. `gateway-test`'s route
is unlabelled, so it stays open; `gateway-test-sso`'s route carries the label, so it's protected.

### The allowlist is INLINE (only the client secret is sealed)
Envoy Gateway's `authorization` rules take the allowed emails as **inline literals** — they cannot be
sourced from a Secret or ConfigMap. The only sealed alternative is delegating to an external authorizer
(oauth2-proxy via `extAuth`), which reintroduces a component and an undocumented login-redirect flow.
We deliberately keep the allowlist inline in `values.yaml` (it's low-sensitivity email in a private
repo) and seal **only** the OAuth client secret. Editing the allowlist is then a normal git commit
(re-run the script, or hand-edit `.allowlist` and push). The client **id** is also plaintext (it isn't
sensitive); only `client-secret` is a `SealedSecret`.

### Email comes from the ID token, via a cookie
Google's access token is opaque (not a JWT), so the `email` claim lives in the **ID token**. The policy
tells OIDC to store the ID token in a named cookie (`oidc.cookieNames.idToken`), and the `jwt` provider
reads it (`extractFrom.cookies`) so `authorization` can match the claim. This OIDC→JWT cookie wiring is
the one part only fully verifiable live (see Verify).

### Fail-closed on the allowlist, fail-open until sealed
`authorization.defaultAction: Deny` means an account not in the list is rejected even after a successful
Google login. But until `12_google_sso.sh` seals the client secret and you commit it, the policy
references a **missing** Secret and won't attach — so the labelled route is **open**. Run the script
before relying on protection. The shipped placeholder `clientID`/allowlist also deny everyone (login
fails on a bogus client), so a half-configured policy never leaks access.

### SecurityPolicy is namespaced — same namespace as the routes
A `SecurityPolicy` targets routes in its **own** namespace, so it lives in `gateway` alongside the
`gateway-test-sso` route and the sealed Secret. For future apps whose routes live in other namespaces,
it's **one SecurityPolicy per namespace** (still label-selected, not per-host) — copy this chart and
point its `namespace` at the app's namespace.

### redirectURL is per host (a Google constraint)
`redirectURL` must be a literal `https://<host>/oauth2/callback` and be registered on the Google OAuth
client. For the test that's one host. For dozens of hosts the "configure once" pattern is a single
shared **auth host** + `cookieDomain: <baseDomain>` so the session cookie is shared across
`*.<baseDomain>` and one callback URI covers everything (`cookieDomain` is already set to the base
domain for exactly this). Hosts on unrelated domains need their own policy/redirect.

## Google OAuth client

The script prints the exact steps (and the precise redirect URI). In short: OAuth consent screen
**External + Published**, an **OAuth client ID** of type **Web application**, Authorized redirect URI
`https://<host>/oauth2/callback`, then copy the client id + secret. **No service account** — that's only
for Google Workspace *group* restriction, which we don't use.

## Apply / verify

1. Run `./12_google_sso/12_google_sso.sh` (needs the cluster reachable so `kubeseal` can fetch the
   controller cert). It derives the host from the gateway chart, prompts for client-id/secret + emails,
   writes `values.yaml` (clientID, redirectURL, cookieDomain, allowlist) and seals the client secret.
2. `git add -A && git commit && git push` — ArgoCD (wave 4) unseals the secret and applies the policy.
3. Ensure `gateway-test-sso.<baseDomain>` resolves + the old Pi forwards `:80` for it (cert issuance),
   same as `gateway-test`.

Checks:

- `kubectl -n gateway get securitypolicy google-sso` → `Accepted=True` (not Accepted ⇒ the client-secret
  Secret is missing — did you run the script + push?).
- Browse `https://gateway-test-sso.<baseDomain>/` → **Google login**; an allowlisted account reaches the
  whoami echo, a non-listed one is denied.
- `https://gateway-test.<baseDomain>/` → whoami **with no login** (the unprotected control).
- If login loops or the allowlist never matches, check the **ID-token cookie name** lines up between
  `oidc.cookieNames.idToken` and `jwt.providers[0].extractFrom.cookies` (this is the riskiest wiring),
  and that the Google client has the exact redirect URI.

## Protecting another host

Label its `HTTPRoute` with `auth: google-sso`. If that route is in the `gateway` namespace, you're done
(same policy). If it's in another namespace, copy `04_google_sso` with `namespace:` set to that one, and
register the host's `/oauth2/callback` on the Google client (or adopt the shared-auth-host +
`cookieDomain` pattern above). Re-run the script to change the allowlist or rotate the client secret.

## Caveats

- **Run the script before expecting protection** — no sealed secret ⇒ the policy doesn't attach ⇒ the
  route is open.
- **Publish the OAuth consent screen** — in "Testing" only listed test users can log in (max 100),
  regardless of the allowlist.
- **The SealedSecret is bound to this cluster's key** — restore the backed-up sealed-secrets key on a
  rebuild ([07_sealed_secrets.md](07_sealed_secrets.md)) or re-run the script to re-seal.
- **`redirectURL` must match Google exactly** — if you change `baseDomain` or the subdomain, re-run the
  script and update the Authorized redirect URI.
