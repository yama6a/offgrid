# ingress

A Helm **library chart** (`type: library`) that renders a workload's ingress "edge" from a declarative
`ingress:` values block: per host a `:443` Gateway listener + an `HTTPRoute` (+ a cross-namespace
`ReferenceGrant`), and **one** multi-SAN cert-manager `Certificate` per ingress. It renders **no SSO** —
Google-SSO is applied centrally per domain by `04_google_sso`. See
[`docs/07_ingress.md`](../../../docs/07_ingress.md) for the full model and values schema.

The cluster wiring — gateway namespace `gateway` (`03_gateway`) and the fallback issuer as named-template
constants in `templates/_helpers.tpl`, plus the gateway class `eg` (`01_envoy_gateway`) inline in
`templates/_gateway.tpl` (used once) — is **hardcoded**, NOT exposed as values. Those are platform invariants,
not per-consumer choices, so a consumer can't (and shouldn't) override them; the only per-ingress cert knob is
`ingresses[].issuer`.

## Use it

Add the dependency and a one-line template in the consumer chart (an `application` chart):

```yaml
# Chart.yaml
dependencies:
  - name: ingress
    version: "*"
    repository: "file://../../../../lib/helm/ingress"
```
```yaml
# templates/ingress.yaml — the whole file
{{ include "ingress.render" . }}
```

Then declare intent in `values.yaml` under `ingress:` (`ingresses[]`, each with a `domain` and `hosts[]`).

## Why it looks the way it does

The `_*.tpl` partials + single `include` entry point are not stylistic — two Helm facts force this shape:

1. **It's a library chart, so it renders nothing itself.** Helm does not turn a library chart's
   `templates/*.yaml` into manifests; a library chart only contributes *named templates* that a consumer pulls
   in via `include`. So the output happens in the **consumer's** `templates/ingress.yaml` (an application
   chart, which does render), and everything here must be a `{{ define }}` block.
2. **The `_` prefix marks partials.** Any `templates/` file whose name starts with `_` is never rendered to its
   own manifest — it only holds named-template definitions. Hence `_gateway.tpl`, `_httproute.tpl`,
   `_referencegrant.tpl`, `_certificate.tpl` (one per resource), `_helpers.tpl`, and `_all.tpl` (the
   orchestrator). `.tpl` is convention.

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

- [`rabbitmq-topology`](../rabbitmq-topology) — the same library-chart idiom (`include "rabbitmq-topology.render"`).
- [`pg-cluster`](../pg-cluster) — `type: application` instead, because it *wraps* an upstream chart (real
  rendered templates + committed `Chart.lock`), rather than composing first-party resources.
