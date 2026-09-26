# Losing a node: what the platform does about it

The tooling that built your cluster owns the machine side of a node loss. That tooling drops a reflashed node's
stale etcd member, re-applies its config, and brings the kubelet back. This repo does none of that.

This doc covers the workload side:

- what the workloads do when a machine disappears
- how long they take to recover
- the one step that needs a human afterwards

## Loss heals itself, replacement needs one step

Every volume here belongs to Longhorn, not to one machine ([05_storage.md](05_storage.md)). So a dead machine is a
scheduling problem, not a data problem. The pod reattaches its volume on a surviving node and starts. There is
nothing to delete and nothing to restore.

A human is needed when a reflashed machine comes back under the same name. Longhorn's node CR holds the old disk
UUID, and the fresh filesystem carries a new one. Longhorn refuses the disk, so it never uses the wrong one. Run
`make reconcile-storage NODE=<host>` once your node tooling has the machine back.

## The dead-node watcher

Kubernetes waits about six minutes before it gives one machine's volumes to another. The wait covers the case
where the node is alive and still writes to them. That default is wrong for this cluster. The machines sit in
one room, and a machine that stops answering is dead.

The taint `node.kubernetes.io/out-of-service:NoExecute` skips the wait. It states that the machine is gone. On
that statement, Kubernetes force-deletes the node's pods and releases their volumes at once. Kubernetes never
applies this taint itself, because only an operator can make that call.

`dead-node-watcher` makes the call, using time spent NotReady as the evidence. It lives in
`argo_apps/platform/charts/02_dead_node_watcher`, wave 2.

Timeline for a machine that dies:

| Step | Time |
|---|---|
| Kubernetes marks the node NotReady | ~40s |
| the watcher's grace period | 60s |
| displaced pod runs on a surviving node | about 2 min in total, against 6+ min without the watcher |

Reboots are out of scope. A node reboot on this hardware takes ~90s. That is shorter than the NotReady delay
plus the 60s grace. So the node returns before the watcher acts, and the volume never has to move. On a
`talosctl reboot --mode force` the watcher logged nothing. It acts only when a machine is down for good or for
many minutes.

The watcher has three guards:

- **It never touches a Ready node.** This protects an ordinary drain. `kubectl drain` and a rolling upgrade
  cordon a machine that is still up. A Ready node never reaches the taint code. A cordon alone is not a reason
  to skip. A node that is being wiped is cordoned and never comes back. Skipping it left volumes stuck for 5.5
  minutes in a test.
- **It does nothing when more than one node is NotReady.** That is a cluster event, not a machine failure.
  There is no node to reschedule to, and a loop must not force-detach everything at once.
- **It removes the taint when the node is Ready again.** Kubernetes requires this, and nothing else does it. A
  node that keeps the taint takes no pods back. Good node tooling also clears the taint next to its own
  `uncordon`. Then an un-taint does not depend on this loop being alive.

Cordoned nodes get the taint too. So a rolling upgrade taints each machine during its reboot. That force-deletes
the three Longhorn DaemonSet pods there:

- `longhorn-manager`
- `longhorn-csi-plugin`
- `engine-image`

Cilium, node-exporter, the log collector and any host-network node agent tolerate every taint. The Longhorn pods
come back when the machine returns. The drain already moved everything else, so nothing else is left to evict.

This is safe because Longhorn refuses to attach one volume in two places. That double attach is the corruption
the six-minute wait exists to prevent.

## RWX volumes fail over on their own path

An RWX volume ([05_storage.md](05_storage.md)) does not use the steps above. Its consumers mount NFS from a
share-manager pod. If the share-manager's node dies, every consumer breaks at once, on any node. Recovery means
Longhorn moves the share-manager. The consumers do not reschedule.

`rwxVolumeFastFailover` holds a lease on the share-manager. Longhorn acts when the lease expires, and does not
wait for pod eviction.

This path is not measured yet, because no RWX volume has a consumer. Time it when one does.

```bash
kubectl -n dead-node-watcher logs deploy/dead-node-watcher   # one line per decision
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

The watcher pod sets `tolerationSeconds: 0` on the not-ready and unreachable taints. So Kubernetes evicts it the
moment its own machine goes NotReady, and its ReplicaSet starts a replacement elsewhere. Without this, the
watcher would sit on the dead machine for the same 5 minutes it exists to avoid.

## What survives

| Storage | Used by | On machine loss | On machine replacement |
|---|---|---|---|
| `longhorn-r2-ephemeral` | Postgres, Redis, monitoring stores, ntfy | volume reattaches on a surviving node | data survives and replicas rebuild. The node's disk record does not. Run `make reconcile-storage` |
| `longhorn-r2-ephemeral-local` | RabbitMQ | same, plus Longhorn builds a fresh local replica there | same |
| none | stateless Deployments | reschedule on their own | nothing |

Hard anti-affinity allows at most one copy per machine. A workload that already has one copy on every machine
has nowhere to put a displaced copy:

| Workload | Machine dies | Machine returns |
|---|---|---|
| `sample-user-manager-analytics`, Redis, monitoring stores, ntfy | moves to a surviving node in ~2 min | nothing to do |
| `sample-user-manager-db`, 3 instances | a standby is promoted, then serves on 2 of 3 | the third instance schedules back on its own |
| RabbitMQ, 3 brokers | serves on 2 of 3, no messages lost | the broker returns with its own data |

Measured write outage. Each test killed the machine that held both the HA database primary and the single
instance. A probe inserted a row every 200ms.

| Failure | HA writes | Single instance | Watcher |
|---|---|---|---|
| ethernet unplugged, a real unplanned death | 184s | 191s | fired at t+116s |
| `talosctl reset`, watcher skipping cordoned nodes | 328s | 402s | skipped, node was cordoned |
| `talosctl reboot --mode force`, back in ~90s | 97s | 244s | correctly never fired |

The taint saves 144s on the HA cluster and 211s on the single instance.

Breakdown of the unplugged-cable case:

| Step | Time |
|---|---|
| Kubernetes marks the node `Unknown` | 53s |
| the watcher's grace period | 62s |
| CNPG promotes, and the single instance reattaches and finishes crash recovery | ~70s |

Both outages last minutes, not seconds. Synchronous replication means no lost transactions. It does not mean a
fast failover. The promoted standby holds every acknowledged commit, but the application still sees ~3 minutes of
failed writes. A tighter target needs a client that retries. A storage change will not help.

### A planned drain: about 20s of write outage

A rolling upgrade cordons and drains each machine before it reboots it. CNPG switches the primary away first. It
puts a second PDB on the primary alone, with `disruptionsAllowed: 0`. So the eviction fails until the handover is
done.

Measured on a graceful drain of the machine that held the primary, with an insert every 100ms:

| Settings | Write outage |
|---|---|
| CNPG defaults, 1 operator replica | 64s |
| `smartShutdownTimeout: 15` | 41s |
| `smartShutdownTimeout: 15`, 2 operator replicas | 19.6s |

1. **`smartShutdownTimeout` defaults to 180s.** In shutdown stage 1, Postgres refuses new connections but waits
   for existing ones. An app that holds an idle pooled connection never closes it.
   - With the default, the drain passes the 120s graceful window. Kubernetes force-deletes the pod, and CNPG does
     a hard failover instead of a switchover.
   - At 15s, the old primary is down in ~3s and the drain finishes in ~33s. That is inside the window, so the
     force-delete never fires. The drain itself needs no change.
2. **The operator runs 2 replicas.** The `-rw` Service selects `cnpg.io/instanceRole=primary`, and only the
   operator moves that label.
   - While the operator is down, no endpoint accepts writes, even when a promoted Postgres is up.
   - With one replica, the drain evicts the only pod that can finish the switchover. That left a 33s gap between
     "new primary accepts connections" and "labels swapped".
3. **Nothing else is tunable.** The remaining ~20s is CNPG's own cadence: about 7s to decide, 6s for Postgres to
   promote and replay, and 6s to relabel. The Cluster spec cannot change it.

So ~20s is the practical floor here, not the 2-5s that "negligible downtime" suggests. It is a real
interruption. While no pod carries the primary label, the `-rw` Service has no endpoints. A client retry does
not hide it. The client retries against a closed port for 20s.

The barman-cloud plugin still runs one replica, so it can still stall a switchover. It holds a lease like the
operator does. It ships as a vendored upstream manifest with `replicas` hardcoded.

Keep your drain's graceful timeout at or above the ~33s a switchover needs. A primary that is force-deleted early
turns a ~20s switchover into a ~60s failover.

### Force-detaching a live machine is safe

The unplugged cable is the case the six-minute wait exists for:

- The machine keeps running.
- Postgres keeps its volume mounted.
- Its `longhorn-manager` cannot reach the API, so nothing can tell it to stop.

The taint force-attaches the same volume on a surviving node. For a short time, two engines each hold a copy.

What the test showed:

- Longhorn set `failedAt` on the isolated machine's replica 5 seconds after the taint landed. It kept serving
  from the surviving replica.
- On rejoin, Longhorn rebuilt the fenced replica from the authoritative one.
- CNPG discarded the diverged former primary. It rebuilt it from a base backup on the old timeline, then
  streamed from the new one.
- A 50-row checksum taken before the pull was byte-identical afterwards.

Two costs, both self-healing:

- The taint force-deleted the returning machine's Longhorn DaemonSet pods. So the first pod scheduled back there
  fails to mount for ~35s, until the CSI plugin registers again. The error is
  `CSINode <node> does not contain driver driver.longhorn.io`.
- An instance that cannot reschedule under hard anti-affinity stays Pending for the whole outage. This is
  correct, but it looks alarming.

The workloads with 3 copies stay available but lose their spare until the machine is repaired. A second loss in
that window stops writes. A 4th machine removes this risk.

## Reconciling a replaced node

Run this after your node tooling reports the rejoined machine Ready.

```bash
make reconcile-storage NODE=talos-cp3   # idempotent. Re-run it to get past a step that needed more time
# then re-spread the stateless Deployments with your node tooling, once everything is healthy
```

`reconcile_storage_after_rejoin.sh` does three things in order:

1. It checks that every volume still has a healthy replica on another node.
2. It drops the stale replica records on the returned node.
3. It resets the node's disk record.

Why the disk record needs a reset: Longhorn stores the disk's UUID in two places. One is the node CR, the other
is `longhorn-disk.cfg` on the disk itself. The reflash made a fresh filesystem. So the manager wrote a new cfg
with a new UUID, and the CR still holds the old one:

```
Ready=False  DiskFilesystemChanged  record diskUUID doesn't match the one on the disk
```

The node itself reports `Ready`, so you only see this when you look at the disk.

### By hand, if the script stops half way

1. Check that each volume has a `running` replica on another node. Then delete the stale replicas:

   ```bash
   kubectl -n longhorn-system get replicas.longhorn.io \
     -o custom-columns=VOL:.spec.volumeName,NODE:.spec.nodeID,STATE:.status.currentState | sort   # one running elsewhere per volume
   kubectl -n longhorn-system get replicas.longhorn.io \
     -o jsonpath='{range .items[?(@.spec.nodeID=="talos-cp3")]}{.metadata.name}{"\n"}{end}' \
     | xargs -r kubectl -n longhorn-system delete replicas.longhorn.io
   ```

2. Disable the disk, remove it, and add it again with the same spec as a healthy node:

   ```bash
   D=$(kubectl -n longhorn-system get nodes.longhorn.io talos-cp3 \
       -o go-template='{{range $k,$v := .spec.disks}}{{$k}}{{end}}')
   SPEC=$(kubectl -n longhorn-system get nodes.longhorn.io talos-cp1 -o jsonpath='{.spec.disks}')

   kubectl -n longhorn-system patch nodes.longhorn.io talos-cp3 --type merge \
     -p "{\"spec\":{\"disks\":{\"$D\":{\"allowScheduling\":false}}}}"
   kubectl -n longhorn-system patch nodes.longhorn.io talos-cp3 --type json \
     -p "[{\"op\":\"remove\",\"path\":\"/spec/disks/$D\"}]"
   kubectl -n longhorn-system patch nodes.longhorn.io talos-cp3 --type merge \
     -p "{\"spec\":{\"disks\":$SPEC}}"        # retry this one, see below
   ```

3. Confirm a new diskUUID, `Ready=True` and `Schedulable=True`:

   ```bash
   kubectl -n longhorn-system get nodes.longhorn.io talos-cp3 -o jsonpath=\
   '{range .status.diskStatus.*}{.diskUUID}{" "}{range .conditions[*]}{.type}={.status} {end}{" avail="}{.storageAvailable}{"\n"}{end}'
   ```

Gotchas in step 2:

- **Order matters.** The validating webhook refuses to remove a disk that is still schedulable. So
  `allowScheduling: false` must land first.
- **A merge patch cannot remove the disk.** `{"disks":{}}` does nothing, because JSON merge patch deletes a key
  only when it is set to `null`. Use a json patch `remove` op instead.
- **The re-add fails once.** The error is
  `spec and status of disks on node talos-cp3 are being syncing and please retry later`. The manager has not
  finished with the removal yet. Wait ~10s and repeat the command.

Rebuilds do not start the moment the node returns. `replica-replenishment-wait-interval` is 1800. So Longhorn
keeps a failed replica for 30 minutes before it replaces it, in case the node comes back with its data. Deleting
the stale replicas in step 1 ends that wait.

Verify that everything converged:

```bash
kubectl get pods -A | grep -Ev 'Running|Completed'                   # empty
kubectl get clusters.postgresql.cnpg.io -A                           # "Cluster in healthy state"
kubectl -n rabbitmq get rabbitmqcluster rabbitmq                     # AllReplicasReady True
kubectl -n longhorn-system get volumes.longhorn.io                   # no degraded, no faulted
kubectl -n longhorn-system get nodes.longhorn.io -o wide             # every node and its disk Ready
kubectl -n argocd get applications                                   # all Synced and Healthy
```

## Per subsystem

### Longhorn

Replicas rebuild from the surviving nodes on their own. The disk record does not. After a reflash you must
reset it, as described above. It is the one Longhorn step that needs a human.

Once the disk is back, watch the replicas and do not touch them:

```bash
kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=\
NAME:.metadata.name,ROBUSTNESS:.status.robustness,STATE:.status.state
```

| Robustness | Meaning | Action |
|---|---|---|
| `degraded` | a rebuild is running | expected, wait |
| `faulted` | every replica is gone | restore from S3 with `make restore-longhorn`, for the one class that has backups |

Do not start work on a second node until robustness is `healthy` everywhere. With 2 replicas on 3 nodes, a
running rebuild means some volume is one failure away from `faulted`.

Expect the replaced node to stay empty afterwards:

- `replica-auto-balance` is `disabled`, so Longhorn never moves a healthy replica.
- Every volume rebuilt during the outage placed its replicas on the two surviving nodes.
- This is not a fault. But if either of those two nodes now fails, every volume degrades at once. All of them
  then rebuild onto the one empty node.
- To spread replicas back over time, set `replica-auto-balance: best-effort` in `02_longhorn`'s values.

### CNPG

Both modes recover on their own, for different reasons.

- **`highAvailability: true`.** The primary dies with the machine, and a synchronous standby is promoted. Each
  commit waited for that standby to flush. So the standby cannot miss a transaction the application saw as
  committed. Writes continue on 2 of 3. The third instance stays Pending until the machine returns, because
  `podAntiAffinityType: required` does not put two instances on one node.
- **`highAvailability: false`.** The single instance reschedules onto a surviving node and reattaches the same
  volume. Postgres replays WAL on startup, as it does after any `kill -9`, and comes up consistent. There is
  nothing to restore.

```bash
kubectl -n <ns> get cluster <cluster> -w      # back to "Cluster in healthy state"
```

CNPG does not leave a primary on a cordoned node. If you cordon a node to move a pod, CNPG switches over first.
So the instance you meant to move may not be the one that moves. Check before and after:

```bash
kubectl get pods -l cnpg.io/podRole=instance -A -L cnpg.io/instanceRole
```

The S3 catalog is still the answer for real data loss:

- a dropped table
- a bad migration
- every replica of a volume lost at once

Run `make restore-cnpg`. Details are in [10_backups.md](10_backups.md). Node recovery does not use it.

### RabbitMQ

Quorum queues tolerate one broker down out of three, so no messages are at risk. The broker's volume belongs to
Longhorn. So the replacement pod reattaches the same data and rejoins with its Raft log intact. You run no
`forget_cluster_node` and no `join_cluster`, and you wipe nothing.

The startup probe (`reached-target-cluster-size`) returns 503 while the broker catches up. It restarts the
container once. That is normal, and one restart is not a failure. Confirm from a healthy peer:

```bash
kubectl -n rabbitmq exec rabbitmq-server-1 -c rabbitmq -- rabbitmqctl cluster_status
```

When all three brokers show under `Running Nodes`, the broker is back, even if the pod is not Ready yet.

Never wipe a broker's PVC as a repair step. Raft tracks members by name, together with the log each one
should have. A member that returns under its old name with an empty log is a contradiction. The surviving
brokers refuse it and do not guess.

If you must replace a broker's storage:

1. Run `stop_app` on the broker.
2. Run `forget_cluster_node` from a peer.
3. Wipe the volume.
4. Run an explicit `join_cluster`.

`rabbitmq-server-0` is the worst case. `rabbit_peer_discovery_k8s` auto-clusters it onto itself. So after a
wipe it comes back with divergent history, not an empty log. Keeping the volume avoids all of this.

### Redis

Nothing to do. Both persistence modes run on Longhorn, so the volume follows the pod to a surviving node.
Redis is unavailable for a short time while it reschedules. [09_redis.md](09_redis.md) accepts this trade-off.

## Retiring a node for good

Your node tooling owns the etcd and Kubernetes side. On a 3-node cluster, retiring a node costs this here:

- **Longhorn returns to `healthy` but has no spare.** 2 replicas with hard anti-affinity fit exactly on 2
  nodes, one each. The next node failure leaves volumes `degraded`, with no node to rebuild onto. The 2-replica
  choice exists to avoid that state ([05_storage.md](05_storage.md)).
- **`sample-user-manager-db` and RabbitMQ stay at 2 of 3.** They have no spare either. Both still serve, and
  neither tolerates another loss.

Two nodes is not a supported steady state here. Treat it as a countdown, not a configuration.

## What self-heals, and what does not

Alerts cover detection. These all fire on a node loss: `Node NotReady`, `CNPG instance not ready`,
`RabbitMQ node down`, `Container stuck (crashloop)`, `StatefulSet has no ready replicas` and
`Longhorn volume degraded`. See [06_monitoring.md](06_monitoring.md).

| Layer | Self-heals a machine loss | Self-heals a machine replacement |
|---|---|---|
| Longhorn replicas | yes, the manager rebuilds | yes |
| Longhorn disk record | n/a | no. The CR's diskUUID outlives the filesystem, and Longhorn does not guess which is right |
| CNPG, HA | yes, a synchronous standby is promoted | yes |
| CNPG, single instance | yes, the volume moves with the pod | yes |
| RabbitMQ | yes, on 2 of 3. The broker returns with its data | yes |
| Redis, monitoring stores, ntfy | yes, through Longhorn | yes |
| Stateless Deployments | yes | yes |

The one possible improvement is a 4th machine. Every "serves on 2 of 3, no spare" row above then becomes a full
recovery, because a displaced copy has a node to go to under hard anti-affinity.

The one remaining manual step is the disk record. It only exists because a reflashed machine returns under the
same name. One idempotent script handles it, and it is not on the availability path.
