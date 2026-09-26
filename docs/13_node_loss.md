# Losing a node

The tooling that built your cluster owns the machine side of a node loss: etcd membership, machine config and
the kubelet. This doc covers the workload side. Procedures are in
[runbooks/13_node_loss.md](runbooks/13_node_loss.md).

## A lost machine is a scheduling problem

Every volume belongs to Longhorn, not to one machine ([05_storage.md](05_storage.md)). So a pod on a dead machine
reattaches its volume on a surviving node and starts. There is nothing to delete and nothing to restore.

A replaced machine needs one step. A reflashed machine comes back under the same name with a new disk UUID.
Longhorn refuses the disk rather than guess, so `make reconcile-storage NODE=<host>` resets the disk record.

## The dead-node watcher

Kubernetes waits about six minutes before it gives a machine's volumes to another node. The wait covers a node
that is alive and still writes. That default is wrong here: the machines sit in one room, and a machine that
stops answering is dead.

The taint `node.kubernetes.io/out-of-service:NoExecute` skips the wait. Kubernetes never sets it, because only
an operator can declare a machine gone. `dead-node-watcher` makes that call after 60s NotReady. It lives in
`argo_apps/platform/charts/02_dead_node_watcher`, wave 2. A displaced pod then runs elsewhere after about 2
minutes, against 6 or more without the watcher.

- **It never touches a Ready node,** so an ordinary drain is never affected.
- **It does nothing when more than one node is NotReady.** That is a cluster event for a person, not a machine
  failure.
- **It does not skip cordoned nodes.** A node being wiped is cordoned and never returns. Skipping it added 144s
  to 211s of write outage in the test below.
- **Reboots never reach it.** A reboot takes about 90s, shorter than NotReady plus the grace period.

A rolling upgrade therefore taints each cordoned machine during its reboot. That force-deletes the Longhorn
DaemonSet pods there, which come back with the machine. This is safe, because Longhorn refuses to attach one
volume in two places.

Measured write outage. Each test killed the machine that held both the HA primary and the single instance:

| Failure | HA writes | Single instance | Watcher |
|---|---|---|---|
| ethernet unplugged | 184s | 191s | fired at t+116s |
| `talosctl reset`, watcher skipping cordoned nodes | 328s | 402s | skipped |
| `talosctl reboot --mode force`, back in about 90s | 97s | 244s | correctly never fired |

Both outages last minutes, not seconds. Synchronous replication means no lost transactions, not a fast
failover. A tighter target needs a client that retries. A storage change will not help.

### Force-detaching a live machine is safe

An unplugged cable is the case the six-minute wait exists for. The machine keeps running and Postgres keeps its
volume mounted. The test showed no damage:

- Longhorn fenced the isolated replica 5 seconds after the taint and served from the surviving one.
- On rejoin, Longhorn rebuilt the fenced replica, and CNPG rebuilt the diverged former primary.
- A 50-row checksum taken before the pull was byte-identical afterwards.

Two costs, both self-healing:

- The first pod scheduled back on the returned machine fails to mount for about 35s, until the Longhorn CSI
  plugin registers again.
- An instance that hard anti-affinity cannot place stays Pending for the whole outage.

## A planned drain: about 20s of write outage

CNPG switches the primary away before a drain evicts it. Two settings bring the outage down:

| Settings | Write outage |
|---|---|
| CNPG defaults, 1 operator replica | 64s |
| `smartShutdownTimeout: 15` | 41s |
| `smartShutdownTimeout: 15`, 2 operator replicas | 19.6s |

The reasons sit next to each setting, in `lib/helm/pg-cluster/templates/cluster.yaml` and
`argo_apps/platform/charts/02_cnpg_operator/values.yaml`.

- **About 20s is the floor.** It is CNPG's own cadence to decide, promote and relabel, and the Cluster spec
  cannot change it. While no pod carries the primary label, the `-rw` Service has no endpoints. A client retry
  does not hide it.
- **Your drain's graceful timeout must be at least 33s.** A primary force-deleted earlier turns a 20s
  switchover into a 60s failover.
- **The barman-cloud plugin still runs one replica,** so it can still stall a switchover. The vendored manifest
  hardcodes `replicas`.

## RWX volumes

An RWX volume's consumers mount NFS from a share-manager pod. If its node dies, every consumer breaks until
Longhorn moves the share-manager. `rwxVolumeFastFailover` makes that seconds, not a pod eviction timeout. This
path is not measured yet, because no RWX volume has a consumer.

## What self-heals

| Layer | Machine loss | Machine replacement |
|---|---|---|
| Longhorn replicas | yes, the manager rebuilds | yes |
| Longhorn disk record | n/a | no, run `make reconcile-storage` |
| CNPG, `highAvailability: true` | yes, a synchronous standby is promoted, then serves on 2 of 3 | yes |
| CNPG, single instance | yes, the volume moves and Postgres replays WAL | yes |
| RabbitMQ | yes, serves on 2 of 3 with no messages lost | yes, the broker returns with its data |
| Redis, monitoring stores, ntfy | yes, through Longhorn | yes |
| Stateless Deployments | yes | yes |

- **Workloads with 3 copies lose their spare** until the machine is back. Hard anti-affinity allows one copy per
  machine, so a second loss in that window stops writes. A 4th machine removes this risk.
- **Two nodes is not a supported steady state.** 2 Longhorn replicas fit exactly, with no node to rebuild onto.
  Treat a retired node as a countdown, not a configuration.
- **Real data loss is not a node problem.** A dropped table or a lost volume needs S3, see
  [10_backups.md](10_backups.md).
