# 12 — Google SSO via Envoy Gateway SecurityPolicy (multi-domain)

Add an **optional** auth layer: Google login + an **email allowlist**, attached to a route by **label**,
scaling to **many apps across several domains** without per-host config. Protect a host = put
`sso: "<its-domain>"` on its `HTTPRoute`. Each domain funnels through **one shared callback host**
(`google-sso.<domain>`), so Google needs exactly **one redirect URI per domain** — never per app.
Proven on `gateway-test-sso.example.com` (protected) vs `gateway-test.example.com` (open).

Delivered (mostly) by ArgoCD:

- `argo_apps/platform/apps/04_google_sso.yaml` — the Application, **sync-wave 4**.
- `argo_apps/platform/charts/04_google_sso/` — one `SecurityPolicy` **per domain**, the per-domain
  `google-sso.<domain>` callback hosts (each a `Certificate` + an `sso:`-labelled `HTTPRoute`, sharing
  one tiny backend), and the shared sealed client secret. No upstream dependency, so no `Chart.lock`.
- the `httpsHosts` list in `argo_apps/platform/charts/03_gateway/` — the `:443` **listener** for each
  `google-sso.<domain>` (listeners can only live on the Gateway; the cert + route live in 04 above).
- `12_google_sso/12_google_sso.sh` — interactive: shared client-id/secret once, an allowlist per domain.

Builds on [11_envoy_gateway.md](11_envoy_gateway.md) — `SecurityPolicy` is Envoy Gateway's CRD.

## How it works — shared callback per domain

One `SecurityPolicy` per domain selects every `HTTPRoute` labelled `sso: <domain>` (`targetSelectors`)
and runs three filters at the Envoy edge:

```
app1.D (no session) → [oidc] 302 to Google → callback to google-sso.D/oauth2/callback
                    → EG sets the ID-token cookie scoped to .D (cookieDomain) → back to app1.D
app1.D (with cookie)→ [oidc] pass → [jwt] validate ID token (Google JWKS) → [authorization] email ∈ allowlist? → backend
```

`cookieDomain: <domain>` means that one login covers **every** subdomain of `<domain>` — visiting
`app2.D` next reuses the session, no second login. The callback always lands on the fixed
`google-sso.<domain>` host, which is why Google only needs that one URI per domain.

## The hard rule that shapes everything: cookies don't cross domains

A browser will share a session cookie across **subdomains of one registrable domain** but **never**
across different domains. So:

- **Within a domain** (`*.example.com`) → one login, shared via `cookieDomain`.
- **Across domains** (`example.com` → `yama.casa`) → each domain has its own cookie, so the first visit
  to a new domain re-runs OIDC — but you're already signed into Google, so it's a **silent redirect, no
  re-login**. Same Google identity throughout.

That's why the unit of configuration is the **domain**, never the app:

| You add… | Google Console | Cluster |
|---|---|---|
| a subdomain/app on an existing domain | nothing | label its route `sso: "<domain>"` |
| a brand-new root domain | +1 redirect URI (`google-sso.<newdomain>/oauth2/callback`) | a `domains` entry in **both** charts (below) + an allowlist |

## Decisions

### One SecurityPolicy per domain, selected by a domain-valued label
`targetSelectors: [{kind: HTTPRoute, matchLabels: {sso: "<domain>"}}]`. The label **value is the
domain** (`sso: "example.com"`), so each domain's policy claims exactly its own routes — no ambiguity
when several policies exist. A route opts in by carrying its domain as the label value.

### One shared Google OAuth client; per-domain redirect URIs
A single OAuth client (one `clientID` + one sealed `client-secret`) serves all domains. You register
**one redirect URI per domain** on it (`https://google-sso.<domain>/oauth2/callback`) and list each apex
under the consent screen's *Authorized domains*. `redirectURL` and `cookieDomain` are **derived** in the
chart from the domain — the script never writes them.

### The shared callback host needs real plumbing — split across two charts
`google-sso.<domain>` must be an `HTTPRoute` on the Gateway for Envoy Gateway to intercept
`/oauth2/callback` there, and it's HTTPS, so it needs a listener + cert. This chart (`04_google_sso`)
ships the `Certificate` + the `sso:`-labelled `HTTPRoute` (per domain, sharing **one tiny whoami
backend** — the callback path never reaches it). The `:443` **listener** for `google-sso.<domain>` can
only live on the Gateway, so it's an entry in `03_gateway`'s `httpsHosts`. So **two lists must agree**:
`httpsHosts` (03, the listeners) and `ssoDomains` (04, the policies + callback certs/routes) — the script
warns if they drift, and a missing listener means that domain's login 404s.

### The allowlist is INLINE and per-domain (only the client secret is sealed)
Envoy Gateway's `authorization` takes the allowed emails as inline literals — they can't come from a
Secret. We keep them inline in `values.yaml` (low-sensitivity email in a private repo), **per domain**,
and seal only the OAuth client secret. `defaultAction: Deny` → an account off the list is rejected even
after a successful Google login.

### Email comes from the ID token, via a cookie
Google's access token is opaque, so the `email` claim is in the **ID token**. OIDC stores it in
`oidc.cookieNames.idToken`; the `jwt` provider reads that cookie (`extractFrom.cookies`) so
`authorization` can match the claim. This OIDC→JWT cookie wiring is the one part only fully verifiable
live (see Verify).

### Fail-closed on the allowlist, fail-open until sealed
Until `12_google_sso.sh` seals the client secret and you commit it, every policy references a **missing**
Secret and won't attach — so labelled routes are **open**. Run the script first. The placeholder
`clientID`/allowlist also deny everyone, so a half-configured policy never leaks access.

### SecurityPolicy is namespaced
A policy targets routes in its **own** namespace, so all policies + routes live in `gateway`. Apps whose
routes live in other namespaces need the policy replicated there (still label-selected, not per-host) —
simplest is to keep protected `HTTPRoute`s in the `gateway` namespace.

## Apply / verify

1. Run `./12_google_sso/12_google_sso.sh` (needs the cluster reachable for `kubeseal`). It reads the
   domains from `04_google_sso/values.yaml`, prints the redirect URIs to register, prompts the shared
   client-id/secret + an allowlist per domain, writes the values, and seals the secret.
2. Register each printed redirect URI on the **one** OAuth client; add each apex under *Authorized
   domains*.
3. `git add -A && git commit && git push` — ArgoCD (wave 4) unseals the secret and applies the policies.
4. For each `google-sso.<domain>` callback host **and** each protected app host: DNS → home router, and
   forward `:80` on the old Pi so HTTP-01 issues the certs (same as any host, see [10_gateway.md](10_gateway.md)).

Checks:

- `kubectl -n gateway get securitypolicy` → `google-sso-<slug>` per domain, `Accepted=True` (not Accepted
  ⇒ the client-secret Secret is missing — run the script + push).
- Browse `https://gateway-test-sso.example.com/` (the protected demo from [gateway-test](13_gateway_test.md))
  → Google login → bounce through `google-sso.example.com` → an allowlisted account reaches whoami; a
  non-listed one is denied.
- `https://gateway-test.example.com/` → whoami, no login (the open control).
- If login loops or the allowlist never matches: confirm the **ID-token cookie name** lines up between
  `oidc.cookieNames.idToken` and `jwt.extractFrom.cookies` (the riskiest wiring), and that each domain's
  callback URI is registered exactly.

## Adding apps / domains

- **Another app on an existing domain** → label its `HTTPRoute` `sso: "<domain>"`. Done.
- **A new domain** → add a `{name, hostname, tlsSecretName}` listener entry to `httpsHosts` (03) for
  `google-sso.<newdomain>` **and** a `{domain, issuer, allowlist}` entry to `ssoDomains` (04), register
  one redirect URI (`google-sso.<newdomain>/oauth2/callback`) on the OAuth client, and re-run the script.

## Caveats

- **Run the script before expecting protection** — no sealed secret ⇒ policies don't attach ⇒ routes open.
- **Keep the two lists in sync** — a `google-sso.<domain>` listener in `httpsHosts` (03) for every
  `ssoDomains` entry (04). The script warns on drift.
- **Changing `cookieDomain` on a live policy** requires clearing browser cookies first, or stale
  host-scoped cookies take precedence and break the flow.
- **Publish the OAuth consent screen** — in "Testing" only listed test users can log in, regardless of
  the allowlist.
- **The SealedSecret is bound to this cluster's key** — restore the backed-up key on a rebuild
  ([07_sealed_secrets.md](07_sealed_secrets.md)) or re-run the script.
