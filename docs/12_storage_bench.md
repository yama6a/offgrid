# Storage benchmark

The storage benchmark measures what Longhorn r2 and synchronous replication cost CNPG and RabbitMQ in write
latency. You run it on demand. It is not a bring-up step.

Its results back two live decisions in [05_storage.md](05_storage.md):

- Everything runs on Longhorn.
- RabbitMQ gets a local replica, and Postgres does not.

The `local-path` rows below are the baseline for the Longhorn numbers. That class is not installed here, so the
script cannot reproduce those rows.

Verdict: Longhorn adds real but small latency. Self-healing on a machine loss is worth that cost. Both numbers
land inside what the managed services deliver.

```bash
make storage-bench          # 2 locality arms x 3 workloads, ~2.3h
make storage-bench-fio      # fsync only, ~26 min, the shortest real answer
make storage-bench-sync     # what synchronous replication costs, 2 arms, ~45 min
make storage-bench-teardown
bash lib/shell/storage_bench.sh run --smoke              # tests the script, the numbers mean nothing
bash lib/shell/storage_bench.sh run --resume <dir>       # continue an interrupted run
bash lib/shell/storage_bench.sh report <dir>
bash lib/shell/storage_bench.sh corroborate <dir>        # compare with VictoriaMetrics, never inside a run
```

## Every scenario, against managed Postgres

- `avg` is pgbench's `latency average`. The cloud sources publish this figure.
- One client means no queueing.
- `pg-cluster` renders rows 4 and 6 with `highAvailability` set to false and true.

| # | Node loss costs | Storage | Inst | Replication | avg ms | p50 | p99 | tps 1cl | tps 8cl | Basis |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | an S3 restore | local-path (gone) | 1 | none | 6.02 | 5.40 | 12.25 | 166 | 731 | measured |
| 2 | a PVC delete, plus acked commits | local-path (gone) | 2 | async | ~6.0 | ~5.4 | ~12.3 | ~166 | ~731 | inferred from 1 |
| 3 | a PVC delete | local-path (gone) | 3 | sync `any 1` | 8.19 | 7.57 | 14.57 | 122 | 555 | measured |
| 4 | nothing | longhorn-r2 | 1 | none | 7.50 | 6.73 | 19.39 | 133 | 552 | measured. `highAvailability: false` today |
| 5 | acked commits | longhorn-r2 | 2 | async | ~7.5 | ~6.7 | ~19.4 | ~133 | ~552 | inferred from 4 |
| 6 | nothing | longhorn-r2 | 3 | sync `any 1` | 10.52 | 9.66 | 22.36 | 95 | 374 | measured. `highAvailability: true` today |
| 7 | RDS single-AZ, `db.t4g.medium` | EBS | 1 | none | 2.41 | | | 416 | 1080 at 4cl | third-party |
| 8 | RDS Multi-AZ | EBS | 1+1 | sync, cross-AZ | ~4.4-7.4 | | | | | 7 plus AWS's 2-5ms |
| 9 | RDS Multi-AZ DB Cluster | local NVMe | 1+2 | semi-sync, 3 AZ | not published | | | | | AWS: "2x faster" than 8 |
| 10 | Cloud SQL HA | regional PD | 1+1 | sync, cross-zone | not published | | | | | Google: direction only |
| 11 | Hetzner CPX22, self-hosted | network block | 1 | none | 3.63 | | | 276 | 1303 at 4cl | third-party |

- **Row 6 is what this repo ships.** It is the only row that costs nothing on a machine loss.
  - Row 8 is the managed equivalent: synchronous HA, no commit loss. It runs at ~4.4-7.4 ms against our
    10.52 ms. That is the same order of magnitude.
  - Row 3 is the same replication on node-local storage, at 8.19 ms. So self-healing costs 2.3 ms.
- **Synchronous replication costs more than the storage does**: +2.17 ms against +1.48 ms.
- **Managed Postgres wins on throughput more than on latency.** 374 tps is still 32M write transactions a day.
- **Rows 2 and 5 are inferred.** Async replication is not on the commit path. A commit waits only for the local
  WAL flush, so it matches the 1-instance number within noise.
- **Rows 7 and 11 also run `pgbench -c 1` on the commit path.** `db.t4g.medium` has 2 ARM vCPUs, and a Pi 5
  has 4. But they ran scale 50 for 60s, and we ran scale 20 for 180s. Row 7 is single-AZ, so row 8 is an
  estimate built on it.
- **No vendor publishes a latency figure or a latency SLA.** AWS's own three-way Multi-AZ benchmark reports New
  Orders Per Minute in a chart. Google documents only that regional disk is slower than zonal disk.

[13_node_loss.md](13_node_loss.md) measures recovery per row. That recovery is what the latency buys. On a
machine loss, both databases served again ~190s later with nobody involved. Node-local storage needed a human
and a 6-minute multi-attach wait first.

## Where the milliseconds go

| Instrument | local-path | longhorn r2 | Isolates |
|---|---|---|---|
| `pg_test_fsync` fdatasync 8kB | 0.98 ms | 1.44 ms (1.47x) | the volume. No network, no Postgres, no client |
| `pg_stat_io` WAL fsync mean | 1.28 ms | 2.39 ms (1.86x) | Postgres' own view of one fsync |
| fio fdatasync p99 | 2.83 ms | 8.85 ms (3.12x) | a saturating serial sync loop |
| `pg_stat_replication.flush_lag` | 2.4-2.7 ms | 2.4-2.7 ms | the synchronous standby round-trip |

- **The ratios differ because the instruments differ.** One is a mean over every fsync, one is a p99 over a
  saturating loop, one is a whole transaction with reads. They agree on direction and rough size.
- **Synchronous replication dominates.** The standby round-trip (~2.5 ms) is about five times the storage delta
  (~0.5 ms). So the disk under it barely moves the total.
- **`flush_lag` predicts the observed cost of sync** on both storages (2.17 and 2.93 ms). This is the strongest
  internal check in either run.
- **The sync arms differ by about the same as the async arms at one client, and by less at eight.** Moving both
  fsyncs onto Longhorn does not double the gap, because replication dominates.
- **`dataLocality: best-effort` does not speed up the write path.** It beat both-replicas-remote by only 4% on
  `pg_stat_io`. A durable write must reach both replicas before the ack. So one replica is always a network hop
  away, wherever the pod runs. Locality can only speed up a read. It is still useful on read-heavy volumes, but
  not as a way to reduce fsync cost.

## Both results are provisional: the `-S` control is not a control

The read-only control (`pgbench -S`) assumes reads come from cache, so they cannot differ between arms. But
`PGBENCH_SCALE=20` is ~300MB, and `shared_buffers` is 128MB. This size is chosen so writes reach the volume. So
reads also reach storage. A control that varies with the variable under test cannot pass when you compare
storage classes. It has never passed:

| Run | `-S` tps across arms | Spread |
|---|---|---|
| `20260802T1433Z` locality | 4820/4814/4856 against 1947/3245/3438 | 2.5x, and 1.77x within one arm |
| `20260803T1603Z` pgsync | 4952 down to 2447 | 2.02x |

The fix is a control that never touches storage, then a re-run. An example is a CPU-bound
`SELECT sum(i) FROM generate_series(...)`.

Until then, confidence rests on the gates that work and on agreement between runs:

- **Runs agree.** The same config, measured a day apart, agrees to 0.01 ms: 6.02 ms avg at one client in both
  runs. The Longhorn single instance agrees to 4% (7.82 and 7.50).
- **Repeat spread is low in the pgsync run**: 1.003x to 1.078x per cell, against a 1.5x threshold. The locality
  run was worse. 4 of 15 cells went over 1.5x, and the drift guard voided 4 cells.
- **The arms are what they claim.** Before any cell ran, Postgres confirmed the sync arm was synchronous and the
  async arm was not.
- **`pg_test_fsync` against fio fails on magnitude (2-3x) but passes on ranking.** This is expected. One is a
  mean over a small file, the other a p99 over 512MB. fdatasync cost grows with the count of dirty extents. The
  gate needs a rewrite to check ranking only.

RabbitMQ ran again at `--repeats 7`. See [its own table](#rabbitmq-against-managed-queues).

Tail latency is bad on every arm, local-path included. Worst single observation per arm:

| Arm | Max ms |
|---|---|
| local-path | 8,050 |
| lh-remote | 545 |
| lh-best-effort | 1,233 |

The cause is Pi 5 scheduling, 1GbE jitter, and a consumer NVMe without power-loss protection. It is not the
storage engine. The "stop if max > 10x p99" tripwire fires on the baseline too, so it does not tell arms apart.

## Arms

An arm is one storage configuration under test. The locality arms all run on one node, so storage is the only
variable. They measure the exact difference between the two shipped classes, so this pair is still
reproducible:

| Arm | StorageClass | Replica layout | Shipped as |
|---|---|---|---|
| `b-lh-remote` | `bench-lh-remote` | both replicas on the other two nodes | `longhorn-r2-ephemeral` |
| `c-lh-local` | `bench-lh-local` | `dataLocality: best-effort`, one replica under the pod | `longhorn-r2-ephemeral-local` |

The `pgsync` arms vary the replication mode on the shipped class:

| Arm | StorageClass | Instances | Replication | Shipped as |
|---|---|---|---|---|
| `f-lh-async` | `longhorn-r2-ephemeral` | 1 | none | `highAvailability: false` |
| `g-lh-sync` | `longhorn-r2-ephemeral` | 3 | `any 1`, `required` | `highAvailability: true` |

- **`b` against `c` prices `dataLocality`.** `g` minus `f` prices synchronous replication. The report does the
  subtraction.
- **The local-path rows came from the `a-local`, `d-local-async` and `e-local-sync` arms.** Those arms no longer
  exist, because the class is not installed. Their numbers stand as recorded, and nothing re-runs them.
- **pgsync uses the shipped class, not a bench class.** The question is whether the real databases move. So the
  real settings (`dataLocality: disabled`) are the ones to measure.
- **pgsync runs 3 instances, not 2.** With `any 1` of two standbys, a drained node does not stall writes. That
  makes a rolling node upgrade safe under `required`. A pre-drain replication-health gate stops the next drain
  until the displaced instance is back in sync.
- **The node tag keeps `b` remote.** Longhorn picks replica nodes by free space. It can silently put a replica
  under the pod, which turns `b` into `c` while the run still looks fine.
  - The script tags the two non-bench nodes `benchreplica`, and `bench-lh-remote` selects on that tag.
  - `allow-empty-node-selector-volume` is `true`, so existing volumes with no selector are unaffected.
  - Teardown removes the tags.
  - `c` needs no tag. `best-effort` places its local replica itself, on attach.
- **The wait gate keeps rebuilds out of `c`.** `best-effort` places the local replica at attach time, not at
  provision time. Longhorn adds a third replica on the pod's node, then drops a remote one. That is a rebuild,
  and a measurement during it measures the rebuild. Load starts only when both are true:
  - the volume is `robustness: healthy` with exactly 2 replicas
  - the replica layout matches the arm

### Threats specific to the pgsync arms

- **The client has contention.** 3 instances on 3 nodes put a database on every node, so `pgclient` shares a
  node with one. Only the sync arm has this. So it does not cancel out against the 1-instance async arm. It
  also makes neither arm comparable to the locality arms.
- **Primary placement is not controllable** with 3 instances. The script records it per cell in
  `primary-node.txt`, and the report gates on it.
- **`any 1` is best-of-two.** The primary waits for the faster standby. So these numbers are a little
  optimistic against a 2-instance cluster that waits on its one peer.

### The assertion that matters

CNPG ignores a malformed `synchronous` block. That would produce a full set of numbers that say sync is free.
So before any cell runs, the script asks Postgres to confirm both:

- `synchronous_standby_names` is not empty
- at least one standby reports `sync_state` as `sync` or `quorum`

If either check fails, the script skips the arm. It keeps the answer in `pgsync/<arm>/synchronous.txt` as proof
that the arm was what it claimed.

## What runs

| Workload | Tool | Reports |
|---|---|---|
| fsync | fio, job files in `lib/bench/fio/` | fdatasync percentiles. The primary storage number |
| Postgres | `pg_test_fsync` then pgbench, from the CNPG image | usec/op per sync method. Commit latency and tps |
| AMQP | `pivotalrabbitmq/perf-test` on a quorum queue | publisher-confirm latency |

Both Postgres tools ship in the CNPG image, so no extra image is needed. The decision metric is pgbench `-c 1`.
At one client the WAL fsync dominates it, and it is what a user of the app feels.

- **`ioengine=psync`, `iodepth=1`, `numjobs=1`.** The WAL writer and Ra both write, then sync, one op at a time.
  A deep queue would measure the drive, and neither app uses one. Ra is RabbitMQ's Raft library.
- **`fdatasync=1`, `direct=0`.** This reproduces `wal_sync_method=fdatasync`. `direct=1` bypasses the page cache
  and measures something Postgres never does.
- **`bs=8k` is `wal_block_size`.** The load is far below the lane's ~450 MB/s on purpose. The test is bound by
  latency, not bandwidth.
- **`wal-group-commit.fio` is the same job at `numjobs=4`.** This is the best case for Longhorn. If the per-op
  replication cost amortizes under concurrency, the serial number overstates it.
- **`pgbench -i -s 20` meets two floors.** Higher values only make setup longer.
  - The TPC-B script updates `pgbench_branches`, which has exactly `scale` rows. Scale must be >= the client
    count (8), or the run measures row-lock contention.
  - The dataset (~300MB) must be larger than `shared_buffers`, or writes never reach the volume.
- **Commit settings stay at production values**: `synchronous_commit`, `fsync`, `full_page_writes`,
  `checkpoint_timeout`. Otherwise the result does not transfer.

## Confound control

A confound is anything other than the storage setting that can change a result.

- **One cell at a time, cluster-wide**, with 60s idle between cells. A cell is one workload on one arm.
- **fio runs repeat-major and palindromic**: forward, reversed, forward. Linear drift, such as thermal soak, a
  CronJob or an ArgoCD poll, cancels out. It does not load onto the arm that runs last. This is affordable
  because fio setup is only a PVC and a pod.
- **pgbench and amqp run arm-major**: provision once, then loop the repeats.
  - Repeat-major would rebuild a CNPG cluster and reload the dataset 9 times instead of 3. That is an hour of
    churn for no extra information.
  - Cost: an arm's repeats run next to each other in time, so drift shows as variance within a cell. The 1.5x
    gate catches it.
- **Warm-up is discarded**: fio `ramp_time`, the first 60s of pgbench in post-processing, and the first
  perf-test intervals.
- **Live workloads are recorded, not paused.** A paused cluster is not the cluster that runs in production.
  - The script captures `kubectl top nodes` before and after every cell. A CPU change of more than 25 points
    voids the cell.
  - It samples after the settle sleep, never right after load. `kubectl top` serves a rolling average, so an
    early sample reads the benchmark's own CPU.
  - If the check fires on most cells, raise `INTER_CELL_SLEEP`. Never raise `CPU_DRIFT_ABORT`, because that
    hides real interference from other pods.
- **Clients run on a different node from the target.** The pgsync arms are the exception. Their 3 instances
  leave no free node.
- **`--smoke` runs every code path at minimum settings.** Its output goes to `<UTC>-SMOKE/`. The numbers mean
  nothing by design. Do not quote them.

## Output

Results go to `.cache/storage-bench/<UTC>/`, which is gitignored:

- raw tool output per arm and per repeat
- `summary.md` with the tables and the gate checklist

If any gate is unchecked, the run is invalid. Publish no verdict.

VictoriaMetrics only corroborates. It runs as a separate sub-command, never as a hidden port-forward inside a
run. At `scrapeInterval: 60s`, a 150s cell gives two samples. So it can contradict the tools, but not replace
them.

## Safety

- **Scoped deletes.** Every object carries `bench.offgrid/owner=storage_bench.sh`, and every delete selects on
  it.
- **No priority class.** Bench pods have no `priorityClassName`, so they run at priority 0, below
  `data-critical`. Node-pressure eviction reaches the benchmark before any database. Never give a bench pod a
  priority class.
- **Preflight fails hard** on any of these:
  - a degraded cluster
  - a Longhorn rebuild in progress. It saturates the exact path under test.
  - an ArgoCD sync in progress
  - a CNPG backup in progress
- **Teardown on exit.** A `trap` tears down on exit and on interrupt.
- **Not a `DANGEROUS_` script.** It creates and destroys only what it labelled. That prefix marks the three
  scripts that wipe the cluster. Using it here would weaken it.
- **Not an ArgoCD app.** Every app here is `automated` with `selfHeal` and `prune`. So Argo would recreate each
  bench object as teardown deleted it. The benchmark creates, measures and destroys in one run, which is the
  opposite of a reconciled steady state. The script applies it directly, like a one-shot probe pod.
- **Default Pod Security level.** The bench namespace takes the cluster default: `enforce: baseline` with
  `warn: restricted`. So `kubectl apply` prints restricted warnings and still admits the pods.
  - Nothing is privileged, host-networked or hostPath-mounted.
  - The fio pod runs as root because `apk add fio` needs it. It drops all capabilities and uses
    `seccompProfile: RuntimeDefault`.
  - Do not set `privileged` on the bench namespace.
- **No CiliumNetworkPolicy in the bench namespace.** It is on the unpoliced list in
  [`01_networking.md`](01_networking.md). A policy would have to allow DNS, the package fetch, both operators,
  kubelet probes, AMQP and 5432 correctly on the first try. One silent drop loses a five-hour run. The namespace
  exists for hours and holds no data.
- **One CNP is required, in the `rabbitmq` namespace.**
  - `03_rabbitmq`'s operator policy allows egress to the management API with a bare
    `matchLabels: {app.kubernetes.io/name: rabbitmq}`.
  - With no namespace key, Cilium matches only the operator's own namespace and that exact cluster name.
  - So the operator cannot reach a bench broker in another namespace, and that cluster never finishes forming.
  - A rename does not help, because the label's value is the cluster name.
  - An additive CNP widens that one rule. Cilium unions policies, so no chart edit is needed and `selfHeal` does
    not revert it.
  - It lives outside the bench namespace, so `kubectl delete ns` does not remove it. Teardown deletes it by
    name. The same applies to the two StorageClasses and the node tags.

## Teardown

`make storage-bench-teardown` is idempotent and safe on a clean cluster.

- The `RabbitmqCluster` carries a finalizer. So teardown deletes it and waits for it before it deletes the
  namespace. Otherwise the namespace stays in `Terminating` forever.
- The bench broker sets `terminationGracePeriodSeconds: 30`. The live broker uses 7 days, which would block
  teardown for a week. This is the one place where the bench differs from production on purpose.

## What would change the answer

- A second NIC or 2.5GbE. The network is most of the storage delta.
- Longhorn V2/SPDK, once its ARM64 stuck-I/O bug is fixed. See [`05_storage.md`](05_storage.md).
- NVMe with power-loss protection. It would take fsync from ~1 ms to tens of microseconds and remove most of the
  tail. No such drive exists in a form factor that fits a Pi.

## RabbitMQ, against managed queues

Run `20260803T2021Z`, 7 repeats, median across repeats. `perf-test` confirm latency is the time from publish to
the Raft-majority fsync across 3 brokers. It is a durability ack, not a delivery.

| # | Config | Measures | p50 ms | p99 ms | msg/s | Basis |
|---|---|---|---|---|---|---|
| 1 | local-path (gone), 1 publisher | confirm | 4.8 | 9.4 | 188 | measured |
| 2 | longhorn-r2, both replicas remote, 1 pub | confirm | 10.5 | 26.7 | 86 | measured |
| 3 | longhorn-r2 `best-effort`, 1 pub | confirm | 9.1 | 18.4 | 102 | measured. What we ship |
| 4 | local-path (gone), 100 publishers | confirm | 50.7 | 96.1 | 1870 | measured |
| 5 | longhorn-r2 remote, 100 pub | confirm | 54.2 | 122.5 | 1608 | measured |
| 6 | longhorn-r2 `best-effort`, 100 pub | confirm | 53.5 | 107.8 | 1750 | measured |
| 7 | SQS, server side | AWS processing time alone | 5-10 | | | AWS support, via an SDK issue |
| 8 | SQS Standard | producer to consumer, eu-west-1 | 16.2 | 105 | | third-party, 2022 |
| 9 | SQS FIFO | producer to consumer | 28.1 | 645 | | third-party, 2022 |
| 10 | Pub/Sub publish | publish to ack | ~16 | 60-70 at p95 | | Google's own prober jobs |

- **At one publisher, Longhorn costs RabbitMQ 2.8x on confirm p99 and 54% of throughput.** That is far more than
  the 1.5x it costs Postgres. A quorum queue fsyncs per Raft batch on every broker. So it pays the storage cost
  three times, and the confirm waits for the majority.
- **Under load the gap nearly closes**: 1.27x on p99 and 86% of throughput at 100 publishers. Raft batching
  amortizes the fsync. So the single-publisher figure is the worst case, not the typical one.
- **`dataLocality: best-effort` recovers 31% here** (18.4 against 26.7). For Postgres it recovered 4%.
  - The both-replicas argument that explains Postgres does not explain this. The cause is unknown.
  - RabbitMQ still gets the `-local` class. 31% for a near-empty volume is worth it without a known mechanism.
  - Postgres does not. 4% is not worth moving a database across 1GbE on every failover.
- **RabbitMQ beats both managed queues on latency, even on Longhorn.** This is expected, and it is not the
  point. The managed queues replicate across zones or regions behind an API. A Google engineer states that
  sub-10 ms is out of reach for Pub/Sub by design. They sell unbounded scale and no operations, which this
  table cannot show.
- **Rows 7 and 10 are the fair comparisons.** Rows 1-6 are a durability ack. Rows 8 and 9 include the
  consumer poll, so they do not compare like for like.
- **Neither vendor publishes a latency SLO.** AWS documents "tens or low hundreds of milliseconds". Google's SLA
  covers availability and points at `topic/send_request_latencies` so you can measure latency yourself.

### The variance gate is the wrong statistic

At one publisher, two of three arms fail the gate. In each, 2 of 7 repeats are outliers:

| arm | sorted p99 across 7 repeats | range gate |
|---|---|---|
| `a-local` (local-path, no longer runs) | 7.5 8.0 9.4 9.4 9.5 9.8 9.9 | 1.33x, pass |
| `b-lh-remote` | 24.2 24.3 25.4 26.7 27.3 32.7 37.7 | 1.56x, fail |
| `c-lh-local` | 16.9 16.9 17.1 18.4 19.6 29.9 39.9 | 2.36x, fail |

- Five of seven repeats cluster tightly in every arm, so the medians hold.
- The gate is max/min, and the range of a sample grows with sample size. So more repeats make a range gate
  more likely to fail. `--repeats 7` cannot fix it.
- Replace it with a statistic that outliers do not move, such as an interquartile spread or a tolerance
  around the median of repeats.
- The outliers are not a warm-up artifact. At 7 repeats they land on r3 and r7, not r1.

## Sources

- [RDS Multi-AZ](https://aws.amazon.com/rds/features/multi-az/)
- [AWS's three-way benchmark](https://aws.amazon.com/blogs/database/benchmark-amazon-rds-for-postgresql-single-az-db-instance-multi-az-db-instance-and-multi-az-db-cluster-deployments)
- [Multi-AZ DB cluster](https://aws.amazon.com/blogs/aws/amazon-rds-multi-az-db-cluster)
- [Cloud SQL HA](https://docs.cloud.google.com/sql/docs/postgres/high-availability)
- [rows 7 and 11](https://hostim.dev/blog/postgres-benchmark-rds-vs-hostim-vs-self-hosted/)
- [the 2-5ms adder](https://thebuild.com/blog/2026/04/28/managed-postgres-examined-amazon-rds-for-postgresql)
- [SQS and SNS percentiles](https://lucvandonkersgoed.com/2022/09/06/serverless-messaging-latency-compared/)
- [SQS latency guidance](https://aws.amazon.com/sqs/faqs/)
- [Pub/Sub troubleshooting and publish latency](https://docs.cloud.google.com/pubsub/docs/topic-troubleshooting)
