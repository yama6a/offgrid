# Replica affinity

A Longhorn PV attaches over the network and carries no `nodeAffinity`. So the scheduler cannot see which 2 of
the 4 nodes hold a volume's replicas. Pods land on any node, and their IO crosses the 1GbE link for the life of
the pod.

Measured before this app ran:

| Volumes | Count |
|---|---|
| attached | 31 |
| with no replica on their pod's node | 16 (52%) |
| of those, on the amd64 worker | 12 |

- The amd64 worker joined after the Pis.
- `replica-auto-balance` is `disabled`, so no replicas moved to it.
- The scheduler still placed pods there for its larger CPU and memory.

A mutating webhook adds a soft `nodeAffinity` toward nodes that already hold the data. So the pod moves, not the
volume. `dataLocality: best-effort` works the other way. It copies the full volume on every pod move.
[05_storage.md](05_storage.md) rejects it for any volume that can grow.

| | |
|---|---|
| App | `longhorn-replica-affinity`, wave 3 |
| Wrapper chart | `argo_apps/platform/charts/03_longhorn_replica_affinity/` |
| Upstream chart | `oci://ghcr.io/yama6a/charts/longhorn-replica-affinity`, same version as its image |
| Behaviour, values, metrics | [upstream README](https://github.com/yama6a/longhorn-replica-affinity) |

The wrapper adds one thing: the `CiliumNetworkPolicy`. Upstream ships none, because it cannot know which policy
engine a cluster runs. Renovate tracks the dependency through `Chart.yaml` and `Chart.lock`, like every other
chart here.

## What this cluster sets

All other values are upstream defaults.

| Value | Why |
|---|---|
| `weight: 30` | stays under a hand-written weight-100 `nodeAffinity`, so a workload's own placement still wins |
| `tls.mode: self-signed` | no ordering constraint on cert-manager at wave 3. See below |
| `priorityClassName: platform-critical` | an evicted webhook drops the preference with no error anywhere |
| `podMonitor.enabled: true` | sends `lra_*` metrics to VictoriaMetrics |

## The ArgoCD exception

In `self-signed` mode the webhook writes its own `caBundle`. So the Application carries:

```yaml
ignoreDifferences:
  - group: admissionregistration.k8s.io
    kind: MutatingWebhookConfiguration
    name: longhorn-replica-affinity
    jqPathExpressions: [".webhooks[].clientConfig.caBundle"]
```

Without it, `selfHeal` clears `caBundle` on every sync, and the apiserver stops trusting the endpoint. With
`failurePolicy: Ignore` this fails silently. No error shows anywhere, and placement goes back to random. Check
this first if locality stops working.

## Opt a workload in

The webhook mutates only pods with the label `longhorn-replica-affinity/enabled: "true"`. The label must reach
the pod. Where you set it depends on what creates the pod:

| Owner | Where |
|---|---|
| plain Deployment | `spec.template.metadata.labels` |
| CNPG (`lib/helm/pg-cluster`) | `Cluster.spec.inheritedMetadata.labels` |
| RabbitMQ | `RabbitmqCluster.spec.override.statefulSet.spec.template.metadata.labels` |
| OpsTree Redis (`lib/helm/redis-instance`) | the CR's pod label field |
| VictoriaMetrics | `spec.podMetadata.labels` |

- `spec.affinity` is immutable. A new label has no effect until the pod is recreated.
- Existing pods move into place as they restart for normal reasons.
- No descheduler evicts them. A descheduler would restart Postgres primaries on its own decision.

Label a workload even when it can never move, for example a pod pinned to one node by a device-plugin resource.
The label tells the reconciler to bring a replica to that node instead. This is a one-time copy, capped by
`maxMoveBytes`.

## Verify

```bash
kubectl -n longhorn-replica-affinity get pods
kubectl get mutatingwebhookconfiguration longhorn-replica-affinity \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | head -c 40   # the webhook wrote this itself

kubectl -n <ns> get pod <pod> \
  -o jsonpath='{.spec.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution}' | jq
```

The injected hostnames must be the nodes that hold that pod's replicas. For an RWX volume, it is the
share-manager's node:

```bash
kubectl -n longhorn-system get pods -l longhorn.io/component=share-manager -o wide
```

Test fail-open. Pods must still schedule when the webhook is down:

```bash
kubectl -n longhorn-replica-affinity scale deploy longhorn-replica-affinity-webhook --replicas=0
kubectl -n sample-user-manager rollout restart deploy/sample-user-manager   # must still schedule
kubectl -n longhorn-replica-affinity scale deploy longhorn-replica-affinity-webhook --replicas=2
```

Locality ratio: `sum(lra_volume_local) / count(lra_volume_local)`. For an RWX volume the attached node is the
share-manager's, so the metric reports the share-manager hop. The `access_mode` label separates the two cases.

Alerts in `05_grafana/files/alerts/replica-affinity.yaml`:

- the webhook stops reporting
- locality stays under 60% for 6h
- the reconciler will not move a volume
