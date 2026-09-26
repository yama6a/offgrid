# Runbook: storage benchmark

Why the benchmark exists and what it found: [../12_storage_bench.md](../12_storage_bench.md).

## Run it

1. Check that the cluster is quiet. The preflight fails hard on any of these:
   - a degraded node or volume
   - a Longhorn rebuild
   - an Argo CD sync
   - a CNPG backup
2. Pick a run:

   ```bash
   make storage-bench          # 2 locality arms x 3 workloads, about 2.3h
   make storage-bench-fio      # fsync only, about 26 min, the shortest real answer
   make storage-bench-sync     # what synchronous replication costs, about 45 min
   ```

   To test the script itself, use `--smoke`. Its numbers mean nothing, and its output directory ends in `-SMOKE`.

   ```bash
   bash lib/shell/storage_bench.sh run --smoke
   ```

3. If a run stops, continue it:

   ```bash
   bash lib/shell/storage_bench.sh run --resume <dir>
   ```

## Read the result

1. Open `.cache/storage-bench/<UTC>/summary.md`. It holds the tables and the validity gates.
2. Check every gate. If one is unchecked, the run is invalid. Publish no verdict.
3. If the CPU drift check voids most cells, raise `INTER_CELL_SLEEP` in the script. Never raise
   `CPU_DRIFT_ABORT`, because that hides real load from other pods.
4. To build the summary again from the raw output:

   ```bash
   bash lib/shell/storage_bench.sh report <dir>
   ```

5. To compare against VictoriaMetrics, run this after the run, never during it:

   ```bash
   bash lib/shell/storage_bench.sh corroborate <dir>
   ```

## Tear down

The script tears down on exit and on interrupt. If a run died hard, tear down by hand. It is idempotent and safe
on a clean cluster.

```bash
make storage-bench-teardown
```

It removes the bench namespace, the two bench StorageClasses, the Longhorn node tags and the extra operator CNP
in the `rabbitmq` namespace.
