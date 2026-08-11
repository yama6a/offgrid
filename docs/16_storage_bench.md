# 16: Storage benchmark

What Longhorn r2 and synchronous replication cost CNPG and RabbitMQ in write latency. On-demand, not a
bring-up step.

This is also the evidence behind two live decisions: everything runs on Longhorn, and RabbitMQ gets a local
replica while Postgres does not ([08_storage.md](08_storage.md)). The `local-path` rows below are the baseline
the Longhorn numbers are measured against. That class is not installed here, so the script cannot reproduce
those rows.
The verdict they support: Longhorn's latency cost is real but small, self-healing on a machine loss is worth it,
and both numbers land inside what the managed services deliver.

```bash
make storage-bench          # 2 locality arms x 3 workloads, ~2.3h
make storage-bench-fio      # fsync only, ~26 min, the shortest real answer
make storage-bench-sync     # what synchronous replication costs, 2 arms, ~45 min
make storage-bench-teardown
bash lib/shell/storage_bench.sh run --smoke              # proves the script, numbers are garbage
bash lib/shell/storage_bench.sh run --resume <dir>       # pick up an interrupted run
bash lib/shell/storage_bench.sh report <dir>
bash lib/shell/storage_bench.sh corroborate <dir>        # vs VictoriaMetrics, never inside a run
```

## Every scenario, against managed Postgres

`avg` is pgbench's `latency average`, the figure the cloud sources publish. One client: no queueing.
`pg-cluster`'s `highAvailability` false and true render rows 1 and 2.

| # | Node loss costs | Storage | Inst | Replication | avg ms | p50 | p99 | tps 1cl | tps 8cl | Basis |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | an S3 restore | local-path (gone) | 1 | none | 6.02 | 5.40 | 12.25 | 166 | 731 | measured |
| 2 | a PVC delete, plus acked commits | local-path (gone) | 2 | async | ~6.0 | ~5.4 | ~12.3 | ~166 | ~731 | inferred from 1 |
| 3 | a PVC delete | local-path (gone) | 3 | sync `any 1` | 8.19 | 7.57 | 14.57 | 122 | 555 | measured |
| 4 | nothing | longhorn-r2 | 1 | none | 7.50 | 6.73 | 19.39 | 133 | 552 | measured; **`highAvailability: false` today** |
| 5 | acked commits | longhorn-r2 | 2 | async | ~7.5 | ~6.7 | ~19.4 | ~133 | ~552 | inferred from 4 |
| 6 | nothing | longhorn-r2 | 3 | sync `any 1` | 10.52 | 9.66 | 22.36 | 95 | 374 | measured; **`highAvailability: true` today** |
| 7 | RDS single-AZ, `db.t4g.medium` | EBS | 1 | none | 2.41 | | | 416 | 1080 at 4cl | third-party |
| 8 | RDS Multi-AZ | EBS | 1+1 | sync, cross-AZ | ~4.4-7.4 | | | | | 7 plus AWS's 2-5ms |
| 9 | RDS Multi-AZ DB Cluster | local NVMe | 1+2 | semi-sync, 3 AZ | not published | | | | | AWS: "2x faster" than 8 |
| 10 | Cloud SQL HA | regional PD | 1+1 | sync, cross-zone | not published | | | | | Google: direction only |
| 11 | Hetzner CPX22, self-hosted | network block | 1 | none | 3.63 | | | 276 | 1303 at 4cl | third-party |

- Row 6 is what we ship, and it is the only row that costs nothing on a machine loss. Against row 8, the
  like-for-like managed equivalent (synchronous HA, no commit loss): 10.52 ms against ~4.4-7.4 ms. Same order.
  Row 3 is the same replication on node-local storage, at 8.19 ms, so self-healing costs 2.3 ms.
- Synchronous replication costs more than the storage does: +2.17 ms against +1.48 ms.
- The gap against managed Postgres is throughput, not latency. 374 tps is 32M write transactions a day.
- Rows 2 and 5 are inferred: async replication sits off the commit path, so a commit waits only for the
  local WAL flush and should match the 1-instance number within noise.
- Rows 7 and 11 are also `pgbench -c 1` on the commit path, and `db.t4g.medium` is 2 vCPU ARM against a
  Pi 5's 4. But scale 50 for 60s against our scale 20 for 180s, and row 7 is SINGLE-AZ, hence 8's estimate.
- No vendor publishes a latency figure or a latency SLA. AWS's own three-way Multi-AZ benchmark reports
  New Orders Per Minute in a chart; Google documents only that regional disk is slower than zonal.

Recovery behaviour per row is measured separately, in [`15_node_recovery.md`](15_node_recovery.md), and that is
what the latency buys: on a machine loss both databases were serving again ~190s later with nobody involved,
where node-local storage needed a human and a 6-minute multi-attach wait first.

## Where the milliseconds go

| Instrument | local-path | longhorn r2 | Isolates |
|---|---|---|---|
| `pg_test_fsync` fdatasync 8kB | 0.98 ms | 1.44 ms (1.47x) | the volume. No network, no Postgres, no client |
| `pg_stat_io` WAL fsync mean | 1.28 ms | 2.39 ms (1.86x) | Postgres' own view of one fsync |
| fio fdatasync p99 | 2.83 ms | 8.85 ms (3.12x) | a saturating serial sync loop |
| `pg_stat_replication.flush_lag` | 2.4-2.7 ms | 2.4-2.7 ms | the synchronous standby round-trip |

- Ratios differ because the instruments differ: a mean over every fsync, a p99 over a saturating loop,
  a whole transaction including reads. Direction and rough size agree.
- The standby round-trip (~2.5 ms) is about five times the storage delta (~0.5 ms). That is why
  synchronous replication dominates and the disk under it barely moves the total.
- `flush_lag` predicts the observed price of sync (2.17 and 2.93 ms) on both storages, which is the
  strongest internal check in either run.
- **`dataLocality: best-effort` does not rescue the write path.** It beat both-replicas-remote by 4% on
  `pg_stat_io`. A durable write must reach both replicas before it is acknowledged, so one is always a
  network hop away wherever the pod sits. Locality can only save a read. Still worth having on
  read-heavy volumes; not as a way to buy back fsync.

Written down before the sync run, and wrong: the sync arms were predicted to differ by ~2x the async
gap, since both the primary's and the standby's fsync move onto Longhorn. They differ by about the same
at one client and LESS at eight. Replication dominates.

## Both results are provisional: the `-S` control is not a control

The read-only control assumes reads come from cache and so cannot differ between arms. `PGBENCH_SCALE=20`
is ~300MB against `shared_buffers` of 128MB, chosen so writes reach the volume. Reads therefore hit
storage by construction, and a control that varies with the variable under test cannot pass while
comparing storage classes. It never has:

| Run | `-S` tps across arms | Spread |
|---|---|---|
| `20260802T1433Z` locality | 4820/4814/4856 against 1947/3245/3438 | 2.5x, and 1.77x within one arm |
| `20260803T1603Z` pgsync | 4952 down to 2447 | 2.02x |

Fixing it means a control that never touches storage, for example a CPU-bound
`SELECT sum(i) FROM generate_series(...)`, then re-running.

Confidence rests on the gates that do work, and on agreement between runs:

- The same config measured a day apart agrees to 0.01 ms: 6.02 ms avg at one client in both runs. The
  Longhorn single instance agrees to 4% (7.82 and 7.50).
- Repeat spread 1.003x to 1.078x per pgsync cell, against a 1.5x threshold. The locality run was worse:
  4 of 15 cells over 1.5x, and 4 cells voided by the drift guard.
- The sync arm proved synchronous against Postgres before any cell ran; the async arm proved it was not.
- `pg_test_fsync` vs fio fails on magnitude (2-3x) but passes on ranking. Expected: a mean over a tiny
  file against a p99 over 512MB, and fdatasync cost grows with dirty extent count. The gate needs
  rewriting as ranking-only.

RabbitMQ was re-run at `--repeats 7`; see its own table below.

**Tail latency is bad on every arm, local-path included.** Worst single observation: local-path 8,050 ms,
lh-remote 545 ms, lh-best-effort 1,233 ms. That is Pi 5 scheduling, 1GbE jitter and a consumer NVMe
without power-loss protection, not the storage engine. The "stop if max > 10x p99" tripwire fires on the
baseline, so it does not discriminate.

## Arms

Locality arms, all pinned to ONE node so storage is the only variable. They price exactly the difference
between the two shipped classes, so this pair is still reproducible:

| Arm | StorageClass | Replica layout | Shipped as |
|---|---|---|---|
| `b-lh-remote` | `bench-lh-remote` | both replicas on the OTHER two nodes | `longhorn-r2-ephemeral` |
| `c-lh-local` | `bench-lh-local` | `dataLocality: best-effort`, one replica under the pod | `longhorn-r2-ephemeral-local` |

`pgsync` arms, replication mode on the shipped class:

| Arm | StorageClass | Instances | Replication | Shipped as |
|---|---|---|---|---|
| `f-lh-async` | `longhorn-r2-ephemeral` | 1 | none | `highAvailability: false` |
| `g-lh-sync` | `longhorn-r2-ephemeral` | 3 | `any 1`, `required` | `highAvailability: true` |

- `b` vs `c` prices `dataLocality`. `g-f` prices synchronous replication. The report does the subtraction.
- The `a-local`, `d-local-async` and `e-local-sync` arms that produced the local-path rows above are gone
  with the class. Their numbers stand as recorded; nothing re-runs them.
- pgsync uses the SHIPPED class, not the bench ones, because the decision is whether the real databases
  move, so the real settings (`dataLocality: disabled`) are the ones that matter.
- 3 instances, not 2: `any 1` of two standbys survives one node being drained without stalling writes,
  which is what makes a rolling Talos upgrade safe under `required`. `03e`'s `wait_replication_healthy`
  stops the next drain before the displaced instance is back in sync.
- **The node tag exists because Longhorn picks replica nodes by free space** and will silently put one
  under the pod, turning `b` into `c` while the run still looks fine. The two non-bench nodes are tagged
  `benchreplica` and `bench-lh-remote` selects on it. `allow-empty-node-selector-volume` is `true`, so
  existing no-selector volumes are unaffected. Teardown removes the tags. `c` needs no tag: `best-effort`
  places its local replica itself, on attach.
- **The wait gate exists because `best-effort` places that replica at ATTACH, not provision:** Longhorn
  adds a third replica on the pod's node then drops a remote one, which is a rebuild. Measuring during
  it measures the rebuild. Load starts only once the volume is `robustness: healthy` at exactly 2
  replicas AND the layout matches the arm.

### Threats specific to the pgsync arms

- **The client is no longer uncontended.** 3 instances on 3 nodes means every node hosts a database, so
  `pgclient` shares one. That is true of the sync arm only, so it does NOT cancel against the 1-instance async
  arm, and it makes neither comparable to the locality arms.
- **Primary placement is not controllable** with 3 instances. Recorded per cell in `primary-node.txt`
  and gated in the report.
- **`any 1` is best-of-two.** The primary waits for the faster standby, so these are mildly optimistic
  against a 2-instance cluster waiting on one peer.

### The assertion that matters

A malformed `synchronous` block that CNPG ignores would yield a full set of numbers saying sync is free.
So Postgres is asked before any cell runs: `synchronous_standby_names` non-empty AND some standby
reporting `sync_state` of `sync` or `quorum`. Failure SKIPS the arm. Kept in
`pgsync/<arm>/synchronous.txt` as evidence the arm was what it claimed.

## What runs

| Workload | Tool | Reports |
|---|---|---|
| fsync | fio, job files in `lib/bench/fio/` | fdatasync percentiles. The primary storage number |
| Postgres | `pg_test_fsync` then pgbench, from the CNPG image | usec/op per sync method; commit latency + tps |
| AMQP | `pivotalrabbitmq/perf-test` on a quorum queue | publisher-confirm latency |

Both Postgres tools ship in the CNPG image, so no extra image. Decision metric is pgbench `-c 1`: at
one client it is dominated by the WAL fsync, and it is what a user of the app would feel.

- `ioengine=psync`, `iodepth=1`, `numjobs=1`: the WAL writer and Ra both write-then-sync serially. A
  deep queue would measure the drive, which neither app uses.
- `fdatasync=1`, `direct=0`: reproduces `wal_sync_method=fdatasync`. `direct=1` would bypass the page
  cache and measure something Postgres never does.
- `bs=8k` is `wal_block_size`. Nowhere near the lane's ~450 MB/s, deliberately: latency-bound, not
  bandwidth-bound.
- `wal-group-commit.fio` is the same at `numjobs=4`, the strongest case FOR Longhorn: if per-op
  replication cost amortizes under concurrency, the serial number overstates it.
- `pgbench -i -s 20` has two floors, both satisfied. The TPC-B script updates `pgbench_branches`, which
  has exactly `scale` rows, so scale must be >= client count (8) or the run measures row-lock contention.
  And ~300MB must exceed `shared_buffers` or writes never reach the volume. Higher only lengthens setup.
- Everything deciding commit cost (`synchronous_commit`, `fsync`, `full_page_writes`,
  `checkpoint_timeout`) stays at its production value, or the result does not transfer.

## Confound control

- One cell at a time cluster-wide, 60s idle between cells.
- **fio runs repeat-major and palindromic**: forward, reversed, forward. Linear drift (thermal soak, a
  CronJob, an ArgoCD poll) cancels instead of loading onto whichever arm runs last. Affordable because
  its setup is a PVC and a pod.
- **pgbench and amqp run arm-major**: provision once, loop the repeats. Repeat-major would rebuild a
  CNPG cluster and reload the dataset 9 times instead of 3, an hour of churn for no extra information.
  Cost: an arm's repeats sit adjacent in time, so drift shows as within-cell variance. The 1.5x gate
  catches it.
- Warm-up: fio `ramp_time`, pgbench's first 60s dropped in post-processing, perf-test's first intervals
  ignored.
- Live workloads are **recorded, not quiesced**. Quiescing would describe a cluster that does not exist.
  `kubectl top nodes` is captured either side of every cell; more than 25 points of CPU movement voids it.
  Sampled after the settle sleep, never immediately after load, because `kubectl top` serves a rolling
  average and an immediate sample re-reads the benchmark's own CPU. If it fires on most cells, raise
  `INTER_CELL_SLEEP`, never `CPU_DRIFT_ABORT`, which would hide real neighbour interference.
- Clients run on a different node from the thing under test, except in the pgsync arms, where 3
  instances leave no free node.
- `--smoke` exercises every path at minimum settings and its output lands in `<UTC>-SMOKE/`. The numbers
  are meaningless by construction. Do not quote them.

## Output

`.cache/storage-bench/<UTC>/`, gitignored. Raw tool output per arm per repeat, plus `summary.md` with the
tables and the gate checklist. Any unchecked gate means INVALID: publish no verdict.

VictoriaMetrics is corroboration only, and a separate sub-command, never a hidden port-forward inside a
run. At `scrapeInterval: 60s` a 150s cell yields two samples, so it can contradict the tools but not
replace them.

## Safety

- Everything carries `bench.raspi-cluster/owner=storage_bench.sh` and every delete is scoped to it.
- Bench pods carry **no `priorityClassName`**, so they sit at priority 0, below `data-critical`.
  Node-pressure eviction reaches the benchmark before any database. Never give a bench pod a priority class.
- Preflight hard-fails on a degraded cluster, an in-flight Longhorn rebuild (it saturates the exact path
  under test), an ArgoCD sync, or a running CNPG backup.
- `trap`-based teardown on exit and interrupt.
- Not a `DANGEROUS_` script: it creates and destroys only what it labelled. That prefix marks the three
  scripts that wipe the cluster, and diluting it would make it useless.
- Not an ArgoCD app: every app here is `automated` + `selfHeal` + `prune`, so Argo would recreate each
  bench object as teardown deleted it. Create-measure-destroy inside one invocation is the opposite of a
  reconciled steady state. Applied imperatively, like `03c`'s probe pod.
- The bench namespace takes the cluster default, `enforce: baseline` with `warn: restricted`, so
  `kubectl apply` prints restricted warnings and admits anyway. Nothing is privileged, host-networked or
  hostPath-mounted. The fio pod runs as root because `apk add fio` needs to, dropping all capabilities
  with `seccompProfile: RuntimeDefault`. **Do not stamp `privileged` on the bench namespace.**
- The bench namespace carries **no CiliumNetworkPolicy**, a deliberate addition to the unpoliced list in
  [`04_networking.md`](04_networking.md). Policing it would mean getting DNS, the package fetch, both
  operators, kubelet probes, AMQP and 5432 right first time or losing a five-hour run to a silent drop.
  It exists for hours and holds no data.
- **One CNP IS required, in the `rabbitmq` namespace.** `03_rabbitmq`'s operator policy allows egress to
  the management API via a bare `matchLabels: {app.kubernetes.io/name: rabbitmq}`. With no namespace key
  Cilium reads that as the operator's own namespace and that exact cluster name, so the operator cannot
  reach a bench broker elsewhere and the cluster never finishes forming. Renaming does not help: the
  label's value IS the cluster name. An additive CNP widens that one rule; Cilium unions policies, so no
  chart edit and no `selfHeal` fight. It lives OUTSIDE the bench namespace, so `kubectl delete ns` does
  not reach it. Teardown deletes it by name, same for the two StorageClasses and the node tags.

## Teardown

`make storage-bench-teardown`. Idempotent, safe on a clean cluster. The `RabbitmqCluster` carries a
finalizer, so it is deleted and waited on BEFORE the namespace, or the namespace hangs in `Terminating`
forever.

The bench broker sets `terminationGracePeriodSeconds: 30`. The live one is 7 days; inheriting that would
wedge teardown for a week. The one place the bench breaks parity with production on purpose.

## What would change the answer

- A second NIC or 2.5GbE, which is most of the storage delta.
- Longhorn V2/SPDK, once its ARM64 stuck-I/O bug is fixed. See [`08_storage.md`](08_storage.md).
- NVMe with power-loss protection, which would take fsync from ~1 ms to tens of microseconds and remove
  most of the tail. Does not exist in a Pi-friendly form factor.

## RabbitMQ, against managed queues

Run `20260803T2021Z`, 7 repeats. Median across repeats. `perf-test` confirm latency is publish to
Raft-majority fsync across 3 brokers, a DURABILITY ack, not a delivery.

| # | Config | Measures | p50 ms | p99 ms | msg/s | Basis |
|---|---|---|---|---|---|---|
| 1 | local-path (gone), 1 publisher | confirm | 4.8 | 9.4 | 188 | measured |
| 2 | longhorn-r2, both replicas remote, 1 pub | confirm | 10.5 | 26.7 | 86 | measured |
| 3 | longhorn-r2 `best-effort`, 1 pub | confirm | 9.1 | 18.4 | 102 | measured; **what we ship** |
| 4 | local-path (gone), 100 publishers | confirm | 50.7 | 96.1 | 1870 | measured |
| 5 | longhorn-r2 remote, 100 pub | confirm | 54.2 | 122.5 | 1608 | measured |
| 6 | longhorn-r2 `best-effort`, 100 pub | confirm | 53.5 | 107.8 | 1750 | measured |
| 7 | SQS, server side | AWS processing time alone | 5-10 | | | AWS support, via an SDK issue |
| 8 | SQS Standard | producer to consumer, eu-west-1 | 16.2 | 105 | | third-party, 2022 |
| 9 | SQS FIFO | producer to consumer | 28.1 | 645 | | third-party, 2022 |
| 10 | Pub/Sub publish | publish to ack | ~16 | 60-70 at p95 | | Google's own prober jobs |

- Longhorn costs RabbitMQ **2.8x on confirm p99 at one publisher** and 54% of throughput. Far worse than
  the 1.5x it costs Postgres, because a quorum queue fsyncs per Raft batch on every broker, so the
  storage penalty is paid three times and the confirm waits for the majority.
- **Under load the gap nearly closes**: 1.27x on p99 and 86% of throughput at 100 publishers. Raft
  batching amortizes the fsync, so the single-publisher figure is the worst case, not the typical one.
- **`dataLocality: best-effort` recovers 31% here** (18.4 against 26.7), where it recovered 4% for
  Postgres. Not explained by the both-replicas argument that covers Postgres. Unresolved, and the reason
  RabbitMQ gets the `-local` class: 31% for a near-empty volume is worth taking even without the mechanism
  nailed down, whereas 4% for a database that must be dragged across 1GbE on every failover is not.
- RabbitMQ beats both managed queues on latency even on Longhorn, which is unsurprising and not the
  point: they replicate across zones or regions behind an API. A Google engineer states plainly that
  sub-10 ms is out of reach for Pub/Sub by design. What they sell is unbounded scale and no operations,
  which this table cannot show.
- Rows 1-6 are a durability ack. Rows 8 and 9 include the consumer poll, so they are NOT like-for-like.
  Rows 7 and 10 are the honest analogues.
- Neither vendor publishes a latency SLO. AWS documents "tens or low hundreds of milliseconds"; Google's
  SLA covers availability and points at `topic/send_request_latencies` to measure yourself.

### The variance gate is the wrong statistic

Two of three arms fail it at one publisher, on 2 outlying repeats out of 7:

| arm | sorted p99 across 7 repeats | range gate |
|---|---|---|
| `a-local` (arm since removed) | 7.5 8.0 9.4 9.4 9.5 9.8 9.9 | 1.33x, pass |
| `b-lh-remote` | 24.2 24.3 25.4 26.7 27.3 **32.7 37.7** | 1.56x, fail |
| `c-lh-local` | 16.9 16.9 17.1 18.4 19.6 **29.9 39.9** | 2.36x, fail |

Five of seven cluster tightly in every arm, so the medians hold. The gate does not, and cannot: it is
max/min, and **the range of a sample grows with sample size**. Raising repeats makes a range gate
strictly MORE likely to fail, so this doc's own prescription of `--repeats 7` could never have fixed it.
Replace it with a robust statistic, an interquartile spread or a median-of-repeats tolerance.

A warm-up artifact was suspected from the 3-repeat data, where both Longhorn arms fell monotonically.
Wrong: at 7 repeats the outliers land on r3 and r7, not r1.

## Sources

[RDS Multi-AZ](https://aws.amazon.com/rds/features/multi-az/) .
[AWS's three-way benchmark](https://aws.amazon.com/blogs/database/benchmark-amazon-rds-for-postgresql-single-az-db-instance-multi-az-db-instance-and-multi-az-db-cluster-deployments) .
[Multi-AZ DB cluster](https://aws.amazon.com/blogs/aws/amazon-rds-multi-az-db-cluster) .
[Cloud SQL HA](https://docs.cloud.google.com/sql/docs/postgres/high-availability) .
[rows 7 and 11](https://hostim.dev/blog/postgres-benchmark-rds-vs-hostim-vs-self-hosted/) .
[the 2-5ms adder](https://thebuild.com/blog/2026/04/28/managed-postgres-examined-amazon-rds-for-postgresql) .
[SQS and SNS percentiles](https://lucvandonkersgoed.com/2022/09/06/serverless-messaging-latency-compared/) .
[SQS latency guidance](https://aws.amazon.com/sqs/faqs/) .
[Pub/Sub troubleshooting and publish latency](https://docs.cloud.google.com/pubsub/docs/topic-troubleshooting)
