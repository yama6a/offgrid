# ingress

Interface: `Chart.yaml` description + `values.yaml`. Model and schema:
[`docs/04_ingress.md`](../../../docs/04_ingress.md).

This file covers only why the templates are shaped the way they are.

## The `_*.tpl` split

A `templates/` file whose name starts with `_` is never rendered to its own manifest; it only holds `{{ define }}`
blocks.

- `_gateway.tpl`, `_httproute.tpl`, `_referencegrant.tpl`, `_certificate.tpl`: one partial per resource.
- `_helpers.tpl`: the derivations.
- `_all.tpl`: the composition root.
- `edge.yaml`: the single rendering template. It calls `ingress.render` over the consumer's `ingresses:`, guarded
  so a consumer that only wants the helpers gets no stray render.

## Why `_all.tpl` is one file

Two reasons it cannot split into independent per-host files:

- Aggregation. Each ingress gets ONE multi-SAN `Certificate` covering all its hosts, into one shared Secret every
  listener references. Building that needs the whole `hosts[]` list at once.
- Fan-out plus validation. It ranges `ingresses[]` then `hosts[]`, emitting a Gateway and HTTPRoute per host, and
  a ReferenceGrant only when the backend is cross-namespace, while enforcing the guards up front with clear
  `fail` messages.

Named templates do not inherit the top-level `.` scope, which is why `_all.tpl` bundles `ingress`, `host` and
`release` into a `$ctx` dict and threads it into each partial.

## Calling it inline

Named templates are global across the chart tree, so a consumer that needs the edge alongside its own resources
declares the same dependency and calls it directly. `04_google_sso` does this, building callback hosts next to its
SecurityPolicy:

```yaml
{{ include "ingress.renderIngress" (dict "ingress" $ing "release" $.Release "cloudflareZones" $zones) }}
```
