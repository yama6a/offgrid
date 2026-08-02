# Percentiles from pgbench --log files. pgbench prints only a mean, so the per-transaction log is the
# only place p99 exists. Usage: awk -v warmup=60 -f pctl.awk run.log.*
#
# pgbench log line: client_id transaction_no time script_no time_epoch time_us
# $3 is the transaction latency in microseconds, $5 the commit epoch in seconds.
#
# Emits one line of shell-eval-able KEY=value, latencies in ms:
#   n=23901 p50=4.312 p95=9.880 p99=18.441 max=132.006 tps=199.18 window=120

function qsort(a, lo, hi,   i, j, p, t) {
  if (lo >= hi) return
  p = a[int((lo + hi) / 2)]; i = lo; j = hi
  while (i <= j) {
    while (a[i] < p) i++
    while (a[j] > p) j--
    if (i <= j) { t = a[i]; a[i] = a[j]; a[j] = t; i++; j-- }
  }
  qsort(a, lo, j); qsort(a, i, hi)
}

# Nearest-rank on a 1-indexed sorted array, which is what fio and perf-test report too.
function pct(a, n, p,   r) {
  r = int(p * n + 0.999999)
  if (r < 1) r = 1
  if (r > n) r = n
  return a[r]
}

BEGIN { if (warmup == "") warmup = 60 }

NF >= 5 && $3 ~ /^[0-9]+$/ {
  lat[++raw] = $3 + 0
  ep[raw] = $5 + 0
  if (first == 0 || $5 + 0 < first) first = $5 + 0
  if ($5 + 0 > last) last = $5 + 0
}

END {
  if (raw == 0) { print "n=0"; exit 1 }
  cut = first + warmup
  for (i = 1; i <= raw; i++) if (ep[i] >= cut) s[++n] = lat[i]
  if (n == 0) { printf "n=0 note=all-%ds-samples-inside-warmup\n", last - first; exit 1 }

  qsort(s, 1, n)
  window = last - cut
  if (window <= 0) window = 1

  printf "n=%d p50=%.3f p95=%.3f p99=%.3f max=%.3f tps=%.2f window=%d\n",
    n, pct(s, n, 0.50) / 1000, pct(s, n, 0.95) / 1000, pct(s, n, 0.99) / 1000,
    s[n] / 1000, n / window, window
}
