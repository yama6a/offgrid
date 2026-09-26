# Runbook: node loss

What the platform does on a node loss, and why: [../13_node_loss.md](../13_node_loss.md).

## Check the dead-node watcher

```bash
kubectl -n dead-node-watcher logs deploy/dead-node-watcher   # one line per decision
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

## Reconcile a replaced node

Run this after your node tooling reports the rejoined machine Ready.

1. Reset the node's storage. The script is idempotent, so re-run it past a step that needed more time.

   ```bash
   make reconcile-storage NODE=talos-cp3
   ```

2. Once everything is healthy, spread the stateless Deployments again with your node tooling.
3. Check that everything converged:

   ```bash
   kubectl get pods -A | grep -Ev 'Running|Completed'                   # empty
   kubectl get clusters.postgresql.cnpg.io -A                           # "Cluster in healthy state"
   kubectl -n rabbitmq get rabbitmqcluster rabbitmq                     # AllReplicasReady True
   kubectl -n longhorn-system get volumes.longhorn.io                   # no degraded, no faulted
   kubectl -n longhorn-system get nodes.longhorn.io -o wide             # every node and its disk Ready
   kubectl -n argocd get applications                                   # all Synced and Healthy
   ```

### By hand, if the script stops half way

1. Check that each volume has a `running` replica on another node. Then delete the stale replicas on the
   returned node:

   ```bash
   kubectl -n longhorn-system get replicas.longhorn.io \
     -o custom-columns=VOL:.spec.volumeName,NODE:.spec.nodeID,STATE:.status.currentState | sort   # one running elsewhere per volume
   kubectl -n longhorn-system get replicas.longhorn.io \
     -o jsonpath='{range .items[?(@.spec.nodeID=="talos-cp3")]}{.metadata.name}{"\n"}{end}' \
     | xargs -r kubectl -n longhorn-system delete replicas.longhorn.io
   ```

2. Disable the disk, remove it, and add it again with the spec of a healthy node. Keep this order. The webhook
   refuses to remove a schedulable disk, and only a json patch can remove a key.

   ```bash
   D=$(kubectl -n longhorn-system get nodes.longhorn.io talos-cp3 \
       -o go-template='{{range $k,$v := .spec.disks}}{{$k}}{{end}}')
   SPEC=$(kubectl -n longhorn-system get nodes.longhorn.io talos-cp1 -o jsonpath='{.spec.disks}')

   kubectl -n longhorn-system patch nodes.longhorn.io talos-cp3 --type merge \
     -p "{\"spec\":{\"disks\":{\"$D\":{\"allowScheduling\":false}}}}"
   kubectl -n longhorn-system patch nodes.longhorn.io talos-cp3 --type json \
     -p "[{\"op\":\"remove\",\"path\":\"/spec/disks/$D\"}]"
   kubectl -n longhorn-system patch nodes.longhorn.io talos-cp3 --type merge \
     -p "{\"spec\":{\"disks\":$SPEC}}"
   ```

   The re-add fails once with `are being syncing and please retry later`. Wait about 10s and repeat it.

3. Confirm a new diskUUID, `Ready=True` and `Schedulable=True`:

   ```bash
   kubectl -n longhorn-system get nodes.longhorn.io talos-cp3 -o jsonpath=\
   '{range .status.diskStatus.*}{.diskUUID}{" "}{range .conditions[*]}{.type}={.status} {end}{" avail="}{.storageAvailable}{"\n"}{end}'
   ```

## Longhorn after a loss

1. Watch the replicas rebuild. Do not touch them.

   ```bash
   kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=\
   NAME:.metadata.name,ROBUSTNESS:.status.robustness,STATE:.status.state
   ```

   | Robustness | Meaning | Action |
   |---|---|---|
   | `degraded` | a rebuild is running | wait |
   | `faulted` | every replica is gone | `make restore-longhorn`, for the class with backups |

2. Do not start work on a second node until every volume is `healthy`. A running rebuild means some volume is
   one failure away from `faulted`.
3. Expect the replaced node to stay empty. `replica-auto-balance` is `disabled`, so Longhorn never moves a
   healthy replica. To spread replicas back over time, set `replica-auto-balance: best-effort` in
   `02_longhorn`'s values.

## CNPG

```bash
kubectl -n <ns> get cluster <cluster> -w      # back to "Cluster in healthy state"
```

CNPG does not leave a primary on a cordoned node. Before you cordon a node to move a pod, check which instance
is primary. CNPG switches over first, so the instance that moves may not be the one you meant.

```bash
kubectl get pods -l cnpg.io/podRole=instance -A -L cnpg.io/instanceRole
```

## RabbitMQ

1. Expect one container restart on the returning broker. Its startup probe returns 503 while it catches up.
2. Confirm from a healthy peer. The broker is back when all three show under `Running Nodes`, even if its pod
   is not Ready yet.

   ```bash
   kubectl -n rabbitmq exec rabbitmq-server-1 -c rabbitmq -- rabbitmqctl cluster_status
   ```

Never wipe a broker's PVC as a repair step. Raft tracks each member by name and log. The survivors refuse a
member that returns with an empty log. If you must replace a broker's storage:

1. Run `stop_app` on the broker.
2. Run `forget_cluster_node` from a peer.
3. Wipe the volume.
4. Run `join_cluster`.

`rabbitmq-server-0` is the worst case. Peer discovery auto-clusters it onto itself, so after a wipe it returns
with divergent history, not an empty log.
