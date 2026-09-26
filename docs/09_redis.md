# Redis, per-workload caches via the OpsTree operator

Redis has the same shape as [Postgres](05_storage.md#cloudnativepg). The platform installs the operator once, and
each workload creates its own private instances through a shared chart. There is no shared Redis. To check, restore,
resize or delete an instance, see [runbooks/09_redis.md](runbooks/09_redis.md).

| Piece | Where | What |
|---|---|---|
| Operator | `argo_apps/platform/{apps,charts}/03_redis_operator`, wave 3 | The OpsTree controller and its CRDs |
| Instance chart | `lib/helm/redis-instance` | One standalone `Redis`, its `ServiceMonitor` and a default-deny `CiliumNetworkPolicy`. One alias per instance |
| Backup | `argo_apps/platform/{apps,charts}/07_redis_backup`, wave 7 | One CronJob that dumps every durable instance to S3 |

The sample workload runs two instances, one per persistence mode. See [07_sample_workload.md](07_sample_workload.md).

## Decisions

### OpsTree operator

- It is mature and close to the CNCF, with a plain CRD.
- Its operator and Redis images are multi-arch, which the Pi 5 needs.

### Standalone instances, no HA

Each instance is one pod with one PVC. There is no replication, sentinel or cluster. On a node loss the pod
reschedules and Longhorn reattaches the volume, so the instance is down for a short time. A workload that needs
more would use a `RedisReplication` or `RedisSentinel`. Neither exists here.

### `persistence` picks durability, not a storage class

| `persistence` | AOF | S3 backup | For |
|---|---|---|---|
| `true` | `everysec`, so a crash loses at most about 1s of writes | daily RDB dump | durable data |
| `false` | not added by the chart | none | caches the app can rebuild |

Every instance uses `longhorn-r2-ephemeral`, with 2 replicas and reclaim `Delete`. A cache also survives a node loss.

`deletionProtection` guards the data, not the reclaim policy. It is a required bool, and it stops Argo CD from
pruning or deleting the instance. Removing an instance from git leaves it running, and restoring the files adopts it
again. A deliberate delete falls back to the S3 dump. A Retain class would add no safety, and would leave a
`Released` PV after every deliberate delete.

### Writes fail at the memory cap

`maxmemory` is 80% of the container memory limit. The rest covers the fork during a save and client buffers, so the
kernel does not OOM-kill the pod. Eviction stays at `noeviction`, so at the cap writes fail instead of Redis dropping
data silently.

### No password, the network policy is the gate

Only the owning workload's pods, the operator and vmagent may open `:6379`. Instances are ClusterIP only.

A password would have to come from somewhere, and each source fails a rule of this repo:

- The OpsTree operator does not generate one, as CNPG and RabbitMQ do.
- A random password from Helm changes on every sync, because Argo CD renders with `helm template` and `lookup`
  returns nothing.
- A sealed secret is for credentials a human supplies from outside. See [03_secrets.md](03_secrets.md).

So the network policy is the access control, and nothing is committed or generated. To add a password later, point
the `Redis` CR at a SealedSecret in `templates/redis.yaml`.

### One central backup job

`07_redis_backup` backs up the whole cluster. It finds durable instances by a label that the instance chart sets,
and runs `redis-cli --rdb` against each one.

- Benefit: one sealed secret in one namespace, and no list of instances to maintain.
- Cost: one schedule for all instances, and job-level alerts.

`redis-no-recoverable-backup` is the only alert that sees one instance stop being backed up. The bucket and IAM
writer are shared with CNPG. See [10_backups.md](10_backups.md).

### Restore through replication

`make restore-redis` makes the instance a `REPLICAOF` of a temporary pod that holds the dump. A full resync carries
every type, TTL and score exactly. A PVC swap would fight the operator and the AOF. `redis-rdb-tools` is unmaintained
and breaks on new RDB versions.
