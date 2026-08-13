# Losing a node: what the platform does about it

The machine half of this lives in the OS repo: what `make recover-node` fixes, how a reflashed node rejoins
etcd, and the reset ordering. See
[05_node_recovery.md](https://github.com/yama6a/talos-raspberry-pi5-cluster/blob/main/docs/05_node_recovery.md).

This is the other half. What the workloads do when a machine disappears, how long they actually take, and the
one thing that needs hands afterwards.

## Losing a machine is uneventful; replacing one needs hands

Every volume here is Longhorn's, not any one machine's ([05_storage.md](05_storage.md)). So a machine dying is
a rescheduling problem, not a data problem: the pod reattaches its volume on a survivor and starts. Nothing to
delete, nothing to restore.

What still needs hands is a machine coming BACK under the same name after being reflashed. Longhorn's node CR
holds the old disk UUID and the fresh filesystem carries a new one, so it refuses the disk rather than risk
using the wrong one. `make reconcile-storage NODE=<host>` does it, after the OS repo's `make recover-node`.

## The dead-node watcher

Kubernetes is deliberately slow to hand one machine's disks to another. A node stops answering, and for about
six minutes nothing takes its volumes, in case it is alive and still writing to them. Reasonable default,
wrong for us: our machines are in one room and a dead one is dead.

`node.kubernetes.io/out-of-service:NoExecute` short-circuits it. The taint asserts the machine is genuinely
gone, and on that assertion Kubernetes force-deletes its pods AND releases their volumes at once. Nothing
applies it automatically in Kubernetes itself, on purpose, because only an operator can make that call.
`dead-node-watcher` (`argo_apps/platform/charts/02_dead_node_watcher`, wave 2) makes it, using time-NotReady
as the evidence.

Timeline for a machine that dies: ~40s for Kubernetes to mark it NotReady, then the watcher's 60s grace, so a
displaced pod is running on a survivor in about two minutes instead of six-plus.

**It deliberately does nothing for a reboot.** A Pi 5 Talos reboot is back inside ~90s, which is shorter than
Kubernetes' own NotReady delay plus the 60s grace, so the node returns before the watcher would act and the
volume never needed to move. Measured on a `talosctl reboot --mode force`: the watcher logged nothing at all.
So it earns its keep only when a machine is down for good, or for many minutes.

Three guards, each of which matters:

- **It never touches a Ready node.** That is what protects an ordinary drain: `kubectl drain` and the OS repo's
  `03e` cordon a machine that is still up, and a Ready node cannot reach the taint branch at all. A cordon on
  its own is NOT a reason to skip, because `talosctl reset` cordons a machine that is never coming back, and
  skipping that one measured 5.5 minutes of stuck volumes.
- **It refuses when more than one node is NotReady.** That is a cluster event, not a machine failure: there is
  nowhere to reschedule to, and force-detaching everything at once is not what you want a loop deciding.
- **It removes the taint when the node is Ready again.** Kubernetes requires that and nothing else does it; a
  node that keeps the taint takes no pods back. The OS repo's `03e` and `recover_node.sh` also clear it next to
  their own `uncordon`, so neither depends on this loop being alive to un-taint a machine they just brought
  back.

Cost of dropping the cordon guard: a rolling upgrade now taints each machine during its reboot, which
force-deletes the three Longhorn DaemonSet pods there (`longhorn-manager`, `longhorn-csi-plugin`,
`engine-image`; cilium, nic-keeper, node-exporter and the log collector tolerate every taint). They are
recreated when the machine returns, and the drain already moved everything else, so there is nothing else on it
to evict.

It is safe because Longhorn refuses to attach one volume in two places, which is the corruption the six-minute
wait exists to prevent.

```bash
kubectl -n dead-node-watcher logs deploy/dead-node-watcher   # one line per decision
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

The watcher pod itself sets `tolerationSeconds: 0` on the not-ready and unreachable taints, so it is evicted
the instant its own machine goes NotReady and its ReplicaSet starts a replacement elsewhere. Without that it
would sit on the dead machine for the same 5 minutes it exists to avoid.

## What survives

| Storage | Used by | On machine loss | On machine replacement |
|---|---|---|---|
| `longhorn-r2-ephemeral` | Postgres, Redis, monitoring stores, ntfy | volume reattaches on a survivor | data survives, replicas rebuild. The node's disk RECORD does not: `make reconcile-storage` |
| `longhorn-r2-ephemeral-local` | RabbitMQ | same, plus a fresh local replica is built there | same |
| none | stateless Deployments | reschedule on their own | nothing |

Hard anti-affinity means a workload that already has one copy per machine has nowhere to put a displaced one:

| Workload | Machine dies | Machine returns |
|---|---|---|
| `sample-user-manager-analytics`, Redis, monitoring stores, ntfy | moves to a survivor in ~2 min | nothing to do |
| `sample-user-manager-db`, 3 instances | a standby is promoted, then serves on 2 of 3 | the third instance schedules back by itself |
| RabbitMQ, 3 brokers | serves on 2 of 3, no messages lost | the broker returns with its own data |

Measured outage, in each case killing the machine that held BOTH the db primary and the single instance, and
probing with an insert every 200ms:

| Failure | HA writes | Single instance | Watcher |
|---|---|---|---|
| ethernet unplugged (a real unplanned death) | **184s** | **191s** | fired at t+116s |
| `talosctl reset` (before the guard was narrowed) | 328s | 402s | suppressed by the cordon |
| `talosctl reboot --mode force` (back in ~90s) | 97s | 244s | correctly never fired |

So the taint is worth 144s on the HA cluster and 211s on the single instance. The cable-pull breakdown: 53s for
Kubernetes to mark the node `Unknown`, 62s of the watcher's grace, then ~70s for CNPG to promote and for the
single instance to reattach and finish crash recovery.

Neither number is "seconds". Synchronous replication buys you no LOST transactions, not a fast failover: the
promoted standby is guaranteed to hold every acknowledged commit, and the application still sees ~3 minutes of
failed writes. Anything needing better than that needs a client that retries, not a storage change.

### A planned drain: 64s of write outage down to 20s

The OS repo's `03e` cordons and drains each machine before rebooting it, and CNPG is designed to switch the
primary away first: it puts a second PDB on the primary alone with `disruptionsAllowed: 0`, so the eviction is
REFUSED until the handover is done. Three separate things were defeating that. Measured on a graceful drain of
the machine holding the primary, probed by an insert every 100ms:

| | Write outage |
|---|---|
| originally | 64s |
| after `smartShutdownTimeout: 15` | 41s |
| after the operator went to 2 replicas | **19.6s** |

1. **`smartShutdownTimeout`, default 180s.** Shutdown stage 1 refuses new connections but WAITS for existing
   ones, and an app holding an idle pooled connection never closes it. So the drain blew through `03e`'s 120s
   graceful window, `03e` force-deleted the primary, and CNPG got a hard failover instead of the switchover it
   was trying to perform. At 15s the old primary is down in ~3s and the drain finishes in ~33s, well inside the
   window, so the force-delete never fires and no change to `03e` was needed.
2. **A single-replica operator.** The `-rw` Service selects `cnpg.io/instanceRole=primary`, and only the
   operator moves that label, so while it is down there is no writable endpoint even though a promoted Postgres
   is up. The drain that needs a switchover was also evicting the only thing that can finish one: a 33s gap
   between "new primary accepting connections" and "labels swapped".
3. Nothing else. The remaining ~20s is CNPG's own cadence, roughly 7s to decide, 6s for Postgres to promote and
   replay, 6s to relabel. Not reachable from the Cluster spec.

So ~20s is the practical floor here, not the 2-5s that "negligible downtime" suggests. It is a real
interruption: with no pod labelled primary the `-rw` Service has NO endpoints, so a client retry does not
paper over it, it just retries into a closed door for 20s.

Still one replica, so still able to stall a switchover: the barman-cloud plugin. It holds a lease like the
operator does, but it ships as a vendored upstream manifest with `replicas` hardcoded.

**Do not shorten `03e`'s `GRACEFUL_DRAIN_TIMEOUT` below the ~33s a switchover needs.** Force-deleting the
primary early turns a ~20s switchover into a ~60s failover.

### Force-detaching a machine that is still alive is safe, and here is why

The cable-pull case is the one the six-minute wait exists for: the machine keeps running, Postgres keeps its
volume mounted, and its `longhorn-manager` cannot be told to stand down because it cannot reach the API.
Tainting it force-attaches the same volume on a survivor, so two engines briefly hold a copy each.

Measured: Longhorn stamped `failedAt` on the isolated machine's replica 5 seconds after the taint landed, and
kept serving from the survivor's replica. On rejoin the fenced replica was rebuilt from the authoritative one,
and CNPG discarded the diverged ex-primary entirely, recovering it from a base backup on the old timeline and
then streaming from the new one. A 50-row checksum taken before the pull was byte-identical afterwards.

Two costs to know about, both self-healing. The returning machine's Longhorn DaemonSets were force-deleted by
the taint, so the first pod scheduled back there fails to mount for ~35s with `CSINode <node> does not contain
driver driver.longhorn.io` until the CSI plugin re-registers. And an instance that cannot reschedule under hard
anti-affinity waits out the whole outage Pending, which is correct but looks alarming.

So the 3-copy workloads stay available but lose their spare until the machine is repaired, and a second loss in
that window stops writes. A 4th machine removes this.

## Reconciling a replaced node

Run this AFTER the OS repo's `make recover-node NODE=<host>` reports the node Ready.

```bash
make reconcile-storage NODE=talos-cp3   # idempotent; re-run to get past a step that needed more time
make rebalance-workloads                # in the OS repo, once everything is healthy
```

`reconcile_storage_after_rejoin.sh` checks every volume still has a healthy replica elsewhere, drops the stale
replica records on the returned node, then resets its disk record. What it is fixing:

Longhorn stores the disk's UUID in BOTH the node CR and a `longhorn-disk.cfg` on the disk itself. The reflash
made a fresh filesystem, so the manager wrote a new cfg with a new UUID while the CR still held the old one:

```
Ready=False  DiskFilesystemChanged  record diskUUID doesn't match the one on the disk
```

The node itself reports `Ready`, so this hides unless you look at the disk.

By hand, if the script stops half way. Delete the stale replicas first, having checked each of their volumes
still has a `running` replica on another node:

```bash
kubectl -n longhorn-system get replicas.longhorn.io \
  -o custom-columns=VOL:.spec.volumeName,NODE:.spec.nodeID,STATE:.status.currentState | sort   # one running elsewhere per volume
kubectl -n longhorn-system get replicas.longhorn.io \
  -o jsonpath='{range .items[?(@.spec.nodeID=="talos-cp3")]}{.metadata.name}{"\n"}{end}' \
  | xargs -r kubectl -n longhorn-system delete replicas.longhorn.io
```

Then disable, remove and re-add the disk, with the same spec as a healthy node's:

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

Confirm a NEW diskUUID, `Ready=True` and `Schedulable=True`:

```bash
kubectl -n longhorn-system get nodes.longhorn.io talos-cp3 -o jsonpath=\
'{range .status.diskStatus.*}{.diskUUID}{" "}{range .conditions[*]}{.type}={.status} {end}{" avail="}{.storageAvailable}{"\n"}{end}'
```

Three gotchas that cost time. The validating webhook refuses to remove a disk that is still schedulable, so
`allowScheduling: false` has to land first. A merge patch of `{"disks":{}}` is a NO-OP, because JSON merge
patch deletes keys only when they are set to `null`; use a json patch `remove` op instead. And the re-add is
rejected once with `spec and status of disks on node talos-cp3 are being syncing and please retry later`,
because the manager has not finished reacting to the removal; wait ~10s and repeat it.

Rebuilds do not start the moment the node returns. `replica-replenishment-wait-interval` is 1800, so Longhorn
holds a failed replica for 30 minutes before replacing it, in case the node comes back with its data. Deleting
the stale replicas above is what ends that wait.

Verify everything converged:

```bash
kubectl get pods -A | grep -Ev 'Running|Completed'                   # empty
kubectl get clusters.postgresql.cnpg.io -A                           # "Cluster in healthy state"
kubectl -n rabbitmq get rabbitmqcluster rabbitmq                     # AllReplicasReady True
kubectl -n longhorn-system get volumes.longhorn.io                   # no degraded, no faulted
kubectl -n longhorn-system get nodes.longhorn.io -o wide             # every node AND its disk Ready
kubectl -n argocd get applications                                   # all Synced + Healthy
```

## Per subsystem

### Longhorn

Replicas rebuild from the surviving nodes on their own. The disk RECORD does not: see above, which is
mandatory after a reflash and is the one Longhorn thing that needs hands.

Once the disk is back, watch the replicas and do not touch them:

```bash
kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=\
NAME:.metadata.name,ROBUSTNESS:.status.robustness,STATE:.status.state
```

`degraded` during a rebuild is expected. `faulted` is not, and means every replica is gone: restore from S3
with `make restore-longhorn`, for the one class that has backups.

Do not start work on a second node until robustness is `healthy` everywhere. With 2 replicas on 3 nodes,
a rebuild in flight means some volume is one failure from `faulted`.

Expect the replaced node to stay EMPTY afterwards. `replica-auto-balance` is `disabled`, so Longhorn never
moves a healthy replica, and every volume that was rebuilt during the outage picked the two survivors. That is
not a fault, but it does mean losing either survivor now degrades every volume at once and rebuilds all of
them onto the one empty node. If that concentration bothers you, `replica-auto-balance: best-effort` in
`02_longhorn`'s values spreads them back over time.

### CNPG

Both cases handle themselves, for different reasons.

`highAvailability: true`: the primary dies with the machine, a synchronous standby is promoted, and because the
commit waited for that standby to flush, it cannot be missing a transaction the application was told had
committed. Writes continue on 2 of 3. The third instance stays Pending until the machine returns, because
`podAntiAffinityType: required` will not double up.

`highAvailability: false`: the single instance reschedules onto a survivor and reattaches the same volume.
Postgres replays WAL on startup, exactly as it does after any `kill -9`, and comes up consistent. Nothing to
restore.

```bash
kubectl -n <ns> get cluster <cluster> -w      # back to "Cluster in healthy state"
```

CNPG will not leave a primary on a cordoned node: cordon one to steer a pod somewhere and it switches over
first, so the instance you meant to move may not be the one that moves. Check
`kubectl get pods -l cnpg.io/podRole=instance -A -L cnpg.io/instanceRole` before and after.

The S3 catalog is still there, and still the answer for real data loss: a dropped table, a bad migration, or
losing every replica of a volume at once. `make restore-cnpg`, detail in [10_backups.md](10_backups.md). It is
no longer part of node recovery.

### RabbitMQ

Quorum queues tolerate one broker down out of three, so no messages are at risk. The broker's volume is
Longhorn's, so the replacement pod reattaches the same data and rejoins with its Raft log intact. No
`forget_cluster_node`, no `join_cluster`, nothing to wipe.

The startup probe (`reached-target-cluster-size`) returns 503 while the broker catches up and will restart the
container once. That is normal; one restart is not a failure. Confirm from a HEALTHY peer:

```bash
kubectl -n rabbitmq exec rabbitmq-server-1 -c rabbitmq -- rabbitmqctl cluster_status
```

All three under `Running Nodes` means it is back, even if the pod is not Ready yet.

**Never wipe a broker's PVC as a repair step.** Raft tracks members by name along with what log each one should
have, so a member that returns under its old name with an empty log is a contradiction the survivors refuse
rather than guess about. If you ever do need to replace a broker's storage, the wipe must be preceded by
`stop_app` plus `forget_cluster_node` from a peer and followed by an explicit `join_cluster`, and it is worst for
`rabbitmq-server-0`, which `rabbit_peer_discovery_k8s` auto-clusters onto itself and which therefore comes back
with divergent history rather than an empty log. Keeping the volume is what makes all of that moot.

### Redis

Nothing to do. Both persistence modes sit on Longhorn, so the volume follows the pod to a surviving node.
A brief availability gap while it reschedules, which is the accepted trade-off in [09_redis.md](09_redis.md).

## Retiring a node for good

The etcd and Kubernetes side is the OS repo's. What it costs here, on a 3-node cluster:

- Longhorn goes back to `healthy`: 2 replicas with hard anti-affinity fit exactly on 2 nodes, one each. What
  is gone is the spare. The next node failure leaves volumes `degraded` with nowhere to rebuild onto, which
  is the situation the 2-replica choice exists to avoid ([05_storage.md](05_storage.md)).
- `sample-user-manager-db` and RabbitMQ drop to 2 of 3 permanently, so they have no spare either. Both still
  serve; neither tolerates another loss.

Two nodes is not a supported steady state here. Treat it as a countdown, not a configuration.

## What self-heals, and what does not

Detection is covered: `Node NotReady`, `CNPG instance not ready`, `RabbitMQ node down`, `Container stuck
(crashloop)`, `StatefulSet has no ready replicas` and `Longhorn volume degraded` all fire on this scenario.
See [06_monitoring.md](06_monitoring.md).

| Layer | Self-heals a machine LOSS | Self-heals a machine REPLACEMENT |
|---|---|---|
| Longhorn replicas | yes, the manager rebuilds | yes |
| Longhorn disk record | n/a | no: the CR's diskUUID outlives the filesystem, and Longhorn will not guess which is right |
| CNPG, HA | yes, a synchronous standby is promoted | yes |
| CNPG, single instance | yes, the volume moves with the pod | yes |
| RabbitMQ | yes, on 2 of 3; the broker returns with its data | yes |
| Redis, monitoring stores, ntfy | yes, rides Longhorn | yes |
| Stateless Deployments | yes | yes |

What would improve it further, in order:

1. **A 4th machine.** Every "serves on 2 of 3, no spare" row above becomes a full recovery, because a displaced
   copy would have somewhere to go under hard anti-affinity.
2. **Nothing else.** The one remaining manual record is an artifact of reflashing a machine under the same
   name, it is handled by one idempotent script, and it is not on the availability path.
