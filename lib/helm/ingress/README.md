# ingress

The interface is the `Chart.yaml` description and `values.yaml`. The model and schema are in
[`docs/04_ingress.md`](../../../docs/04_ingress.md).

## Why `_all.tpl` is one file

`_all.tpl` composes the per-resource partials (`_gateway.tpl`, `_httproute.tpl`, `_referencegrant.tpl`,
`_certificate.tpl`). It cannot split into one file for each host:

- **Aggregation.** Each ingress gets one multi-SAN `Certificate` for all its hosts, in one shared Secret that every
  listener references. So the template needs the whole `hosts[]` list at once.
- **Validation.** The guards check the whole ingress and stop with a clear `fail` message before any host renders.

## Calling it inline

Named templates are global across the chart tree. A consumer that needs the edge next to its own resources declares
the same dependency and calls the template directly. `04_google_sso` does this to build its callback hosts next to
its SecurityPolicy:

```yaml
{{ include "ingress.renderIngress" (dict "ingress" $ing "release" $.Release "cloudflareZones" $zones) }}
```
