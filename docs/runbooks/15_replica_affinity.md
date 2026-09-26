# Runbook: replica affinity

Why the webhook exists: [../15_replica_affinity.md](../15_replica_affinity.md).

## Opt a workload in

1. Put the label `longhorn-replica-affinity/enabled: "true"` on the pod. Where it goes depends on the owner:

   | Owner | Where |
   |---|---|
   | plain Deployment | `spec.template.metadata.labels` |
   | CNPG (`lib/helm/pg-cluster`) | `Cluster.spec.inheritedMetadata.labels` |
   | RabbitMQ | `RabbitmqCluster.spec.override.statefulSet.spec.template.metadata.labels` |
   | OpsTree Redis (`lib/helm/redis-instance`) | the CR's pod label field |
   | VictoriaMetrics | `spec.podMetadata.labels` |

2. Recreate the pod, or wait for a normal restart. `spec.affinity` is immutable, so a running pod keeps its old
   placement.

Label a workload even when it can never move, such as a pod pinned by a device-plugin resource. The reconciler
then copies a replica to that node once, capped by `maxMoveBytes`.

## Verify

1. Check that the webhook runs and wrote its own `caBundle`:

   ```bash
   kubectl -n longhorn-replica-affinity get pods
   kubectl get mutatingwebhookconfiguration longhorn-replica-affinity \
     -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | head -c 40
   ```

2. Check a pod's injected affinity. The hostnames must be the nodes that hold its replicas. For an RWX volume
   it is the share-manager's node.

   ```bash
   kubectl -n <ns> get pod <pod> \
     -o jsonpath='{.spec.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution}' | jq
   kubectl -n longhorn-system get pods -l longhorn.io/component=share-manager -o wide
   ```

3. Test fail-open. Pods must still schedule while the webhook is down:

   ```bash
   kubectl -n longhorn-replica-affinity scale deploy longhorn-replica-affinity-webhook --replicas=0
   kubectl -n sample-user-manager rollout restart deploy/sample-user-manager   # must still schedule
   kubectl -n longhorn-replica-affinity scale deploy longhorn-replica-affinity-webhook --replicas=2
   ```

4. Read the locality ratio in Grafana: `sum(lra_volume_local) / count(lra_volume_local)`. The `access_mode`
   label separates RWX volumes, which report the share-manager hop.

## Locality stopped working

Check the `caBundle` first, with step 1 above. An empty one means Argo CD cleared it, and the webhook fails
silently. The Application's `ignoreDifferences` on `caBundle` prevents that. Confirm it is still there.
