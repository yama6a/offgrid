# Replica affinity

A Longhorn PV is network-attachable and carries no `nodeAffinity`, so the scheduler cannot see which 2 of the 4
nodes hold a volume's replicas. Pods land anywhere; their IO crosses the 1GbE for the life of the pod.

Measured before deploying this: **16 of 31 attached volumes (52%) had no replica on their pod's node**, 12 of
them on `tc-w1`. That node joined after the Pis and `replica-auto-balance` is `disabled`, so replicas never
followed it while the scheduler kept placing pods there for its 6 CPUs and 16 GiB.

A mutating webhook adds a soft `nodeAffinity` toward nodes that already hold the data, so the pod moves instead
of the volume. `dataLocality: best-effort` is the other direction and costs a full volume transfer per pod
move; [05_storage.md](05_storage.md) already rejects it for anything that can grow.

| | |
|---|---|
| App | `longhorn-replica-affinity`, wave 3 |
| Wrapper chart | `argo_apps/platform/charts/03_longhorn_replica_affinity/` |
| Upstream chart | `oci://ghcr.io/yama6a/charts/longhorn-replica-affinity`, same version as its image |
| Behaviour, values, metrics | [upstream README](https://github.com/yama6a/longhorn-replica-affinity) |

The wrapper adds one thing: the `CiliumNetworkPolicy`. Upstream ships none, since it cannot know the policy
engine. Renovate tracks the dependency through `Chart.yaml`/`Chart.lock` like every other chart here.

## What this cluster sets

Everything else is an upstream default.

| Value | Why |
|---|---|
| `weight: 30` | must stay under plex's weight-100 nodeAffinity in `workloads/charts/media/templates/plex.yaml` |
| `tls.mode: self-signed` | no cert-manager ordering constraint at wave 3; see below |
| `priorityClassName: platform-critical` | an evicted webhook drops the preference with no error anywhere |
| `podMonitor.enabled: true` | feeds `lra_*` to VictoriaMetrics |

## The ArgoCD exception

In `self-signed` mode the webhook patches its own `caBundle`, so the Application carries:

```yaml
ignoreDifferences:
  - group: admissionregistration.k8s.io
    kind: MutatingWebhookConfiguration
    name: longhorn-replica-affinity
    jqPathExpressions: [".webhooks[].clientConfig.caBundle"]
```

Without it, `selfHeal` blanks `caBundle` every sync and the apiserver stops trusting the endpoint. With
`failurePolicy: Ignore` that fails silently: no error anywhere, placement just goes back to random. **Check
this first if locality stops working.**

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
place on ordinary churn. No descheduler evicts them, deliberately: it would decide on its own to restart
Postgres primaries.

Plex is labelled even though it can never move, since the `gpu.intel.com/i915` limit exists only on `tc-w1`.
The label is what tells the reconciler to bring a replica of `plex-config` to it instead: a 0.7Gi copy, once.

## Verify

```bash
kubectl -n longhorn-replica-affinity get pods
kubectl get mutatingwebhookconfiguration longhorn-replica-affinity \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | head -c 40   # the webhook wrote this itself

kubectl -n media get pod <pod> \
  -o jsonpath='{.spec.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution}' | jq
```

The injected hostnames must be that pod's replica nodes, or for RWX the share-manager's node
(`kubectl -n longhorn-system get pods -l longhorn.io/component=share-manager -o wide`).

Fail-open, the one thing that must not be wrong:

```bash
kubectl -n longhorn-replica-affinity scale deploy longhorn-replica-affinity-webhook --replicas=0
kubectl -n media rollout restart deploy/sonarr-yama    # must still schedule, just without the preference
kubectl -n longhorn-replica-affinity scale deploy longhorn-replica-affinity-webhook --replicas=2
```

Scoreboard: `sum(lra_volume_local) / count(lra_volume_local)`. For RWX that reports the share-manager hop, since
its attached node is the share-manager's; the `access_mode` label separates the two.

Alerts in `05_grafana/files/alerts/replica-affinity.yaml`: webhook not reporting, locality under 60% for 6h,
and a volume the reconciler will not move.
