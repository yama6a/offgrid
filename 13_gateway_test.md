# 13 — gateway-test: demo apps behind the Gateway

Throwaway `whoami` echo apps that exercise the shared Gateway end to end — **split out of the
`03_gateway` platform so the ingress platform owns no apps**. Two of them:

- **`gateway-test`** — OPEN (no `sso` label): the unprotected control, proves the raw HTTPS path.
- **`gateway-test-sso`** — PROTECTED: its `HTTPRoute` is labelled `sso: "example.com"`, so the matching
  [`04_google_sso`](12_google_sso.md) `SecurityPolicy` gates it behind Google login + the example.com
  allowlist (auth bounces via the shared `google-sso.example.com` callback host).

Delivered purely by ArgoCD:

- `argo_apps/workloads/apps/gateway_test.yaml` — the Application. A **workload** (in the workloads tree),
  so **no `NN_` number and no `sync-wave`** — see "Ordering" below.
- `argo_apps/workloads/charts/gateway_test/` — a generic `apps` list; each entry renders a Deployment +
  Service + Certificate + HTTPRoute. No upstream dependency (first-party resources + a tiny Deployment),
  so no `Chart.lock`.

## How an entry works

Each `apps[]` entry owns its app's full slice **except the listener** (which lives on the Gateway):

```yaml
apps:
  - name: gateway-test-sso
    host: gateway-test-sso.example.com
    listenerName: gateway-test-sso      # == a 03_gateway httpsHosts entry's `name` (the :443 listener)
    tlsSecretName: gateway-test-sso-tls # == that entry's `tlsSecretName` (the cert Secret it references)
    issuer: letsencrypt-prod            # which ClusterIssuer mints the cert (HTTP-01)
    sso: "example.com"                  # set => route labelled sso:<domain> (protected); "" => open
```

The chart renders the Deployment + Service (the whoami), the `Certificate` (HTTP-01, fills the Secret
the Gateway listener references), and the `HTTPRoute` (`parentRefs.sectionName: <listenerName>`, the
`sso` label only when set). Toggle an app by adding/removing its list entry.

## Decisions

### Why split out of `03_gateway`
The Gateway platform (Gateway + listeners + issuers) is one concern; demo/echo apps are another. Keeping
them apart means `03_gateway` reads as "the ingress," and apps — demo or real — live in the **workloads
tree**, gated behind the whole platform. This chart is the template for *any* app behind the Gateway:
workload + cert + route + (optional) `sso` label.

### The listener still lives on the Gateway (the HTTP-01 coupling)
One shared Gateway + per-host HTTP-01 (no wildcard without DNS-01) means **every HTTPS host needs a
`:443` listener on the one Gateway resource** — that can't move into this chart. So each app here has a
matching entry in `03_gateway`'s `httpsHosts` (`name == listenerName`, `hostname == host`,
`tlsSecretName == tlsSecretName`). Adding an app is a two-place edit: the listener in `03_gateway`, the
cert+route+workload here. That's the price of one Gateway + HTTP-01; a wildcard cert via DNS-01 would
remove it, but we don't have DNS-01.

### Ordering — a workload, gated behind the whole platform
These apps need the Gateway listeners (platform wave 3) **and** the SSO policies (platform wave 4) to
already exist — otherwise `gateway-test-sso` could be briefly exposed before its `SecurityPolicy`
attaches. As a **workload** it gets that for free: the root-of-roots only creates the workloads tree
**after the entire platform is Synced + Healthy**, so the Gateway and the SSO policies are guaranteed
present before this route appears. That's why it needs no per-app `sync-wave` — the platform→workloads
gate is the single ordering guarantee. See the two-tree model in [05_gitops.md](05_gitops.md) /
[CLAUDE.md](CLAUDE.md).

## Apply / verify

1. Ensure each app's hostname has a `03_gateway` `httpsHosts` listener, public DNS → home router, and the
   old Pi forwarding `:80` to the Gateway IP so HTTP-01 issues its cert (see [10_gateway.md](10_gateway.md)).
2. `git add -A && git commit && git push` — ArgoCD applies the demo apps via the workloads tree (once the
   platform is Healthy).

Checks:

- `kubectl -n gateway get certificate gateway-test gateway-test-sso` → `READY=True` once DNS + the `:80`
  forward exist.
- `https://gateway-test.example.com/` → the whoami echo, **no login** (open control).
- `https://gateway-test-sso.example.com/` → **Google login** → bounce via `google-sso.example.com` → an
  allowlisted account reaches the echo; a non-listed one is denied (see [12_google_sso.md](12_google_sso.md)).

## Caveats

- **Two-place edit per app** — keep the `httpsHosts` listener (03) and the `apps` entry (here) in step
  (`name`/`hostname`/`tlsSecretName` must match), or the route won't bind / the cert won't fill the
  listener's Secret.
- **`gateway-test-sso` is only protected once `04_google_sso` is configured** — run
  `12_google_sso/12_google_sso.sh` and commit, or the policy doesn't attach and the route is open (see
  [12_google_sso.md](12_google_sso.md)).
