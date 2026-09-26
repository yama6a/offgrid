# Storage benchmark

The storage benchmark measures what Longhorn r2 and synchronous replication cost CNPG and RabbitMQ in write
latency. It backs two decisions in [05_storage.md](05_storage.md):

- Everything runs on Longhorn.
- RabbitMQ gets a local replica, and Postgres does not.

Verdict: Longhorn adds real but small latency. Self-healing on a machine loss is worth that cost. Both databases
stay inside what the managed services deliver.

The benchmark runs on demand. It is not a bring-up step. The method lives in `lib/shell/storage_bench.sh` and
`lib/bench/`. To run it, see [runbooks/12_storage_bench.md](runbooks/12_storage_bench.md).

## Postgres, against managed Postgres

The decision metric is pgbench latency at one client. The WAL fsync dominates it, and it is what a user of an
app feels. The `local-path` rows are a baseline from runs before that class left the cluster.

| Setup | Node loss costs | avg ms | tps at 8 clients |
|---|---|---|---|
| local-path, 1 instance | an S3 restore | 6.02 | 731 |
| local-path, 3 instances, sync `any 1` | a PVC delete | 8.19 | 555 |
| Longhorn r2, 1 instance, `highAvailability: false` | nothing | 7.50 | 552 |
| Longhorn r2, 3 instances, sync `any 1`, `highAvailability: true` | nothing | 10.52 | 374 |
| RDS Multi-AZ, synchronous | | about 4.4 to 7.4 | |
| RDS single-AZ, `db.t4g.medium` | | 2.41 | 1080 at 4 clients |

- **The shipped HA setup costs 10.52 ms.** RDS Multi-AZ gives the same guarantee at about 4.4 to 7.4 ms. That
  is the same order of magnitude.
- **Self-healing costs 2.3 ms**: 10.52 ms on Longhorn against 8.19 ms for the same replication on node-local
  storage.
- **Synchronous replication costs more than the storage does**: +2.17 ms against +1.48 ms. The standby
  round-trip is about 2.5 ms, so the disk under it barely moves the total.
- **`dataLocality: best-effort` does not help Postgres.** It beat both-replicas-remote by 4%. A durable write
  must reach both replicas before the ack, so one replica is always a network hop away.
- **Managed Postgres wins on throughput more than on latency.** 374 tps is still 32M write transactions a day.

What the latency buys is in [13_node_loss.md](13_node_loss.md). On a machine loss, both databases served again
about 190s later with nobody involved. Node-local storage needed a human first.

## RabbitMQ, against managed queues

Publisher-confirm latency, 7 repeats, median. A confirm is the Raft-majority fsync across 3 brokers.

| Setup | p99 ms, 1 publisher | p99 ms, 100 publishers |
|---|---|---|
| local-path | 9.4 | 96.1 |
| Longhorn r2, both replicas remote | 26.7 | 122.5 |
| Longhorn r2, `best-effort`, what we ship | 18.4 | 107.8 |

- **At one publisher, Longhorn costs RabbitMQ far more than Postgres.** A quorum queue fsyncs on every broker,
  so it pays the storage cost three times.
- **Under load the gap nearly closes.** Raft batching spreads the fsync over many messages.
- **`best-effort` recovers 31% of p99** (18.4 against 26.7 ms). The cause is unknown. On a near-empty volume
  that is still worth it, so RabbitMQ gets the `-local` class.
- **RabbitMQ still beats managed queues on latency.** SQS Standard and Pub/Sub run at about 16 ms p50. They
  replicate across zones and sell unbounded scale without operations, which this table cannot show.

## How far to trust the result

The results are provisional.

- **The read-only control is not a control.** At `PGBENCH_SCALE=20` the data is larger than `shared_buffers`,
  so reads reach storage and differ by arm. The control has never passed. The fix is a CPU-bound control, then
  a re-run.
- **Runs agree.** The same setup, measured a day apart, gave 6.02 ms both times. The arms are what they claim:
  Postgres confirmed the sync arm was synchronous before any cell ran.
- **The RabbitMQ variance gate fails on 2 of 3 arms.** 5 of 7 repeats cluster tightly in every arm, so the
  medians hold.
- **Tail latency is bad on every arm, local-path included.** The worst single write took 8s on local-path. The
  cause is Pi 5 scheduling, 1GbE jitter and consumer NVMe, not the storage engine.

## Design of the benchmark

- **A script, not an Argo CD app.** Argo CD `selfHeal` and `prune` would recreate each bench object as teardown
  deletes it. The benchmark creates, measures and destroys in one run.
- **Not a `DANGEROUS_` script.** It deletes only objects it labelled. The prefix marks the scripts that wipe the
  cluster, and using it here would weaken it.
- **No CiliumNetworkPolicy in the bench namespace.** It is on the unpoliced list in
  [01_networking.md](01_networking.md). One silent drop would lose a five-hour run, and the namespace holds no
  data.
- **Live workloads keep running.** A paused cluster is not the cluster that runs in production. The script voids
  a cell when node CPU changes during it.

## What would change the answer

- A second NIC or 2.5GbE. The network is most of the storage delta.
- Longhorn V2/SPDK, once its ARM64 stuck-I/O bug is fixed. See [05_storage.md](05_storage.md).
- NVMe with power-loss protection. It would take fsync from about 1 ms to tens of microseconds. No such drive
  fits a Pi.

## Sources

- [RDS Multi-AZ](https://aws.amazon.com/rds/features/multi-az/)
- [RDS single-AZ figures](https://hostim.dev/blog/postgres-benchmark-rds-vs-hostim-vs-self-hosted/)
- [the 2-5ms Multi-AZ adder](https://thebuild.com/blog/2026/04/28/managed-postgres-examined-amazon-rds-for-postgresql)
- [SQS latency](https://lucvandonkersgoed.com/2022/09/06/serverless-messaging-latency-compared/)
- [Pub/Sub publish latency](https://docs.cloud.google.com/pubsub/docs/topic-troubleshooting)
