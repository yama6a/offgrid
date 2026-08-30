# Replica affinity

Longhorn replicates each volume to 2 of the 4 nodes. The scheduler cannot see which two, because a Longhorn PV
is network-attachable and carries no `nodeAffinity`, so pods land anywhere and about half of them read and
write across the 1GbE for the life of the pod.

Measured before this was deployed: **16 of 31 attached volumes (52%) had no replica on the node their pod ran
on**, 12 of them on `tc-w1`. That node joined after the Pis, and `replica-auto-balance` is `disabled`, so
replicas never followed it while the scheduler kept placing pods there for its 6 CPUs and 16 GiB.

App: `longhorn-replica-affinity` (`argo_apps/platform/charts/03_longhorn_replica_affinity/`), wave 3.
Source and image: [yama6a/longhorn-replica-affinity](https://github.com/yama6a/longhorn-replica-affinity).

## Why not dataLocality

`dataLocality: best-effort` solves the same problem from the other end: it rebuilds a full replica onto the
pod's node, then drops a remote one. That is one whole volume transfer per pod move, which is the traffic this
is trying to avoid. See [05_storage.md](05_storage.md), which already rejects it for anything that can grow.

Moving the pod costs one restart and zero bytes. So the pod follows the data, and the volume only moves in the
one case where the pod physically cannot.

## The webhook

Mutating admission on pod `CREATE`. Per PVC the pod mounts, it finds the nodes with a running replica and
appends a `preferredDuringSchedulingIgnoredDuringExecution` term for each, weighted by how many of the pod's
volumes that node holds.

| Property | Value |
|---|---|
| `failurePolicy` | `Ignore`. This optimises placement and must never be able to block it |
| `objectSelector` | the opt-in label, so the apiserver never calls it for anything else |
| `namespaceSelector` | excludes `kube-system`, `longhorn-system` and its own namespace |
| weight | 30 per volume, multiplied by the count, capped at 100 |
| RWX | targets the share-manager's node, not the replica nodes |

Weight 30 is under 100 on purpose: plex's hand-written weight-100 preference for the amd64 box in
`argo_apps/workloads/charts/media/templates/plex.yaml` has to keep outranking this.

RWX is different because the consumer mounts nfs-ganesha rather than a replica, so the share-manager's node is
the only placement that saves it a hop. That is what puts qbittorrent on the node serving `media-downloads`.

The webhook makes no API calls while admitting. Informers hold the replica map in memory and `/healthz` is 503
until they are warm, so a pod never serves admission while it would answer "no local replica" for everything.

## The reconciler

For a pod pinned by a hard constraint that can never move to its data. Plex is the live case: the
`gpu.intel.com/i915` limit exists only on `tc-w1`, so the scheduler has exactly one candidate, while
`plex-config`'s replicas both sit on Pis.

The opt-in label is the test. A labelled pod that is **still** off its data means the preference lost to
something hard, which is the definition of a pod that cannot move. For those:

1. Park the volume's current `dataLocality` in an annotation.
2. Set `best-effort`. Longhorn rebuilds a replica onto the pod's node.
3. Once it is running, restore the parked value and clear the annotation.

Step 3 is the point. Leaving `best-effort` on would re-enable volume-follows-pod forever, dragging a copy on
every future reschedule. Restoring the **parked** value rather than a hardcoded `disabled` is what keeps
RabbitMQ's `longhorn-r2-ephemeral-local` volumes on `best-effort`, which is their intended steady state. The
annotation is on the object, so a reconciler restart mid-flip still restores the right value.

Two guards, both in `values.yaml`:

- `dwell: 30m`, so a rolling update or a node drain never triggers a copy.
- `maxMoveBytes: 5Gi`, against **actual** thin size, not the provisioned ceiling. Everything on the cluster is
  under 3Gi except `media-downloads` at ~10Gi, so this moves everything that matters and never touches the big
  RWX share.

For plex this is a 0.7Gi copy, about 6 seconds on 1GbE, once.

## Opting a workload in

Nothing is mutated without the pod label `longhorn-replica-affinity/enabled: "true"`. It has to reach the
**pod**, and where that lives depends on who creates it:

| Owner | Where |
|---|---|
| plain Deployment | `spec.template.metadata.labels` |
| CNPG (`lib/helm/pg-cluster`) | `Cluster.spec.inheritedMetadata.labels` |
| RabbitMQ | `RabbitmqCluster.spec.override.statefulSet.spec.template.metadata.labels` |
| OpsTree Redis (`lib/helm/redis-instance`) | the CR's pod label field |
| VictoriaMetrics | `spec.podMetadata.labels` |

`spec.affinity` is immutable, so labelling changes nothing until the pod is recreated. Existing pods drift into
place on ordinary churn: Renovate bumps, Talos upgrades, node reboots. There is deliberately no descheduler
evicting them, because that would decide on its own to restart Postgres primaries.

## Deliberately not done

- **The share-manager's own placement.** Longhorn puts it wherever, including on a node with no replica of the
  volume it serves. Fixing that means mutating pods in `longhorn-system`, which the namespace exclusion forbids
  and which would risk the storage layer to save one hop.
- **Hard pinning.** Longhorn's `strict-local`, and `csi-allowed-topology-keys` + `strictTopology`, both work
  and both write `Required` PV nodeAffinity. That loses the reattach-on-a-survivor property that
  [05_storage.md](05_storage.md) says is the whole reason everything is on Longhorn. PV `nodeAffinity` has no
  `Preferred` field at all, which is why this is a webhook and not a PV mutation.

## Verify

```bash
kubectl -n longhorn-replica-affinity get pods,certificate
kubectl get mutatingwebhookconfiguration longhorn-replica-affinity \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | head -c 40   # cainjector filled it

# what got injected into an opted-in pod
kubectl -n media get pod <pod> \
  -o jsonpath='{.spec.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution}' | jq
```

The injected hostnames must equal the replica nodes for that pod's PVCs, or for an RWX volume the
share-manager's node (`kubectl -n longhorn-system get pods -l longhorn.io/component=share-manager -o wide`).

Fail-open, the one thing that must not be wrong:

```bash
kubectl -n longhorn-replica-affinity scale deploy longhorn-replica-affinity-webhook --replicas=0
kubectl -n media rollout restart deploy/sonarr-yama    # must still schedule, just without the preference
kubectl -n longhorn-replica-affinity scale deploy longhorn-replica-affinity-webhook --replicas=2
```

The scoreboard, before and after:

```bash
kubectl get volumes.longhorn.io -n longhorn-system -o json > /tmp/v.json
kubectl get replicas.longhorn.io -n longhorn-system -o json > /tmp/r.json
jq -n --slurpfile v /tmp/v.json --slurpfile r /tmp/r.json '
  ($r[0].items | group_by(.spec.volumeName)
   | map({key: .[0].spec.volumeName,
          value: [.[] | select(.status.currentState=="running") | .spec.nodeID]})
   | from_entries) as $m
  | [$v[0].items[] | select(.status.state=="attached")
     | {pvc: .status.kubernetesStatus.pvcName, at: .status.currentNodeID,
        reps: ($m[.metadata.name] // [])}]
  | map(.at as $a | . + {hit: (.reps | any(. == $a))})
  | {total: length, hits: (map(select(.hit))|length),
     misses: (map(select(.hit|not))|length)}'
```

Or the same thing from metrics: `sum(lra_volume_local) / count(lra_volume_local)`.

Alerts are in `05_grafana/files/alerts/replica-affinity.yaml`: webhook not reporting, locality under 60% for
6h, and a volume the reconciler has decided it will not move.
