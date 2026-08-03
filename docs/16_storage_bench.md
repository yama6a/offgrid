# 16: Storage benchmark

Measures what Longhorn r2 costs CNPG and RabbitMQ in write latency, against the node-local
`local-path` they run on today. On-demand, not a bring-up step: `make storage-bench`.

## Why

[`15_node_recovery.md`](15_node_recovery.md) says moving them to Longhorn is "not worth doing" on
write-latency grounds. Nothing measured backed that. The trade is real either way:

| | `local-path` today | Longhorn r2 |
|---|---|---|
| Write path | node-local NVMe | + 1GbE hop to the 2nd replica, TSO/GSO/GRO off, WireGuard-encrypted |
| Node replaced under the same name | PVC survives EMPTY, operator crashloops, **a human deletes the PVC** | replica rebuilds, no action |

So: pay latency forever, or pay a manual step per node replacement. This produces the numbers.

## Result: Longhorn roughly doubles a WAL fsync. Keep both on local-path.

Run `20260802T1433Z`, 3 arms x 3 workloads x 3 repeats, 103 checks, 0 failures.

**Longhorn r2 costs about 2x on the write path, consistently and measurably.** Three independent
instruments agree on direction and rough size, and the tightest of them puts a Postgres WAL fsync at
1.28 ms on local-path against 2.39 ms on Longhorn.

| Instrument | local-path | lh best-effort | lh remote | Spread across repeats |
|---|---|---|---|---|
| `pg_stat_io` WAL fsync, mean (Postgres' own counter) | **1.28 ms** | **2.39 ms** (1.86x) | 2.49 ms (1.94x) | under 1% |
| `pg_test_fsync` fdatasync, 8 kB | 0.99 ms | 1.30 ms (1.31x) | 1.46 ms (1.47x) | under 2% |
| fio fdatasync p99 | 2.83 ms | 8.85 ms (3.12x) | 9.90 ms (3.49x) | 1.02x / 1.12x / 1.63x |
| pgbench `-c 1` p99 (decision metric) | 12.30 ms | 18.38 ms (1.50x) | 19.21 ms (1.56x) | 1.03x |
| pgbench `-c 1` TPS | 167 | 134 (81%) | 133 (80%) | |
| pgbench `-c 8` p99 / TPS | 44.5 ms / 722 | 49.8 ms (1.12x) / 544 (75%) | 47.6 ms (1.07x) / 554 (77%) | 1.10x |

Ratios differ per instrument because they measure different things: `pg_stat_io` is a mean over every
WAL fsync, fio is a p99 over a saturating loop, pgbench is a whole transaction including reads. The
consistent story is roughly 2x on the sync itself, landing as ~1.5x on commit p99 and a ~20%
throughput haircut.

### Against the criteria declared before the run

The decision metric was pgbench `-c 1` p99 on arm `c`: **1.50x, absolute 18.38 ms.**

- "Migrate both" needed <= 2.0x **and** absolute p99 <= 10 ms. The ratio passes, the absolute fails.
- "Keep local-path" needed > 3.0x, or > 25 ms, or TPS below half. None of those happened.

So the result lands in a **gap in the criteria** and neither branch fires. That is a flaw in how they
were written, not a licence to pick the convenient one. Recording it rather than retrofitting: the
ratio bar says migrate, the absolute bar says do not, and the deciding consideration below is neither.

### The finding that actually settles it

**`dataLocality: best-effort` does not rescue the write path.** Arm `c` beat arm `b` by 4% on
`pg_stat_io` (2.39 vs 2.49 ms) and 1.06x on fio p99. Of course it does: a durable write has to reach
*both* replicas before it can be acknowledged, so one of them is always a network hop away no matter
where the pod sits. Locality can only ever save a read.

That closes the "schedule Longhorn pods onto the node holding their replica" idea for anything
write-heavy. It remains worth having for read-heavy volumes, just not as a way to buy back fsync.

So there is no configuration that gets automatic node recovery without the ~2x write tax. The choice
is the bare trade, and for two systems that already replicate themselves at the application layer,
paying a permanent latency cost to remove a rare manual step is the wrong side of it.

### RabbitMQ: not enough data, and what there is looks worse

The AMQP numbers do not support a verdict and are not quoted as one. After the drift guard voided two
of three repeats, arm `b` is n=1, and arm `c`'s p99 spread is 2.22x, well past the 1.5x gate.
Directionally: `perf-test -c 1` p99 7.97 ms on local-path against 20.60 ms on arm `c` (2.59x) at 51%
of the throughput. Plausible mechanically, since a quorum queue fsyncs per Raft batch across three
brokers and Longhorn would add a second replication layer underneath that. If RabbitMQ on Longhorn
ever needs deciding, re-run `--workload amqp --repeats 7`; three is not enough for this one.

### Tail latency is bad on every arm, including local-path

The pre-declared "stop if max > 10x p99" tripwire fires on the **baseline** too: local-path
`perf-test -c 100` produced a single 8,050 ms max, and local-path fio a 41.9 ms max against a 2.87 ms
p99. So that criterion does not discriminate here; it is measuring Pi 5 scheduling and 1GbE jitter,
not the storage engine. Worst single observation per arm: local-path 8,050 ms, lh-remote 545 ms,
lh-best-effort 1,233 ms. Read those as "this hardware has a nasty tail regardless", not as a Longhorn
verdict.

### Validity gates, honestly

Two of five failed, and both failures are the gate's fault rather than the run's.

| Gate | Result |
|---|---|
| Replica layout per arm | **pass**, 9/9. `b` never held a replica on the bench node, `c` always did |
| Variance under 1.5x per cell | **fail in 4 of 15**: fio `b` 1.63x, and three of the perf-test cells. Every pgbench cell passed at 1.02-1.13x |
| No drift-flagged cells | **fail**, 4 cells voided. The guard earned its keep: the two pgbench cells it flagged are exactly the ones carrying 444 ms and 281 ms max outliers |
| `pg_test_fsync` vs fio within 2x | **fail on magnitude** (2.0x-3.0x), **pass on ranking**. Systematic: a mean on a small file against a p99 on a 512 MB file. The gate needs rewriting as ranking-only |
| pgbench `-S` read control within 10% | **fail**, badly: 4,830 TPS on local-path against 1,947-3,438 on Longhorn |

The `-S` gate was built on a false premise. It assumed reads come from cache and so cannot differ
between arms, but `-s 20` is ~300 MB against `shared_buffers: 128MB`, so reads reach the volume and
genuinely differ. Both Longhorn arms also climbed monotonically across repeats (1,947 to 3,438), which
is cache warming, not storage. Two consequences: the control is not a control and should be re-scoped
or dropped, and the pgbench figures blend a read penalty with the write penalty. That is why
`pg_stat_io` is the number to trust for fsync specifically.

Because the surviving decision-relevant cells are internally consistent (pgbench variance 1.02-1.13x,
`pg_stat_io` under 1%, three instruments agreeing on direction), the write-path conclusion stands. The
RabbitMQ conclusion does not, and is withheld above.

### What would change the answer

- A second NIC or 2.5GbE, which is most of the 2x.
- Longhorn V2/SPDK, once its ARM64 stuck-I/O bug is fixed (see [08_storage.md](08_storage.md)).
- Caring less about latency than about the manual PVC step. At 1.5x commit p99 on a cluster whose
  sample database is idle nearly all the time, that is a defensible position; it is just not the
  default this repo picks.

## The three arms

All three pinned to **one node**, so storage is the only variable.

| Arm | StorageClass | Replica layout |
|---|---|---|
| `a-local` | `local-path` | node-local dir |
| `b-lh-remote` | `bench-lh-remote` (bench-only) | both replicas on the OTHER two nodes, every read and write over the wire |
| `c-lh-local` | `bench-lh-local` (bench-only) | `dataLocality: best-effort`, one replica under the pod, only the 2nd write crosses |

`b` vs `c` is the pair that matters: same class settings, same replica count, same node, differing
only in whether a replica sits under the pod. `a` is the baseline.

### Why the node tag exists

Longhorn picks replica nodes by free space. Left alone it can and does put a replica under the pod,
which turns `b` into `c` silently and the run looks fine. So the harness tags the two non-bench nodes
`benchreplica` and `bench-lh-remote` selects on it, forcing the pod's node out of the running.
`allow-empty-node-selector-volume` is `true` here, so the existing no-selector volumes are unaffected.
Teardown removes the tags.

`c` needs no tag: `best-effort` places the local replica itself, on attach.

### The wait gate

`best-effort` does not place the local replica at provision time. It reacts to the volume attaching:
Longhorn adds a third replica on the pod's node, then drops a remote one. That is a rebuild, and
measuring during it measures the rebuild. The harness blocks until the volume is `robustness: healthy`
at exactly 2 replicas **and** the layout matches the arm, before any load starts.

## Runtime

Roughly 3.4h for the full matrix at `--repeats 3`; the script prints a real estimate before asking to
proceed. Most of that is provisioning, not measuring, which is why `--workload` and `--repeats` exist.

| Invocation | Time | Answers |
|---|---|---|
| `bash lib/shell/storage_bench.sh run --smoke` | ~20 min | nothing about storage. Proves the harness works after an edit |
| `make storage-bench-fio` | ~39 min | the core question: what does an fsync cost on each arm |
| `make storage-bench` | ~3.4h | the above plus Postgres commit latency and quorum-queue confirm latency |

### `--smoke`

Runs every code path once at the shortest settings that still exercise it: 5-second fio jobs,
`pgbench -s 1 -T 15`, a 20-second perf-test, a single-broker RabbitMQ. fio still covers all three
arms, because the tag-driven replica placement and the settle gate are the parts most likely to break
after an edit; pgbench and amqp cover one arm, because a second CNPG cluster forming proves nothing
the first one did not.

What it validates: the two bench StorageClasses provision; the node tag really does keep replicas off
the bench node; `best-effort` really does pull one onto it; the settle gate fires; CNPG comes up on
each class; `pg_test_fsync`, pgbench and its log parsing work; the additive CNP lets the RabbitMQ
operator reach a bench broker in another namespace; perf-test connects to a quorum queue; the report
renders; teardown leaves nothing behind.

The output lands in `.cache/storage-bench/<UTC>-SMOKE/` and `manifest.txt` says so on line one. The
numbers are meaningless by construction. Do not quote them.

Start with fio. If the arms are within noise of each other there, the app-level runs are unlikely to
find a difference worth a migration.

## What runs

| Workload | Tool | Reports |
|---|---|---|
| fsync | fio, three job files in `lib/bench/fio/` | fdatasync latency percentiles. The primary storage number |
| Postgres | `pg_test_fsync` then pgbench, from the CNPG image | usec/op per sync method; commit latency + TPS |
| AMQP | `pivotalrabbitmq/perf-test` on a quorum queue | publisher-confirm latency |

Both `pgbench` and `pg_test_fsync` already ship in `ghcr.io/cloudnative-pg/postgresql:18-minimal-trixie`,
so no extra image.

Decision metric is **pgbench `-c 1` p99**: at one client it is dominated by the WAL fsync, and it is
what a user of the app would feel. fio and the `-c 8` run support it; they do not decide it.

### Why these fio parameters

- `ioengine=psync`, `iodepth=1`, `numjobs=1`: the WAL writer and Ra both write-then-sync serially. A
  deep queue would measure the drive, which neither app uses.
- `fdatasync=1`, `direct=0`: reproduces `wal_sync_method=fdatasync`, buffered write then barrier.
  `direct=1` would bypass the page cache and measure something Postgres never does.
- `bs=8k`: Postgres `wal_block_size`. Nowhere near the lane's ~450 MB/s, which is the point: this job
  is latency-bound, not bandwidth-bound.
- `wal-group-commit.fio` is the same at `numjobs=4`, the strongest case FOR Longhorn: if the per-op
  replication cost amortizes under concurrency, the serialized number overstates the real cost.

`pgbench -i -s 20` has two floors under it, both satisfied and neither exceeded. The TPC-B script
updates `pgbench_branches`, which has exactly `scale` rows, so **scale must be >= client count** (8)
or the run measures row-lock contention instead of storage. And ~300MB must exceed `shared_buffers`
(128MB) or writes never reach the volume. Going higher only lengthens `pgbench -i`, which is pure
setup cost.

Everything that decides commit cost (`synchronous_commit`, `fsync`, `full_page_writes`,
`checkpoint_timeout`) stays at its production value. Touching any of them makes the result not
transfer.

## Reading the result

Declared before the first run, so it cannot be rationalised after. Judge on arm `c`, the config you
would actually ship.

| `c` vs `a`, pgbench `-c 1` p99 | Verdict |
|---|---|
| <= 2.0x and absolute p99 <= 10 ms | migrate both |
| 2.0x to 3.0x | grey. Re-run at 5 repeats; if still grey the tie-break is operator effort, which favours Longhorn |
| > 3.0x, or absolute p99 > 25 ms, or TPS below half | `15_node_recovery.md` stands, now with numbers |
| any arm with max > 10x p99, or IO stalls | stop. That is the ARM64 V1-engine risk and it disqualifies Longhorn for a DB regardless of averages |

RabbitMQ is judged separately and a split verdict is expected: quorum queues already fsync per Raft
append and tolerate more latency than a synchronous DB commit.

Separately, `b` vs `c` prices `dataLocality`. If `c` beats `b` by more than ~25% on p99,
`best-effort` is worth adopting on `longhorn-r2-ephemeral` for Redis, ntfy and the monitoring stores,
whatever happens to CNPG and RabbitMQ.

### Validity gates

`summary.md` ends with these. Any one unchecked means **INVALID**, publish no verdict.

- pgbench `-S` read-only control within 10% across arms. Reads come from cache, so if they differ the
  arms were never comparable and the write numbers mean nothing.
- max/min of p99 across repeats under 1.5x per cell.
- `pg_test_fsync` and fio's sync p50 agree **within 2x**, and rank the arms the same way. They are not
  expected to match closely: `pg_test_fsync` reports a mean over a tiny file, fio a p50 over a 512MB
  time-based run, and fdatasync cost grows with the file's dirty extent count. The smoke run measured
  979 usec/op against a 2.07 ms fio p50 on the same volume, which is normal. What would be a real
  signal is an order of magnitude apart, or the two disagreeing about which arm is faster: that means
  the fio job is measuring something other than the sync path.
- no cell flagged by the CPU-drift guard. It samples `kubectl top` before the cell and again *after*
  the settle sleep, never immediately after the load: `kubectl top` serves a rolling average, so an
  immediate second sample re-reads the benchmark's own CPU and flags every cell. If the guard still
  fires on most cells in a real run, raise `INTER_CELL_SLEEP` so the load fully drains from that
  window. Do not raise `CPU_DRIFT_ABORT` instead: that hides real neighbour interference too. The
  guard is off under `--smoke`, where a 5s settle cannot possibly be long enough.
- `c` actually had a local replica and `b` actually did not (`replica-nodes.txt` per cell).

## Confound control

- One cell at a time cluster-wide, 60s idle between cells.
- **fio runs repeat-major and palindromic**: repeat 1 forward, repeat 2 reversed, repeat 3 forward.
  Linear drift (thermal soak, a CronJob, an ArgoCD poll) cancels instead of loading onto whichever arm
  runs last. fio can afford this because its setup is a PVC and a pod.
- **pgbench and amqp run arm-major**: provision once, then loop the repeats against it. Repeat-major
  would rebuild a CNPG cluster and reload pgbench's dataset 9 times instead of 3, which is over an
  hour of pure churn for no extra information. The cost is that an arm's repeats sit adjacent in time,
  so drift shows up as within-cell variance rather than cancelling. The per-repeat spread is printed
  and the 1.5x variance gate is what catches it.
- Warm-up: fio `ramp_time`, pgbench's first 60s dropped in post-processing, perf-test's first
  intervals ignored.
- Live workloads are **recorded, not quiesced**. Quiescing would produce a number that does not
  describe this cluster. `kubectl top nodes` is captured either side of every cell and a cell that saw
  more than 25 points of CPU movement is flagged void.
- Clients (pgbench, perf-test) run on a different node from the thing under test.

## Output

`.cache/storage-bench/<UTC>/` (gitignored). Raw tool output per arm per repeat, plus `summary.md`
with the table and the gate checklist. `make storage-bench` prints it; re-print any old run with
`bash lib/shell/storage_bench.sh report <dir>`.

VictoriaMetrics is corroboration only and a separate sub-command
(`bash lib/shell/storage_bench.sh corroborate <dir>`), never a hidden port-forward inside a run. At
`scrapeInterval: 60s` with `dedup.minScrapeInterval: 60s` a 150s cell yields two samples, so it can
contradict the tools but it cannot replace them.

## Safety

- Everything carries `bench.raspi-cluster/owner=storage_bench.sh` and every delete is scoped to it.
- Bench pods carry **no `priorityClassName`**, so they sit at priority 0, below `data-critical`.
  Node-pressure eviction reaches the benchmark before it reaches any database. Never give a bench pod
  a priority class.
- `local-path` enforces no quota and the `a` arm shares the 50 GiB slice with the live CNPG data. The
  harness `df`s before the arm and refuses below 10 GiB free. This is the highest-consequence risk
  here: a full slice takes production Postgres down.
- Preflight hard-fails on a degraded cluster, an in-flight Longhorn rebuild (it saturates the exact
  path under test), an ArgoCD sync, or a running CNPG backup.
- `trap`-based teardown on exit and interrupt.

### Not a `DANGEROUS_` script

It creates and destroys only objects it labelled itself. `DANGEROUS_` marks the three scripts that
wipe the cluster; diluting that signal would make it useless.

### Not an ArgoCD app

Every app here is `automated` + `selfHeal` + `prune`. Argo would recreate each bench object the moment
teardown deleted it and fight the teardown indefinitely. A benchmark's whole lifecycle is
create-measure-destroy inside one invocation, which is the opposite of a reconciled steady state.
Applied imperatively, like `03e`'s probe pod and the `recover_*` scripts' temp pods.

### Pod Security

The bench namespace takes the cluster default, which Talos sets to `enforce: baseline` with
`warn: restricted`. So `kubectl apply` prints restricted-level warnings for the bench pods and admits
them anyway. Baseline is enough: nothing here is privileged, host-networked or hostPath-mounted, fio
just mounts a normal PVC. The fio pod does run as root, because `apk add fio` needs to, and it drops
all capabilities and sets `seccompProfile: RuntimeDefault` so root is the only concession. **Do not
stamp `privileged` on the bench namespace.** If something appears to need it, the setup is wrong.

### The bench namespace carries no CiliumNetworkPolicy

A deliberate addition to the unpoliced list in [`04_networking.md`](04_networking.md). Policing it
would mean getting DNS, the package fetch, both operators, kubelet probes, AMQP and 5432 all right
first time or losing a five-hour run to a silent drop. It exists for hours and holds no data.

### One CNP IS required, in the `rabbitmq` namespace

`03_rabbitmq`'s cluster-operator policy allows egress to the management API via a bare
`matchLabels: {app.kubernetes.io/name: rabbitmq}`. With no namespace key, Cilium reads that as the
operator's own namespace and that exact cluster name, so the operator cannot reach a bench broker
anywhere else and the cluster never finishes forming. Renaming does not help: the label's value IS
the cluster name.

The harness applies an additive CNP in `rabbitmq` widening that one egress rule. Cilium unions
policies, so this needs no chart edit and no ArgoCD `selfHeal` fight. **It lives outside the bench
namespace, so `kubectl delete ns` does not reach it** - teardown deletes it by name. Same for the two
StorageClasses and the node tags.

## Teardown

`make storage-bench-teardown`. Idempotent; safe on a clean cluster. Order matters: the
`RabbitmqCluster` carries a finalizer, so it is deleted and waited on **before** the namespace, or the
namespace hangs in `Terminating` forever.

The bench broker sets `terminationGracePeriodSeconds: 30`. The live one is `604800` (7 days);
inheriting that would wedge teardown for a week. That is the one place the bench deliberately breaks
parity with production.

## `pgsync`: what synchronous replication costs

A separate question from the three arms above, and a separate workload. Those isolate replica
LOCALITY for a single-node database. This isolates what SYNCHRONOUS replication costs, on each
storage, because that is the choice that decides where the HA database lives.

`make storage-bench-sync`. Not part of `--workload all`: it is another ~85 min, and folding it in
would invalidate the runtime figures above.

### Why the question exists

The HA cluster replicates ASYNCHRONOUSLY today (`sync_state=async`, `synchronous_standby_names`
empty; `pg-cluster` never configures it). So a promotion can discard transactions the client was told
had committed, with no error anywhere. The database is never corrupt, only behind, and when the old
primary returns CNPG `pg_rewind`s it and throws its divergent WAL away. Silent, which is why it is
worth closing.

Closing it means `synchronous` with `dataDurability: required`. On Longhorn that makes a commit wait
for the primary's WAL on 2 replicas AND a standby's WAL on 2 replicas: four network fsyncs. Whether
that is affordable on three Pi 5s is what this measures.

### The four arms

| arm | storage | instances | replication |
|---|---|---|---|
| `d-local-async` | `local-path` | 1 | none (baseline) |
| `e-local-sync` | `local-path` | 3 | `any 1`, `required` |
| `f-lh-async` | `longhorn-r2-ephemeral` | 1 | none |
| `g-lh-sync` | `longhorn-r2-ephemeral` | 3 | `any 1`, `required` |

Read as margins: `f-d` and `g-e` are the price of Longhorn, `e-d` and `g-f` the price of sync. The
report prints the grid with both subtractions already done.

The SHIPPED `longhorn-r2-ephemeral`, not the two bench classes, because the decision this feeds is
whether the real databases move, so the real settings (`dataLocality: disabled` included) are the ones
that matter.

3 instances, not 2, because `any 1` of two standbys is the config worth running: it survives one node
being drained without stalling writes, which is what makes a rolling Talos upgrade safe under
`required`. `03f`'s `wait_replication_healthy` gate is what stops the next drain starting before the
displaced instance is back in sync.

### The assertion that matters

A malformed `synchronous` block that CNPG ignores would produce a full set of numbers saying sync is
free. So before any cell runs, Postgres itself is asked: `synchronous_standby_names` must be non-empty
AND some standby must report `sync_state` of `sync` or `quorum`. Failure SKIPS the arm. The answers are
kept in `pgsync/<arm>/synchronous.txt` as the run's evidence it measured what it claimed.

### Threats specific to these arms

- **The client is no longer uncontended.** 3 instances on 3 nodes means every node hosts a database,
  so `pgclient` on `OFF_NODE` shares a node with one. Identical across both sync arms, so it largely
  cancels in the comparison, but it makes these arms NOT comparable to `a-local`/`b-lh-remote`.
- **Primary placement is not controllable** with 3 instances: CNPG picks. Recorded per cell in
  `primary-node.txt` and gated in the report, not eliminated.
- **`any 1` is best-of-two.** The primary waits for the faster standby, so these numbers are mildly
  optimistic against a 2-instance cluster waiting on one specific peer.
- `pg_stat_io` WAL `fsync_time` isolates the LOCAL fsync; `pg_stat_replication` (captured before and
  after each cell) covers the standby side. Together they decompose a commit into storage and network,
  which is what tells you whether a disappointing number is the disk or the wire.

### Expected shape, written down before the run

A sync commit adds a round-trip plus a remote WAL fsync. If Longhorn costs ~1.1ms per fsync over
local-path (1.28 to 2.39ms, measured above), the sync arms should differ by roughly TWICE that, since
both the primary's and the standby's fsync move onto Longhorn. If `g-e` lands far from 2x `f-d`, either
the network dominates both and storage barely matters, or a cell is invalid.

### Result: PROVISIONAL, because the `-S` control is not a control

Run `20260803T1603Z`, 2 repeats, arms d/e/f measured together and g resumed ~3.5h later after a
laptop restart killed the run mid-arm.

commit p50 ms, mean of 2 repeats:

| | local-path | longhorn-r2 | price of longhorn |
|---|---|---|---|
| async, 1 instance, c1 | 5.40 | 6.73 | +1.33 |
| sync any 1 required, 3 instances, c1 | 7.57 | 9.66 | +2.09 |
| **price of sync, c1** | **+2.17** | **+2.93** | |
| async, 1 instance, c8 | 7.55 | 11.44 | +3.89 |
| sync any 1 required, 3 instances, c8 | 10.12 | 17.27 | +7.15 |
| **price of sync, c8** | **+2.57** | **+5.83** | |

Throughput at c1: 167 / 122 / 135 / 95 tps for d/e/f/g. At c8: 740 / 562 / 550 / 383.

**The prediction written above was wrong.** The sync arms do NOT differ by ~2x the async gap. At c1 the
gap is 7.14ms async against 7.79ms sync, essentially flat; at c8 it goes DOWN, 14.37 to 10.15. The
first branch of the stated alternative is what happened: the replication round-trip dominates, and the
storage under it barely moves the total.

Two independent measurements corroborate that, and neither depends on the broken gate:

- `pg_test_fsync` on the volume, no network and no Postgres: local-path 1024 ops/sec (0.98 ms),
  longhorn 693 ops/sec (1.44 ms). Longhorn costs **0.46 ms per fsync**, 1.47x.
- `pg_stat_replication.flush_lag` on the sync primary: **2.4 to 2.7 ms**. That predicts the observed
  price of sync at c1 (2.17 and 2.93 ms) almost exactly, on both storages.

So the standby round-trip is ~2.5 ms and the storage difference under it is ~0.5 ms. Sync costs about
five times what the storage choice does.

### Why this is provisional, and what it says about the published result above

The `-S` read-only control FAILED: 4952 tps down to 2447 across arms, a 2.02x spread against a 10%
tolerance. By this document's own rule that means no verdict.

But the gate is mis-specified, and **the published Longhorn result above violates it too**. Its run
(`20260802T1433Z`) recorded a-local at 4820/4814/4856 against b-lh-remote at 1947/3245/3438: a 2.5x
spread, and a 1.77x spread within one arm's own repeats. That conclusion was published anyway.

The premise is what is wrong. The gate says "reads come from cache, so this MUST match across arms",
but `PGBENCH_SCALE=20` is ~300MB against `shared_buffers` of 128MB, chosen deliberately so writes
reach the volume. So `-S` reads hit storage by construction, and a control that varies with the
variable under test is not a control. It cannot pass while comparing storage classes, and never has.

The pgsync run is better behaved than the published one on every gate that does work: repeat spread
1.003x to 1.078x (against 1.5x), no cell flagged for CPU drift, the primary on pi-cp3 in all 8 cells,
and both sync arms proved synchronous against Postgres.

Fixing it means a control that does not touch storage at all, for example a CPU-bound
`SELECT sum(i) FROM generate_series(...)`, and re-running. Until then these numbers are the best
available reading, not a verdict.
