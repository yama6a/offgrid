# ingress

A Helm **application chart** (`type: application`) that renders a consumer's ingress "edge" from a declarative
`ingresses:` values block: per host a `:443` Gateway listener + an `HTTPRoute` (+ a cross-namespace
`ReferenceGrant`), and **one** multi-SAN cert-manager `Certificate` per ingress. It renders **no SSO**:
Google-SSO is applied centrally per domain by `04_google_sso`. See
[`docs/07_ingress.md`](../../../docs/07_ingress.md) for the full model and values schema.

The cluster wiring — gateway namespace `gateway` (`03_gateway`) and the fallback issuer as named-template
constants in `templates/_helpers.tpl`, plus the gateway class `eg` (`01_envoy_gateway`) inline in
`templates/_gateway.tpl` (used once) — is **hardcoded**, NOT exposed as values. Those are platform invariants,
not per-consumer choices, so a consumer can't (and shouldn't) override them; the only per-ingress cert knob is
`ingresses[].issuer`.

## Use it

Add the dependency and supply values. No template needed: the chart auto-renders from `ingresses:`.

```yaml
# Chart.yaml
dependencies:
  - name: ingress
    version: "*"
    repository: "file://../../../../lib/helm/ingress"
```
```yaml
# values.yaml (config under the dependency name)
ingress:
  ingresses:               # each with a `domain` and `hosts[]`
    - name: ...
      domain: ...
      hosts: [...]
```

A chart that instead wants the edge helper inline (google-sso builds its callback hosts alongside its own
SecurityPolicy) declares the same dependency, then calls the global named template from its OWN template:

```yaml
# templates/whatever.yaml
{{ include "ingress.renderIngress" (dict "ingress" $ing "release" $.Release "cloudflareZones" $zones) }}
```

## Why it looks the way it does

The `_*.tpl` partials + the single `templates/edge.yaml` entry point are not stylistic:

1. **`edge.yaml` is the one rendering template.** It calls `ingress.render` over the consumer's `ingresses:`,
   guarded so a consumer that only wants the helpers (google-sso) gets no stray render. Everything else here is
   a `{{ define }}` block.
2. **The `_` prefix marks partials.** Any `templates/` file whose name starts with `_` is never rendered to its
   own manifest, it only holds named-template definitions. Hence `_gateway.tpl`, `_httproute.tpl`,
   `_referencegrant.tpl`, `_certificate.tpl` (one per resource), `_helpers.tpl`, and `_all.tpl` (the
   orchestrator). `.tpl` is convention. Named templates are global across the chart tree, so a consumer that
   wants them inline (google-sso) can `include` them from its OWN templates.

## Why `_all.tpl` is a composition root (not independent files)

The edge is data-driven and cross-cutting: a consumer lists `ingresses[]`, each with `hosts[]`. `_all.tpl`
(`ingress.render`) is the one place that sees all of it, and it has to, for two reasons:

- **Aggregation.** Each ingress gets **one** multi-SAN `Certificate` covering *all* its hosts (into one shared
  Secret every listener references). That single cert can only be built by scanning the whole `hosts[]` list —
  it can't live in a per-host file.
- **Fan-out + validation.** It `range`s over `ingresses[]` then `hosts[]`, emitting a Gateway + HTTPRoute per
  host (and a ReferenceGrant only when the backend is cross-namespace), while enforcing guards up front
  (issuer must be a shipped ClusterIssuer; `domain` required; `hosts[].subdomain` must be a bare subdomain, not
  a full hostname) with clear `fail` messages.

Named templates don't inherit the top-level `.` scope, so `_all.tpl` bundles `ingress`/`host`/`release`
into a `$ctx` dict and threads it into each partial — that's the plumbing you see.

## Related

- [`pg-cluster`](../pg-cluster) / [`redis-instance`](../redis-instance): also `type: application` shared charts
  that render first-party CRs from values with no consumer template, the same shape this chart now uses (pin no
  upstream, ship no `Chart.lock`).
- [`rabbitmq-topology`](../rabbitmq-topology): the other messaging shared chart, also `type: application`,
  rendering its topology CRs from values with no consumer template.
