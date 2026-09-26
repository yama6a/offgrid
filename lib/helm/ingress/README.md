# ingress

The interface is the `Chart.yaml` description and `values.yaml`. The model and schema are in
[`docs/04_ingress.md`](../../../docs/04_ingress.md).

This file only explains the shape of the templates.

## The `_*.tpl` split

Helm never renders a `templates/` file whose name starts with `_` to its own manifest. Such a file only holds
`{{ define }}` blocks.

- `_gateway.tpl`, `_httproute.tpl`, `_referencegrant.tpl`, `_certificate.tpl`: one partial for each resource.
- `_helpers.tpl`: the derived values.
- `_all.tpl`: composes the partials.
- `edge.yaml`: the one rendering template. It calls `ingress.render` over the `ingresses:` list of the consumer.
  A guard skips the render when that list is empty, so a consumer that only wants the helpers gets no stray
  output.

## Why `_all.tpl` is one file

It cannot split into independent files for each host, for two reasons:

- **Aggregation.** Each ingress gets one multi-SAN `Certificate` for all its hosts. That certificate goes into one
  shared Secret, and every listener references it. To build it, the template needs the whole `hosts[]` list at
  once.
- **Fan-out and validation.** The template loops over `ingresses[]`, then over `hosts[]`. It emits a Gateway and an
  HTTPRoute for each host. It emits a ReferenceGrant only when the backend is in another namespace. It checks the
  guards first and stops with a clear `fail` message.

A named template does not inherit the top-level `.` scope. So `_all.tpl` puts `ingress`, `host` and `release` into
a `$ctx` dict and passes it to each partial.

## Calling it inline

Named templates are global across the chart tree. A consumer that needs the edge next to its own resources declares
the same dependency and calls the template directly. `04_google_sso` does this to build its callback hosts next to
its SecurityPolicy:

```yaml
{{ include "ingress.renderIngress" (dict "ingress" $ing "release" $.Release "cloudflareZones" $zones) }}
```
