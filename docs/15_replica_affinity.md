# Replica affinity

A Longhorn PV is network-attachable and carries no `nodeAffinity`, so the scheduler cannot see which 2 of the 4
nodes hold a volume's replicas. Pods land anywhere; their IO crosses the 1GbE for the life of the pod.

Measured before deploying this: **16 of 31 attached volumes (52%) had no replica on their pod's node**, 12 of
them on `tc-w1`. That node joined after the Pis and `replica-auto-balance` is `disabled`, so replicas never
followed it while the scheduler kept placing pods there for its 6 CPUs and 16 GiB.

| | |
|---|---|
| App | `longhorn-replica-affinity`, wave 3 |
| Wrapper chart | `argo_apps/platform/charts/03_longhorn_replica_affinity/` |
| Upstream chart | `oci://ghcr.io/yama6a/charts/longhorn-replica-affinity`, same version as its image |
| Source | [yama6a/longhorn-replica-affinity](https://github.com/yama6a/longhorn-replica-affinity) |

The wrapper adds one thing: the `CiliumNetworkPolicy`. Upstream ships none, since it cannot know the policy
engine. Renovate tracks the dependency through `Chart.yaml`/`Chart.lock` like every other chart here.

## Why not dataLocality

`dataLocality: best-effort` fixes the same problem by rebuilding a full replica onto the pod's node and
dropping a remote one: one whole volume transfer per pod move, which is the traffic being avoided.
[05_storage.md](05_storage.md) already rejects it for anything that can grow.

Moving the pod costs one restart and zero bytes. The volume moves only where the pod physically cannot.

## The webhook

Mutating admission on pod `CREATE`. Per PVC the pod mounts, finds the nodes with a running replica and appends
a `preferredDuringSchedulingIgnoredDuringExecution` term for each, weighted by how many of the pod's volumes
that node holds.

| Property | Value |
|---|---|
| `failurePolicy` | `Ignore`. This optimises placement and must never be able to block it |
| `objectSelector` | the opt-in label, so the apiserver never calls it for anything else |
| `namespaceSelector` | excludes `kube-system`, `longhorn-system` and its own namespace |
| weight | 30 per volume, multiplied by the count, capped at 100 |
| RWX consumers | target the share-manager's node, not the replica nodes |
| share-manager | placed onto a node that already holds a replica of the volume it serves |

Weight 30 is under 100 so plex's hand-written weight-100 preference for the amd64 box
(`argo_apps/workloads/charts/media/templates/plex.yaml`) keeps outranking it.

### RWX: two hops, both fixed by moving a pod

```
consumer  ->  share-manager  ->  replica
          (1)                (2)
```

1. Consumers preferring the share-manager's node collapses this one. That is what puts qbittorrent on the node
   serving `media-downloads`.
2. The share-manager preferring a node that already holds a replica collapses this one, for every consumer of
   that volume at once.

Both are pod moves; the volume never moves. `media-downloads` is the largest thing on the cluster and it is
shared, so copying it to chase the share-manager would be the worst trade available. The reconciler refuses to
touch RWX at all and reports `lra_volume_unfixable{reason="rwx-share-manager-moves"}`. Longhorn documents
`strict-local` as incompatible with RWX anyway.

Hop 2 needs a webhook entry inside `longhorn-system`. It is a separate entry, not a hole in the namespace
exclusion: its `objectSelector` is the share-manager label, so the apiserver never calls this for any other
Longhorn pod. `failurePolicy: Ignore` still applies.

No API calls on the admission path. Informers hold the replica map in memory, and `/healthz` is 503 until they
are warm, so a pod never serves admission while it would answer "no local replica" for everything.

## The reconciler

For an **RWO** pod pinned by a hard constraint that can never move to its data. Plex is the live case: the
`gpu.intel.com/i915` limit exists only on `tc-w1`, so the scheduler has exactly one candidate, while
`plex-config`'s replicas both sit on Pis. RWX volumes are never moved; see above.

The opt-in label is the test: a labelled pod still off its data means the preference lost to something hard.
For those:

1. Park the volume's current `dataLocality` in an annotation.
2. Set `best-effort`. Longhorn rebuilds a replica onto the pod's node.
3. Once it is running, restore the parked value and clear the annotation.

Step 3 is the point. Leaving `best-effort` on re-enables volume-follows-pod forever, dragging a copy on every
future reschedule. Restoring the parked value rather than a hardcoded `disabled` keeps RabbitMQ's
`longhorn-r2-ephemeral-local` volumes on `best-effort`, their intended steady state. The annotation lives on
the object, so a restart mid-flip still restores correctly.

Guards, both upstream defaults:

| Guard | Effect |
|---|---|
| `dwell: 30m` | a rolling update or node drain never triggers a copy |
| `maxMoveBytes: 5Gi` | actual thin size, not the provisioned ceiling; every RWO volume here is under 3Gi |

For plex: a 0.7Gi copy, about 6 seconds on 1GbE, once.

## Opting a workload in

Nothing is mutated without the pod label `longhorn-replica-affinity/enabled: "true"`. It must reach the pod,
and where that lives depends on who creates it:

| Owner | Where |
|---|---|
| plain Deployment | `spec.template.metadata.labels` |
| CNPG (`lib/helm/pg-cluster`) | `Cluster.spec.inheritedMetadata.labels` |
| RabbitMQ | `RabbitmqCluster.spec.override.statefulSet.spec.template.metadata.labels` |
| OpsTree Redis (`lib/helm/redis-instance`) | the CR's pod label field |
| VictoriaMetrics | `spec.podMetadata.labels` |

`spec.affinity` is immutable, so labelling changes nothing until the pod is recreated. Existing pods drift into
place on ordinary churn: Renovate bumps, Talos upgrades, node reboots. No descheduler evicts them, deliberately:
it would decide on its own to restart Postgres primaries.

## Deliberately not done

- **Moving any volume for an RWX share.** Only pods move for RWX; see above.
- **Multi-replica tuning.** A required `podAntiAffinity` or `DoNotSchedule` spread constraint is a scheduler
  filter and always beats this, which is a score, so cramming past a hard constraint cannot happen. Among nodes
  that survive filtering, the weight-30 terms add to the scheduler's own spread and resource-balance scoring.
  `weight` is the only knob if that ever misbehaves.
- **Hard pinning.** `strict-local`, and `csi-allowed-topology-keys` + `strictTopology`, both write `Required`
  PV nodeAffinity, losing the reattach-on-a-survivor property [05_storage.md](05_storage.md) calls the whole
  reason everything is on Longhorn. PV `nodeAffinity` has no `Preferred` field, hence a webhook.

## TLS

The apiserver calls a mutating webhook only over HTTPS and must trust the cert, so a serving cert and a
published `caBundle` are not optional.

Upstream's `self-signed` mode: the webhook mints its own CA and leaf at startup, stores them in a Secret so
both replicas agree, and patches the CA into its own `MutatingWebhookConfiguration`. No cert-manager, despite
it being right there, to avoid a cross-app ordering constraint at wave 3.

That last write forces an exception on the Application:

```yaml
ignoreDifferences:
  - group: admissionregistration.k8s.io
    kind: MutatingWebhookConfiguration
    name: longhorn-replica-affinity
    jqPathExpressions: [".webhooks[].clientConfig.caBundle"]
```

Without it, `selfHeal` blanks `caBundle` every sync and the apiserver stops trusting the endpoint. With
`failurePolicy: Ignore` that fails silently: no error anywhere, placement just goes back to random. Check this
first if locality stops working. `tls.mode: provided` plus cert-manager is the alternative.

## Verify

```bash
kubectl -n longhorn-replica-affinity get pods
kubectl get mutatingwebhookconfiguration longhorn-replica-affinity \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | head -c 40   # the webhook wrote this itself

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

For an RWX volume, `lra_volume_local` reports the share-manager hop, since its attached node is the
share-manager's. The `access_mode` label separates the two cases.
