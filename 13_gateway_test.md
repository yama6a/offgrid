# 13 — gateway-test: demo apps behind the Gateway

Throwaway `whoami` echo apps that exercise the ingress path end to end — each owns its **own Gateway + :443
listener**, all folded onto the one shared Envoy + LoadBalancer via `mergeGateways` (`01_envoy_gateway`).
**Split out of the `03_gateway` platform so the ingress platform owns no apps**. Two of them:

- **`gateway-test`** — OPEN (no `sso` label): the unprotected control, proves the raw HTTPS path.
- **`gateway-test-sso`** — PROTECTED: its `HTTPRoute` is labelled `sso: "example.com"`, so the matching
  [`04_google_sso`](12_google_sso.md) `SecurityPolicy` gates it behind Google login + the example.com
  allowlist (auth bounces via the shared `google-sso.example.com` callback host).

Delivered purely by ArgoCD:

- `argo_apps/workloads/apps/gateway_test.yaml` — the Application. A **workload** (in the workloads tree),
  so **no `NN_` number and no `sync-wave`** — see "Ordering" below.
- `argo_apps/workloads/charts/gateway_test/` — a generic `apps` list; each entry renders its own Gateway +
  :443 listener (`templates/gateway.yaml`) plus a Deployment + Service + Certificate + HTTPRoute. No
  upstream dependency (first-party resources + a tiny Deployment), so no `Chart.lock`.

## How an entry works

Each `apps[]` entry owns its app's **full ingress slice** — Gateway + listener, cert, route, workload:

```yaml
apps:
  - name: gateway-test-sso
    host: gateway-test-sso.example.com
    listenerName: gateway-test-sso      # the :443 listener on this app's own Gateway (templates/gateway.yaml)
    tlsSecretName: gateway-test-sso-tls # the cert Secret that listener references
    issuer: letsencrypt-prod            # which ClusterIssuer mints the cert (HTTP-01)
    sso: "example.com"                  # set => route labelled sso:<domain> (protected); "" => open
```

The chart renders this app's own `Gateway` + `:443` listener (`templates/gateway.yaml`, merged onto the
shared Envoy), the Deployment + Service (the whoami), the `Certificate` (HTTP-01, fills the Secret that
listener references), and the `HTTPRoute` (`parentRefs` → this app's Gateway, `sectionName: <listenerName>`,
the `sso` label only when set). Toggle an app by adding/removing its list entry.

## Decisions

### Why split out of `03_gateway`
The Gateway platform (Gateway + listeners + issuers) is one concern; demo/echo apps are another. Keeping
them apart means `03_gateway` reads as "the ingress," and apps — demo or real — live in the **workloads
tree**, gated behind the whole platform. This chart is the template for *any* app behind the Gateway:
workload + cert + route + (optional) `sso` label.

### One-place edit — the app owns its whole ingress stack
Per-host HTTP-01 (no wildcard without DNS-01) still means **every HTTPS host needs its own `:443`
listener** — but that listener now lives on the **app's own Gateway** (`templates/gateway.yaml`), folded
onto the shared Envoy via `mergeGateways`, not on a single shared Gateway resource in `03_gateway`. So
adding an app is a **one-place edit**: a single `apps[]` entry here renders the Gateway + listener + cert
+ route + workload together, with nothing to keep in step in `03_gateway`. The per-host listener
requirement persists (a wildcard cert via DNS-01 would remove it, but we don't have DNS-01) — it just no
longer forces a second edit, because each app carries its own listener.

### Ordering — a workload, gated behind the whole platform
These apps need the Gateway listeners (platform wave 3) **and** the SSO policies (platform wave 4) to
already exist — otherwise `gateway-test-sso` could be briefly exposed before its `SecurityPolicy`
attaches. As a **workload** it gets that for free: the root-of-roots only creates the workloads tree
**after the entire platform is Synced + Healthy**, so the Gateway and the SSO policies are guaranteed
present before this route appears. That's why it needs no per-app `sync-wave` — the platform→workloads
gate is the single ordering guarantee. See the two-tree model in [05_gitops.md](05_gitops.md) /
[CLAUDE.md](CLAUDE.md).

## Apply / verify

1. Ensure each app's hostname has public DNS → home router and the old Pi forwarding `:80` to the Gateway
   IP so HTTP-01 issues its cert (its `:443` listener ships with the app's own Gateway here — see
   [10_gateway.md](10_gateway.md)).
2. `git add -A && git commit && git push` — ArgoCD applies the demo apps via the workloads tree (once the
   platform is Healthy).

Checks:

- `kubectl -n gateway get certificate gateway-test gateway-test-sso` → `READY=True` once DNS + the `:80`
  forward exist.
- `https://gateway-test.example.com/` → the whoami echo, **no login** (open control).
- `https://gateway-test-sso.example.com/` → **Google login** → bounce via `google-sso.example.com` → an
  allowlisted account reaches the echo; a non-listed one is denied (see [12_google_sso.md](12_google_sso.md)).

## Caveats

- **One-place edit per app** — a single `apps` entry here renders the whole stack (Gateway + listener +
  cert + route + workload), so keep its own fields consistent (`listenerName`/`host`/`tlsSecretName`), or
  the route won't bind / the cert won't fill the listener's Secret. No `03_gateway` edit is involved.
- **`gateway-test-sso` is only protected once `04_google_sso` is configured** — run
  `12_google_sso/12_google_sso.sh` and commit, or the policy doesn't attach and the route is open (see
  [12_google_sso.md](12_google_sso.md)).
