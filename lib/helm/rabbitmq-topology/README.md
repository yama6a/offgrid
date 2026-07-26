# rabbitmq-topology

A Helm **application chart** (`type: application`) that renders a workload's RabbitMQ topology directly: its
`User`, the `Exchange`/`Queue`/`Binding` CRs it owns (plus a `<queue>.dlx`/`<queue>.dlq` dead-letter pair per
consumer queue), and one aggregated `Permission`, against the shared broker, from a declarative
`rabbitmq-topology:` values block. See [`docs/11_messaging.md`](../../../docs/11_messaging.md) for the
ownership model and the full values schema.

## Use it

Add the dependency to the consumer chart. No template of your own: this chart renders itself.

```yaml
# Chart.yaml
dependencies:
  - name: rabbitmq-topology
    version: "*"
    repository: "file://../../../../lib/helm/rabbitmq-topology"
```

Then declare intent in `values.yaml` under `rabbitmq-topology:` (`publishEvents` / `subscribeEvents` /
`consumeCommands` / `sendCommands`). Run `helm dependency update` and commit the consumer's `Chart.lock`.

## Layout

Plain manifest files (like `pg-cluster`/`redis-instance`), one per resource kind:

- `user.yaml`: the one `User` (operator-generated credentials Secret).
- `exchanges.yaml`: the exchanges this workload owns (`publishEvents` + the direct `consumeCommands` exchanges).
- `queues.yaml`: each consumed queue + its binding, and its dead-letter companions when `deadLetter` is on.
- `permission.yaml`: the one aggregated `Permission`.
- `validate.yaml`: fail-fast guards (renders nothing).
- `_helpers.tpl`: the two small shared snippets (`rabbitmq-topology.user`, `rabbitmq-topology.clusterRef`).

## The aggregated Permission

RabbitMQ allows exactly one `configure`/`write`/`read` triple per user+vhost, and the inputs are scattered
across the four intent lists. `permission.yaml` recomputes both sets from the same values (`write` =
`publishEvents` + `sendCommands`, `read` = `consumeCommands` queues + the `<user>.<exchange>` subscribe
queues), escapes regex metacharacters, and emits only the non-empty fields (an empty `write`/`read` would sit
perpetually OutOfSync, since the operator drops empty strings). It needs no shared state with the other files:
each manifest ranges the values it cares about.

## Related

- [`pg-cluster`](../pg-cluster) / [`redis-instance`](../redis-instance) / [`ingress`](../ingress): the other
  `type: application` shared charts that render first-party CRs from values with no consumer template. Pin no
  upstream, ship no `Chart.lock`.
