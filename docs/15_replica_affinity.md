# Replica affinity

A Longhorn PV attaches over the network and carries no `nodeAffinity`. So the scheduler cannot see which 2 of the
4 nodes hold a volume's replicas, and a pod's IO may cross the 1GbE link for its whole life. Before this app ran,
16 of 31 attached volumes (52%) had no replica on their pod's node. 12 of those were on the amd64 worker, which
joined after the Pis and got pods but no replicas.

`longhorn-replica-affinity` is a mutating webhook. It adds a soft `nodeAffinity` toward the nodes that already
hold a pod's data, so the pod moves, not the volume. `dataLocality: best-effort` works the other way and copies
the whole volume on every pod move. [05_storage.md](05_storage.md) rejects that for any volume that can grow.

How to opt a workload in and check it: [runbooks/15_replica_affinity.md](runbooks/15_replica_affinity.md).

| | |
|---|---|
| App | `longhorn-replica-affinity`, wave 3 |
| Wrapper chart | `argo_apps/platform/charts/03_longhorn_replica_affinity/` |
| Upstream chart | `oci://ghcr.io/yama6a/charts/longhorn-replica-affinity` |
| Behaviour, values, metrics | [upstream README](https://github.com/yama6a/longhorn-replica-affinity) |

## Decisions

- **Opt-in by label, soft preference.** The webhook uses `weight: 30`, below a workload's own weight-100
  affinity, so a workload's own placement still wins.
- **Fail open.** With the webhook down, pods schedule as if it did not exist. Placement degrades, nothing breaks.
- **No descheduler.** Existing pods move into place as they restart for normal reasons. A descheduler would
  restart Postgres primaries on its own decision.
- **The wrapper adds only a `CiliumNetworkPolicy`.** Upstream ships none, because it cannot know the policy
  engine.
