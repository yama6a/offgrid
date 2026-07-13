# rabbitmq-topology

A Helm **library chart** (`type: library`) that renders a workload's RabbitMQ topology — its `User`, the
`Exchange`/`Queue`/`Binding` CRs it owns, and one aggregated `Permission` — against the shared broker, from a
declarative `rabbitmq-topology:` values block. See [`docs/11_messaging.md`](../../../docs/11_messaging.md) for
the ownership model and the full values schema.

## Use it

Add the dependency and a one-line template in the consumer chart (an `application` chart):

```yaml
# Chart.yaml
dependencies:
  - name: rabbitmq-topology
    version: "*"
    repository: "file://../../../../lib/helm/rabbitmq-topology"
```
```yaml
# templates/messaging.yaml — the whole file
{{ include "rabbitmq-topology.render" . }}
```

Then declare intent in `values.yaml` under `rabbitmq-topology:` (`publishEvents` / `subscribeEvents` /
`consumeCommands` / `sendCommands`).

## Why it looks the way it does

The `_*.tpl` partials + single `include` entry point are not stylistic — two Helm facts force this shape:

1. **It's a library chart, so it renders nothing itself.** Helm does not turn a library chart's
   `templates/*.yaml` into manifests; a library chart only contributes *named templates* that a consumer pulls
   in via `include`. So the output happens in the **consumer's** `templates/messaging.yaml` (an application
   chart, which does render), and everything here must be a `{{ define }}` block.
2. **The `_` prefix marks partials.** Any `templates/` file whose name starts with `_` is never rendered to its
   own manifest — it only holds named-template definitions. Hence `_user.tpl`, `_exchange.tpl`, `_queue.tpl`,
   `_binding.tpl`, `_permission.tpl` (one per resource) and `_all.tpl` (the orchestrator). `.tpl` is convention.

## Why `_all.tpl` is a composition root (not independent files)

RabbitMQ allows exactly **one** `configure`/`write`/`read` permission triple per user+vhost, but the inputs are
scattered across four intent lists. So the single `Permission` must be computed by scanning *all* of them at
once — that aggregation can't live in independent per-resource files. `rabbitmq-topology.render` (`_all.tpl`)
is the one place that sees everything: it `range`s over each list, calls the per-resource partials to emit the
CRs, accumulates the write/read sets as it goes (escaping regex metacharacters, omitting empty fields to avoid
perpetual OutOfSync), and emits one `Permission` at the end.

Named templates don't inherit the top-level `.` scope, so `_all.tpl` bundles `user`/`vhost`/`cluster`/`ns` into
a `$ctx` dict and threads it into each partial — that's the plumbing you see at the top.

## Related

- [`ingress`](../ingress) — the same library-chart idiom (`include "ingress.render"`).
- [`pg-cluster`](../pg-cluster) — `type: application` instead, because it *wraps* an upstream chart (real
  rendered templates + committed `Chart.lock`), rather than composing first-party CRs.
