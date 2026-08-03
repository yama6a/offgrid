# 15: Losing and replacing a node

What breaks when one of the three Pis goes away, what comes back on its own, and what needs hands.

## The thing that catches you out

A node REPLACED under the same name is harder to recover than a node destroyed outright.

Reflashing the NVMe wipes the `/var/mnt/localpath` slice, but the PVC and PV objects for it live in the API
server, not on the disk. They survive, still `Bound`, still node-affine to that node, now pointing at a
directory with nothing in it. Every operator therefore sees "the volume is here and its contents are wrong",
not "the volume is gone", and none of them will destroy a PVC that might hold the last copy of something. So
they sit in CrashLoopBackOff until a human deletes it:

- CNPG: `pg_controldata: exit status 1`
- RabbitMQ: `Ra could not create its data directory`

That is the whole trick. **After replacing a node, delete every local-path PVC that was bound to it.** The
operators rebuild from their surviving peers the moment the PVC comes back empty and fresh.

Longhorn is unaffected: its replicas live on the other nodes, so it just rebuilds.

## What survives

| Storage | Used by | On node replacement |
|---|---|---|
| `longhorn-r2-ephemeral` | Redis, general workload volumes | data survives, replicas rebuild themselves. The node's disk RECORD does not: it needs resetting, step 8 |
| `local-path` | CNPG Postgres | PVC survives EMPTY. Delete it; CNPG re-clones from the primary |
| `local-path-ephemeral` | RabbitMQ quorum logs | PVC survives EMPTY. Delete it; the broker re-syncs from the quorum |
| none | stateless Deployments | reschedule on their own |

The one case with no peer to rebuild from is a **single-instance CNPG cluster**
(`highAvailability: false`). Its only copy was on that node. That needs an S3 restore, see
[13_backups.md](13_backups.md).

## Replace a node

```bash
make flash-talos-nvme                # only if the NVMe itself is being replaced; power on with no SD card
make recover-node NODE=pi-cp3        # steps 3 and 5 to 8 below, in order, idempotent
make restore-cnpg                    # only if a single-instance DB lived there; recover-node names it
make rebalance-workloads             # once everything is healthy
```

`recover_node.sh` does the mechanical part: drops the stale etcd member, applies that node's machine config,
waits for the kubelet, deletes the local-path PVCs bound to it (forgetting a RabbitMQ broker first), drops the
stale Longhorn replicas and resets the disk record. It re-checks before every action, so re-running it is how
you get past a step that needed more time.

The rest of this section is what it does and why, which is what you need when it stops half way. Nodes are
addressed by IP throughout; `pi-cp3` / `192.168.10.203` is the example. Do not run `talosctl bootstrap` at any
point: that is for creating a cluster, not joining one.

1. Confirm the node is really gone, not just slow to boot.

   ```bash
   arp -n 192.168.10.203          # "(incomplete)" = no layer-2 presence at all
   nc -vz 192.168.10.203 50000    # Talos API
   ```

   An incomplete ARP entry means it is not on the network: either it did not boot, or its NIC did not come
   up. Attach HDMI or a USB-UART (115200, `ttyAMA10`) to tell those apart.

2. Check the survivors can afford it. Two of three nodes hold etcd quorum, so you have no spare failure
   until the third is back.

   ```bash
   make talosctl -- -n 192.168.10.201 etcd members    # expect 3, one unreachable
   kubectl get nodes
   ```

3. Remove the stale etcd member. A reflashed node comes back with a NEW etcd identity, and the old member
   entry at the same peer URL blocks a clean join. Takes the member ID, not the hostname.

   ```bash
   make talosctl -- -n 192.168.10.201 etcd remove-member f54813b437fd8f2e
   make talosctl -- -n 192.168.10.201 etcd members    # expect 2
   ```

4. Reflash and boot it. `make flash-talos-nvme`, then power on with no SD card. It comes up in maintenance
   mode, which answers `--insecure` and rejects a secure call with an unknown-CA error:

   ```bash
   make talosctl -- -n 192.168.10.203 version --insecure
   ```

5. Apply that node's machine config. `03c` re-renders from the durable `secrets/secrets.yaml`, so PKI is
   preserved. Give it a hostname and it applies to that node alone and skips the etcd bootstrap:

   ```bash
   bash lib/shell/03c_talos_cluster_config.sh pi-cp3
   ```

   Only the apply and its two waits narrow to the one node. certSANs and the `secrets/talosconfig` endpoints
   still come from the whole `CLUSTER_NODES` list, or the rejoined node would trust an apiserver cert naming
   just itself and `talosctl` would forget the other two.

   Expect `Applied configuration without a reboot`, then the node ready. It joins etcd by itself; control
   plane nodes auto-join when a cluster already exists.

   ```bash
   make talosctl -- -n 192.168.10.201 etcd members    # expect 3, new ID for the replaced node
   ```

6. Uncordon, once the kubelet reports Ready.

   ```bash
   kubectl uncordon pi-cp3
   ```

   If the node object is stuck on a stale identity, `kubectl delete node pi-cp3` and let the kubelet
   re-register.

7. Delete every local-path PVC that was bound to it. This is the step nothing does for you.

   ```bash
   # list them: local-path PVCs whose PV is node-affine to the replaced node
   for pvc in $(kubectl get pvc -A -o jsonpath='{range .items[?(@.spec.storageClassName)]}{.metadata.namespace}/{.metadata.name}/{.spec.volumeName}/{.spec.storageClassName}{"\n"}{end}' | grep local-path); do
     IFS=/ read -r ns name pv sc <<< "$pvc"
     node=$(kubectl get pv "$pv" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}' 2>/dev/null)
     [ "$node" = "pi-cp3" ] && echo "$ns $name $sc"
   done
   ```

   Then, per hit, PVC first and pod second. The PVC sits in `Terminating` until the pod releases it, then
   the operator recreates both:

   ```bash
   kubectl -n <ns> delete pvc <name>
   kubectl -n <ns> delete pod <pod>
   ```

   Two exceptions, both covered below. A **RabbitMQ** broker must be forgotten by a peer BEFORE its PVC goes,
   or it cannot rejoin. A **single-instance CNPG** PVC should be left alone: its only copy died with the node,
   so an empty PVC is not what is wrong and the S3 restore takes the PVC with the Cluster anyway.

8. Reset the Longhorn disk record. Longhorn stores the disk's UUID in BOTH the node CR and a
   `longhorn-disk.cfg` on the disk itself. The reflash made a fresh filesystem, so the manager wrote a new
   cfg with a new UUID while the CR still held the old one, and Longhorn refuses the disk rather than risk
   using the wrong one:

   ```
   Ready=False  DiskFilesystemChanged  record diskUUID doesn't match the one on the disk
   ```

   The node itself reports `Ready`, so this hides unless you look at the disk.

   The node comes back still listing its old replicas, now `stopped` with `failedAt` set: they describe data
   on a filesystem that no longer exists. Delete them, having checked each of their volumes still has a
   `running` replica on another node, and only then touch the disk:

   ```bash
   kubectl -n longhorn-system get replicas.longhorn.io \
     -o custom-columns=VOL:.spec.volumeName,NODE:.spec.nodeID,STATE:.status.currentState | sort   # one running elsewhere per volume
   kubectl -n longhorn-system get replicas.longhorn.io \
     -o jsonpath='{range .items[?(@.spec.nodeID=="pi-cp3")]}{.metadata.name}{"\n"}{end}' \
     | xargs -r kubectl -n longhorn-system delete replicas.longhorn.io
   ```

   Then disable, remove and re-add the disk, with the same spec as a healthy node's:

   ```bash
   D=$(kubectl -n longhorn-system get nodes.longhorn.io pi-cp3 \
       -o go-template='{{range $k,$v := .spec.disks}}{{$k}}{{end}}')
   SPEC=$(kubectl -n longhorn-system get nodes.longhorn.io pi-cp1 -o jsonpath='{.spec.disks}')

   kubectl -n longhorn-system patch nodes.longhorn.io pi-cp3 --type merge \
     -p "{\"spec\":{\"disks\":{\"$D\":{\"allowScheduling\":false}}}}"
   kubectl -n longhorn-system patch nodes.longhorn.io pi-cp3 --type json \
     -p "[{\"op\":\"remove\",\"path\":\"/spec/disks/$D\"}]"
   kubectl -n longhorn-system patch nodes.longhorn.io pi-cp3 --type merge \
     -p "{\"spec\":{\"disks\":$SPEC}}"        # retry this one, see below
   ```

   Confirm a NEW diskUUID, `Ready=True` and `Schedulable=True`:

   ```bash
   kubectl -n longhorn-system get nodes.longhorn.io pi-cp3 -o jsonpath=\
'{range .status.diskStatus.*}{.diskUUID}{" "}{range .conditions[*]}{.type}={.status} {end}{" avail="}{.storageAvailable}{"\n"}{end}'
   ```

   Three gotchas that cost time. The validating webhook refuses to remove a disk that is still schedulable,
   so `allowScheduling: false` has to land first. A merge patch of `{"disks":{}}` is a NO-OP, because JSON
   merge patch deletes keys only when they are set to `null`; use a json patch `remove` op instead. And the
   re-add is rejected once with `spec and status of disks on node pi-cp3 are being syncing and please retry
   later`, because the manager has not finished reacting to the removal; wait ~10s and repeat it.

   Rebuilds do not start the moment the node returns. `replica-replenishment-wait-interval` is 1800, so
   Longhorn holds a failed replica for 30 minutes before replacing it, in case the node comes back with its
   data. Deleting the stale replicas above is what ends that wait.

9. Verify everything converged.

   ```bash
   kubectl get nodes                                                    # 3 Ready
   make talosctl -- -n 192.168.10.201 etcd members                      # 3 members
   kubectl get pods -A | grep -Ev 'Running|Completed'                   # empty
   kubectl get clusters.postgresql.cnpg.io -A                           # "Cluster in healthy state"
   kubectl -n rabbitmq get rabbitmqcluster rabbitmq                     # AllReplicasReady True
   kubectl -n longhorn-system get volumes.longhorn.io                   # no degraded, no faulted
   kubectl -n longhorn-system get nodes.longhorn.io -o wide             # every node AND its disk Ready
   kubectl -n argocd get applications                                   # all Synced + Healthy
   ```

## Per subsystem

### Longhorn

Replicas rebuild from the surviving nodes on their own. The disk RECORD does not: see step 8 above, which
is mandatory after a reflash and is the one Longhorn thing that needs hands.

Once the disk is back, watch the replicas and do not touch them:

```bash
kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=\
NAME:.metadata.name,ROBUSTNESS:.status.robustness,STATE:.status.state
```

`degraded` during a rebuild is expected. `faulted` is not, and means every replica is gone: restore from S3
with `make restore-longhorn`.

Do not start work on a second node until robustness is `healthy` everywhere. With 2 replicas on 3 nodes,
a rebuild in flight means some volume is one failure from `faulted`.

Expect the replaced node to stay EMPTY afterwards. `replica-auto-balance` is `disabled`, so Longhorn never
moves a healthy replica, and every volume that was rebuilt during the outage picked the two survivors. That is
not a fault, but it does mean losing either survivor now degrades every volume at once and rebuilds all of
them onto the one empty node. If that concentration bothers you, `replica-auto-balance: best-effort` in
`02_longhorn`'s values spreads them back over time.

### CNPG, HA cluster (`highAvailability: true`)

The primary survives on another node. Delete the replica's PVC and pod; CNPG runs a `-join` job that clones
from the primary. No data loss, nothing to restore.

```bash
kubectl -n <ns> delete pvc <cluster>-<n>
kubectl -n <ns> delete pod <cluster>-<n>
kubectl -n <ns> get cluster <cluster> -w      # back to "Cluster in healthy state"
```

Recovery is a full base clone over the network, so give it minutes, not seconds.

CNPG will not leave a primary on a cordoned node: cordon one to steer a pod somewhere and it switches over
first, so the instance you meant to move may not be the one that moves. Check
`kubectl get pods -l cnpg.io/podRole=instance -A -L cnpg.io/instanceRole` before and after.

### CNPG, single instance (`highAvailability: false`)

No peer, so the data is gone with the node. This is the only case that needs the S3 catalog.

CNPG reads `spec.bootstrap` once, at create time, so an in-place restore only works on a Cluster that does
not exist yet. With `selfHeal` on, the order matters: enable the restore in git FIRST, then delete the
Cluster, so Argo recreates it already carrying the recovery bootstrap. Deleting it while the restore is
still off just gets you a fresh empty database from `initdb`.

`make restore-cnpg` drives the whole thing across two runs. Answer `in-place`, the namespace and the DB name:

```bash
make restore-cnpg   # run 1: sets deletionProtection false + restore.enabled true, prints the commit
git add argo_apps/workloads/charts/<app>/values.yaml && git commit -m "restore <db> from S3" && git push
make restore-cnpg   # run 2: deletes the Cluster, watches the rebuild, verifies, reverts both flags
git add argo_apps/workloads/charts/<app>/values.yaml && git commit -m "<db>: restore done, re-protect" && git push
```

What run 2 does, in order: refuses until the live Cluster carries `cnpg.io/skipEmptyWalArchiveCheck`, which
is the proof Argo has synced the restore render; deletes the Cluster; watches Argo recreate it and CNPG run a
`-full-recovery` job that pulls the newest base backup and replays the WAL catalog; prints every restored
table with its row count and the new timeline; rolls anything mounting the regenerated `<cluster>-app`
Secret, whose password changed when the old Cluster was deleted; and turns `restore` back off and
`deletionProtection` back on.

It refuses to touch a HEALTHY live database without an explicit confirmation, because continuing rewinds it
to the catalog. To read old rows from a DB that is fine, use `--mode side` instead.

Full detail in [13_backups.md](13_backups.md). The real fix is not to be in this situation: see below.

### RabbitMQ

Quorum queues tolerate one broker down out of three, so no messages are at risk. Getting the broker back is
the part with a trap in it.

**Forget it from a peer BEFORE you delete its PVC.** Quorum keeps the cluster available while a known member
is away; it says nothing about re-admitting one. Re-admission is a Raft membership change, and Raft tracks
members by name along with what log each one should have. A member that returns under its old name with an
empty log is a contradiction: the survivors believe it holds state it demonstrably does not. Raft cannot tell
"blank because someone wiped the disk" from "blank because I cannot read my disk yet", so it refuses rather
than guess. Same shape as the local-path PVC problem at the top of this doc.

```bash
N=rabbit@rabbitmq-server-0.rabbitmq-nodes.rabbitmq       # <pod>.<RabbitmqCluster>-nodes.<namespace>
kubectl -n rabbitmq exec rabbitmq-server-0 -c rabbitmq -- rabbitmqctl stop_app   # skip if the pod is gone
kubectl -n rabbitmq exec rabbitmq-server-1 -c rabbitmq -- rabbitmqctl forget_cluster_node "$N"
kubectl -n rabbitmq delete pvc persistence-rabbitmq-server-0
kubectl -n rabbitmq delete pod rabbitmq-server-0
```

`forget_cluster_node` needs the target stopped, which is what `stop_app` is for. Check it actually took, because
a peer that still thinks the broker is running refuses and says nothing useful:

```bash
kubectl -n rabbitmq exec rabbitmq-server-1 -c rabbitmq -- rabbitmqctl eval 'ra:members({rabbitmq_metadata, node()}).'
```

If the broker is still listed, do NOT wipe it. Wiping a member the survivors still hold is the whole problem.

Once it is out and the PVC is gone, the replacement comes up blank and, for `rabbitmq-server-0`, sits in a
cluster of its own: peer discovery auto-clusters onto the lowest-ordered broker, which for that one is itself.
Join it by hand rather than hoping. This is safe and a no-op if it already joined:

```bash
kubectl -n rabbitmq exec rabbitmq-server-0 -c rabbitmq -- \
  rabbitmqctl join_cluster rabbit@rabbitmq-server-1.rabbitmq-nodes.rabbitmq
```

Ready in about 90s after that, and the quorum queues take the member back on their own via periodic membership
reconciliation, so there is no `grow` to run.

Skipping the forget sometimes works anyway: an empty log is something the leader can repair by shipping a
snapshot. Do not rely on it. It fails outright for the lowest-ordered broker, below.

The startup probe (`reached-target-cluster-size`) returns 503 while the broker catches up and will restart the
container once. That is normal; one restart is not a failure. Confirm from a HEALTHY peer:

```bash
kubectl -n rabbitmq exec rabbitmq-server-1 -c rabbitmq -- rabbitmqctl cluster_status
```

All three under `Running Nodes` means it is back, even if the pod is not Ready yet.

#### If you wiped without forgetting, and it never goes Ready

A peer's view is not enough to diagnose this: ask the RETURNING node what IT can see.

```bash
kubectl -n rabbitmq exec rabbitmq-server-0 -c rabbitmq -- rabbitmqctl eval 'rabbit_nodes:list_running().'
```

If the peers list all three but the returning node lists only itself, it did not join, it FORMED a second
cluster. Its container then restarts every ~5 minutes forever, because `reached-target-cluster-size` counts
1 of 3, and the log loops `RabbitMQ metadata store: term mismatch ... Asking leader to resend from N` every
30s. Ra is stuck in `await_condition` and waiting does not fix it.

Worst for `rabbitmq-server-0`. `rabbit_peer_discovery_k8s` auto-clusters onto the lowest-ordered broker, and
for server-0 that is itself, so it logs `DB: virgin node -> run peer discovery` then `node
'rabbit@rabbitmq-server-0...' selected for auto-clustering` and seeds its own store. It then arrives with
divergent history of its own rather than an empty log, which is the case no snapshot can repair. server-1 and
server-2 auto-cluster ONTO server-0, so they only ever arrive empty, which is the recoverable case.

The fix is the same forget, just after the fact: `stop_app`, `forget_cluster_node` from a peer, then delete the
PVC and pod AGAIN, then `join_cluster`.

The other end of the same problem looks almost identical: the broker is out of the membership and standalone,
because it WAS forgotten and then never rejoined. Same symptom from the returning node (`list_running` shows
only itself), but the peer's `ra:members` does NOT list it. That one needs no wipe at all, only the
`join_cluster` above.

Either way, confirm the member came back:

```bash
kubectl -n rabbitmq exec rabbitmq-server-1 -c rabbitmq -- rabbitmq-queues quorum_status --vhost apps <queue>
```

### Redis

Nothing to do. Both persistence modes sit on Longhorn, so the volume follows the pod to a surviving node.
A brief availability gap while it reschedules, which is the accepted trade-off in [12_redis.md](12_redis.md).

## Retiring a node for good

When it is not coming back, tell all three layers, in this order:

```bash
make talosctl -- -n 192.168.10.201 etcd members             # find the ID
make talosctl -- -n 192.168.10.201 etcd remove-member <id>  # etcd
kubectl delete node pi-cp3                                 # kubernetes
```

Then remove it from `CLUSTER_NODES` in `.env`, so `03b` to `03e` stop targeting it.

What this costs, on a 3-node cluster:

- etcd drops to 2 members, which still needs 2 for quorum. No fault tolerance at all until you add a node.
- Longhorn goes back to `healthy`: 2 replicas with hard anti-affinity fit exactly on 2 nodes, one each. What
  is gone is the spare. The next node failure leaves volumes `degraded` with nowhere to rebuild onto, which
  is the situation the 2-replica choice exists to avoid ([08_storage.md](08_storage.md)).
- Any single-instance CNPG that lived there is gone, restore from S3.
- The control-plane VIP fails over on its own, no action.

Two nodes is not a supported steady state here. Treat it as a countdown, not a configuration.

## What self-heals today, and what should

Detection is already covered: `Node NotReady`, `CNPG instance not ready`, `RabbitMQ node down`,
`Container stuck (crashloop)`, `StatefulSet has no ready replicas` and `Longhorn volume degraded` all fire on
this scenario. See [09_monitoring.md](09_monitoring.md). The gap is remediation, not visibility.

| Layer | Self-heals | Why not |
|---|---|---|
| Longhorn replicas | yes | network-replicated, the manager rebuilds |
| Longhorn disk record | no | the CR's diskUUID outlives the filesystem, and Longhorn will not guess which is right |
| Redis | yes | rides Longhorn |
| Stateless Deployments | yes | the scheduler reschedules them |
| Control-plane VIP | yes | Talos fails it over |
| etcd membership | no | nothing prunes a member whose node was replaced |
| local-path PVCs | no | an empty PVC is indistinguishable from a corrupt one, so no operator will delete it |
| CNPG replica | no, then yes | needs the PVC gone; after that CNPG clones by itself |
| RabbitMQ broker | no, then yes | needs forgetting AND the PVC gone; Raft will not re-admit a member that returns blank under its old name |
| Single-instance CNPG | no | no peer, needs the S3 catalog |

`make recover-node NODE=<host>` now drives every "no, then yes" row above. What is left:

1. **Make every CNPG cluster HA.** `highAvailability: true` turns the one case that needs an S3 restore into
   the case `recover-node` already handles. `sample-user-manager-analytics` is the current exception, and it
   costs one line in its `values.yaml` plus a second instance's worth of memory. Nothing else on this cluster
   gives a comparable reduction in recovery work.
2. **Do not automate the PVC deletion beyond that script.** A controller that deletes PVCs whose backing
   directory looks empty is a controller that eventually deletes a good one. Keeping it in a script a human
   runs, against a node they know they just replaced, is the right amount of automation.

Not worth doing: moving CNPG or RabbitMQ onto Longhorn to dodge this. Now measured rather than asserted
(see [16_storage_bench.md](16_storage_bench.md)). Longhorn r2 roughly doubles a Postgres WAL fsync on
this hardware, 1.28 ms to 2.39 ms by Postgres' own `pg_stat_io` counter, landing as 1.5x commit p99 and
about a 20% throughput loss.

The part that settles it: `dataLocality: best-effort` recovers only 4% of that, because a durable write
must reach both replicas before it is acknowledged, so one is always a network hop away wherever the pod
sits. There is no configuration that buys automatic recovery without the write tax. For two systems that
already replicate at the application layer, a permanent latency cost to remove a rare manual step is the
wrong trade.

RabbitMQ specifically is unresolved: too few clean repeats to call, and what data exists looks worse than
Postgres, not better.
