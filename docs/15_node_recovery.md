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

Nodes are addressed by IP throughout; `pi-cp3` / `192.168.10.203` below is the example. Do not run
`talosctl bootstrap` at any point: that is for creating a cluster, not joining one.

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
   make talosctl -n 192.168.10.201 etcd members    # expect 3, one unreachable
   kubectl get nodes
   ```

3. Remove the stale etcd member. A reflashed node comes back with a NEW etcd identity, and the old member
   entry at the same peer URL blocks a clean join. Takes the member ID, not the hostname.

   ```bash
   make talosctl -n 192.168.10.201 etcd remove-member f54813b437fd8f2e
   make talosctl -n 192.168.10.201 etcd members    # expect 2
   ```

4. Reflash and boot it. `make flash-talos-nvme`, then power on with no SD card. It comes up in maintenance
   mode, which answers `--insecure` and rejects a secure call with an unknown-CA error:

   ```bash
   make talosctl -n 192.168.10.203 version --insecure
   ```

5. Apply that node's machine config. `03d` re-renders from the durable `secrets/secrets.yaml`, so PKI is
   preserved, but it ends by bootstrapping etcd, which must not run here. Pin it to the one node and cut it
   off before that:

   ```bash
   sed -e '27a HOSTNAMES=(pi-cp3); IPS=(192.168.10.203)' \
       -e '235,$d' \
       lib/shell/03d_talos_cluster_config.sh > lib/shell/zz_rejoin.sh
   grep -c 'talosctl bootstrap' lib/shell/zz_rejoin.sh   # MUST print 0
   bash lib/shell/zz_rejoin.sh && rm lib/shell/zz_rejoin.sh
   ```

   Expect `Applied configuration without a reboot`, then the node ready. It joins etcd by itself; control
   plane nodes auto-join when a cluster already exists.

   ```bash
   make talosctl -n 192.168.10.201 etcd members    # expect 3, new ID for the replaced node
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

8. Reset the Longhorn disk record. Longhorn stores the disk's UUID in BOTH the node CR and a
   `longhorn-disk.cfg` on the disk itself. The reflash made a fresh filesystem, so the manager wrote a new
   cfg with a new UUID while the CR still held the old one, and Longhorn refuses the disk rather than risk
   using the wrong one:

   ```
   Ready=False  DiskFilesystemChanged  record diskUUID doesn't match the one on the disk
   ```

   The node itself reports `Ready`, so this hides unless you look at the disk. Confirm zero replicas on it
   first, then disable, remove and re-add:

   ```bash
   D=$(kubectl -n longhorn-system get nodes.longhorn.io pi-cp3 \
       -o go-template='{{range $k,$v := .spec.disks}}{{$k}}{{end}}')
   kubectl -n longhorn-system get replicas.longhorn.io -o jsonpath='{range .items[?(@.spec.nodeID=="pi-cp3")]}{.metadata.name}{"\n"}{end}'   # must be empty

   kubectl -n longhorn-system patch nodes.longhorn.io pi-cp3 --type merge \
     -p "{\"spec\":{\"disks\":{\"$D\":{\"allowScheduling\":false}}}}"
   kubectl -n longhorn-system patch nodes.longhorn.io pi-cp3 --type json \
     -p "[{\"op\":\"remove\",\"path\":\"/spec/disks/$D\"}]"
   ```

   Then re-add it with the same spec as a healthy node's (`kubectl -n longhorn-system get nodes.longhorn.io
   pi-cp1 -o jsonpath='{.spec.disks}'`), and confirm:

   ```bash
   kubectl -n longhorn-system get nodes.longhorn.io pi-cp3 \
     -o jsonpath='{range .status.diskStatus.*}{.diskUUID}{" avail="}{.storageAvailable}{"\n"}{end}'
   ```

   Two gotchas that cost time. The validating webhook refuses to remove a disk that is still schedulable, so
   `allowScheduling: false` has to land first. And a merge patch of `{"disks":{}}` is a NO-OP, because JSON
   merge patch deletes keys only when they are set to `null`; use a json patch `remove` op instead.

9. Verify everything converged.

   ```bash
   kubectl get nodes                                                    # 3 Ready
   make talosctl -n 192.168.10.201 etcd members                         # 3 members
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

### CNPG, single instance (`highAvailability: false`)

No peer, so the data is gone with the node. This is the only case that needs the S3 catalog.

CNPG reads `spec.bootstrap` once, at create time, so an in-place restore only works on a Cluster that does
not exist yet. With `selfHeal` on, the order matters: enable the restore in git FIRST, then delete the
Cluster, so Argo recreates it already carrying the recovery bootstrap.

1. Set `deletionProtection: false` on that instance in its workload `values.yaml`, commit, push, wait for the
   sync.
2. Set `restore.enabled: true` on the same instance, commit, push, wait for the sync.
3. Delete the Cluster. Argo recreates it with `bootstrap.recovery` and CNPG runs a `-full-recovery` job that
   pulls the newest base backup and replays the WAL catalog.
4. Verify the data, then revert both flags in one commit.
5. Roll anything that mounts the `<cluster>-app` Secret. Deleting the Cluster regenerated it, so consumers
   are holding a stale password.

`make restore-cnpg` drives steps 1, 2, 4 and 5 and is the supported path; it refuses while the Cluster is
still live, which is what step 3 is for. Full detail in [13_backups.md](13_backups.md).

The real fix is not to be in this situation: see below.

### RabbitMQ

Quorum queues tolerate one broker down out of three. Delete the PVC and pod; the replacement starts empty and
replays the Ra logs from the two healthy peers.

```bash
kubectl -n rabbitmq delete pvc persistence-rabbitmq-server-<n>
kubectl -n rabbitmq delete pod rabbitmq-server-<n>
```

It rejoins the cluster and takes leadership of queues within a minute or two, but the startup probe
(`reached-target-cluster-size`) returns 503 while it catches up and will restart the container once. That is
normal; one restart is not a failure. Confirm with:

```bash
kubectl -n rabbitmq exec rabbitmq-server-1 -c rabbitmq -- rabbitmqctl cluster_status
```

All three under `Running Nodes` means it is back, even if the pod is not Ready yet.

### Redis

Nothing to do. Both persistence modes sit on Longhorn, so the volume follows the pod to a surviving node.
A brief availability gap while it reschedules, which is the accepted trade-off in [12_redis.md](12_redis.md).

## Retiring a node for good

When it is not coming back, tell all three layers, in this order:

```bash
make talosctl -n 192.168.10.201 etcd members                       # find the ID
make talosctl -n 192.168.10.201 etcd remove-member <id>            # etcd
kubectl delete node pi-cp3                                         # kubernetes
```

Then remove it from `CLUSTER_NODES` in `.env`, so `03c` to `03f` stop targeting it.

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
| RabbitMQ broker | no, then yes | same |
| Single-instance CNPG | no | no peer, needs the S3 catalog |

Three changes would remove most of the manual work, in descending order of value:

1. **Make every CNPG cluster HA.** `highAvailability: true` turns the one case that needs an S3 restore into
   the case that needs a PVC deleted. `sample-user-manager-analytics` is the current exception, and it costs
   one line in its `values.yaml` plus a second instance's worth of memory. Nothing else on this cluster gives
   a comparable reduction in recovery work.
2. **Write `make recover-node NODE=pi-cp3`.** Steps 3 and 5 to 7 above are entirely mechanical: read the
   member ID, remove it, apply the pinned config, uncordon, find and delete the node's local-path PVCs, wait
   for convergence. It is the same shape as the existing `03f`, including its replication-health gate, and it
   would turn an hour of careful work into one command. Everything it needs to know is already derivable.
3. **Do not automate the PVC deletion beyond that script.** A controller that deletes PVCs whose backing
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
