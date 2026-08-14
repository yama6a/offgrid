#!/usr/bin/env bash
# Measures what a Longhorn replica being local or remote costs CNPG and RabbitMQ in write latency,
# which is the choice between the two shipped -ephemeral classes. See docs/12_storage_bench.md.
set -uo pipefail

# ---- knobs ----
BENCH_NS="storage-bench"
BENCH_SC_REMOTE="bench-lh-remote"            # dataLocality disabled + replicas pinned OFF the bench node
BENCH_SC_LOCAL="bench-lh-local"              # dataLocality best-effort, one replica follows the pod
REPLICA_TAG="benchreplica"                   # Longhorn node tag; teardown removes it from every node
OWNER_LABEL="bench.raspi-cluster/owner=storage_bench.sh"
RABBIT_NS="rabbitmq"                          # where the live cluster operator lives (needs an egress grant)
EGRESS_CNP="bench-mq-operator-egress"         # additive CNP in $RABBIT_NS; teardown deletes it BY NAME
REPEATS=3
PGBENCH_SCALE=20          # ~300MB: >= PGBENCH_CLIENTS (else pgbench_branches row-lock contention masks
                          # storage) and > shared_buffers (else writes never reach the volume). Both
                          # constraints are satisfied well before 50, and init cost scales with it.
PGBENCH_SECONDS=180       # first PGBENCH_WARMUP dropped in post-processing, no separate warm-up run
PGBENCH_WARMUP=60
PGBENCH_CLIENTS=8
PERFTEST_SECONDS=150
INTER_CELL_SLEEP=60       # NVMe on cp3 idles at 50C; let it settle between cells
PVC_SIZE="8Gi"            # per CNPG arm; 2x this across the two replicas
MQ_PVC_SIZE="4Gi"
CPU_DRIFT_ABORT=25        # percentage points of node CPU movement across a cell that voids it
MIN_FREE_MEM_MI=700       # per node, before the bench adds ~1.5Gi cluster-wide
MIN_FREE_LONGHORN_GI=50

# renovate: datasource=docker
FIO_IMAGE="alpine:3.24"                       # no maintained multi-arch fio image exists; apk add instead
# renovate: datasource=docker
PERFTEST_IMAGE="pivotalrabbitmq/perf-test:2.25.0"   # 2.25.0 is the first line with linux/arm64 manifests
MQ_IMAGE="rabbitmq:4.3.4-management-alpine"   # matches the live broker (03_rabbitmq values)
MQ_REPLICAS=3             # a quorum queue needs a quorum; 1 broker measures nothing about Raft
PG_MAJOR="18"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

BENCH_LIB="${REPO_ROOT}/lib/bench"
PG_IMAGE="$(yq -r ".\"${PG_MAJOR}\"" "${REPO_ROOT}/lib/helm/pg-cluster/files/postgres-images.yaml")"

# The arms. Fields: id|storageClass|human label. IDs are lowercase because they become Kubernetes
# object names, which are RFC1123.
# The pair the whole exercise turns on: same node, same class settings, same replica count, differing
# only in whether one replica sits under the pod or both are a network hop away. That is exactly the
# choice between longhorn-r2-ephemeral and longhorn-r2-ephemeral-local.
ARMS=(
  "b-lh-remote|${BENCH_SC_REMOTE}|longhorn r2, BOTH replicas remote, every read and write over the wire"
  "c-lh-local|${BENCH_SC_LOCAL}|longhorn r2 best-effort, one replica local, only the 2nd write crosses"
)

# The `pgsync` workload's own arms. Answers a different question from ARMS above, which is why it does
# not share them: ARMS isolates replica LOCALITY for a single-instance DB, this isolates what
# SYNCHRONOUS replication costs, i.e. what highAvailability: true buys and charges.
# Fields: id|storageClass|instances|sync|label
#
# Uses the SHIPPED class, not the two bench ones, because this feeds a decision about the real
# databases, so the real class settings (dataLocality disabled included) are the ones that matter.
# 3 instances because `any 1` of two standbys is the config worth running: it survives one node being
# drained without stalling writes, which is what makes a rolling Talos upgrade safe.
SYNC_ARMS=(
  "f-lh-async|longhorn-r2-ephemeral|1|off|longhorn r2, single instance, no replication"
  "g-lh-sync|longhorn-r2-ephemeral|3|on|longhorn r2, 3 instances, synchronous any 1 required"
)

WORKLOADS="all"
RUN_DIR=""
BENCH_NODE=""
OFF_NODE=""
SMOKE=false
RESUME_DIR=""
FIO_JOBS=(wal-fsync wal-group-commit seq-throughput)

# --smoke: prove the plumbing, not the storage. Every code path runs once at the shortest settings
# that still exercise it. fio still covers all three arms, because the tag-driven replica placement
# and the settle gate are the parts most likely to be wrong; pgbench and amqp cover one arm only,
# because a second CNPG cluster forming proves nothing a first one did not.
apply_smoke_knobs() {
  REPEATS=1
  FIO_JOBS=(smoke)
  PGBENCH_SCALE=1
  PGBENCH_CLIENTS=1        # scale must stay >= clients
  PGBENCH_SECONDS=15
  PGBENCH_WARMUP=5
  PERFTEST_SECONDS=20
  MQ_REPLICAS=1            # a 3-broker quorum takes minutes to form and proves nothing extra here
  INTER_CELL_SLEEP=5
  CPU_DRIFT_ABORT=100      # off: 5s is far short of metrics-server's window, so the guard would only
                           # ever re-read the smoke load itself and warn on every cell
  PVC_SIZE="2Gi"
  MQ_PVC_SIZE="1Gi"
}

usage() {
  cat <<EOF
usage: storage_bench.sh [run] [--workload fio|pgbench|amqp|pgsync|all] [--repeats N] [--smoke]
                              [--resume <run-dir>]
       storage_bench.sh teardown
       storage_bench.sh report <run-dir>
       storage_bench.sh corroborate <run-dir>

  --smoke   exercise every code path once at minimum runtime and throw the numbers away.
            Use this after editing the script, NOT to answer anything about storage.

  --resume  reuse an existing run dir and skip the arms that already finished, for picking a long
            run back up after it was interrupted. The cells then span two points in time, so check
            the pgbench -S control before trusting a comparison across them.

  pgsync    what SYNCHRONOUS replication costs, i.e. the price of highAvailability: true. NOT part of
            `all`: another ~45 min, and a different question from the replica-locality one the other
            workloads share. See docs/12_storage_bench.md.
EOF
  exit 1
}

# ---- helpers ----

kb()  { kubectl -n "$BENCH_NS" "$@"; }
lh()  { kubectl -n longhorn-system "$@"; }

# Every delete in this script is scoped to $OWNER_LABEL. Nothing without it is ever touched.
labelled() { printf 'bench.raspi-cluster/owner: storage_bench.sh'; }

node_cpu_pct() {
  kubectl top node "$1" --no-headers 2>/dev/null | awk '{gsub(/%/,"",$3); print $3+0}'
}

node_free_mem_mi() {
  local n="$1" alloc used
  alloc="$(kubectl get node "$n" -o jsonpath='{.status.allocatable.memory}' | sed 's/Ki$//')"
  used="$(kubectl top node "$n" --no-headers 2>/dev/null | awk '{gsub(/Mi/,"",$4); print $4+0}')"
  echo $(( alloc / 1024 - used ))
}

# Longhorn nodes holding a replica of a bound PVC, one per line.
replica_nodes() {
  local pvc="$1" vol
  vol="$(kb get pvc "$pvc" -o jsonpath='{.spec.volumeName}' 2>/dev/null)"
  [ -n "$vol" ] || return 1
  lh get replicas.longhorn.io -l "longhornvolume=${vol}" \
    -o jsonpath='{range .items[*]}{.spec.nodeID}{"\n"}{end}' | sort -u | grep -v '^$'
}

# Pull one KEY=value out of a pctl.awk line, without eval'ing file content.
kv() { awk -v k="$1" '{for(i=1;i<=NF;i++){split($i,a,"="); if(a[1]==k){print a[2]; exit}}}' <<< "$2"; }

# Retry an IDEMPOTENT `kb exec ...`, writing stdout to a file. `kubectl exec` streams through the
# apiserver, and a reset on that connection ("next reader: read tcp ...: connection reset by peer")
# truncates the output with no fault in the thing being measured. A run is an hour of these, so the
# read-only probes retry rather than costing a validity gate. NOT for the pgbench runs themselves: a
# half-written transaction log has to stay a visible failure, not be silently replaced.
kb_exec_retry() {
  local what="$1" dest="$2" tries="${3:-3}"; shift 3
  local i
  for i in $(seq 1 "$tries"); do
    if kb exec "$@" > "$dest" 2>&1 && ! grep -q 'error reading from error stream\|connection reset by peer' "$dest"; then
      ok "${what}"; return 0
    fi
    sleep 5
  done
  bad "${what} (${tries} attempts, last: $(tail -1 "$dest" | cut -c1-80))"
  return 1
}

# Mean p99 for one pgsync arm and pgbench run, across the repeats. Empty if the arm never produced a
# cell, which is what a skipped (non-synchronous) arm looks like.
mean_p99() {
  local dir="$1" arm="$2" run="$3" f v t=0 n=0
  for f in "${dir}"/pgsync/"${arm}"/r*/"${run}".pctl; do
    [ -f "$f" ] || continue
    v="$(kv p99 "$(cat "$f")")"
    case "$v" in ''|*[!0-9.]*) continue ;; esac
    t="$(awk -v a="$t" -v b="$v" 'BEGIN{printf "%.4f", a+b}')"; n=$((n + 1))
  done
  [ "$n" -gt 0 ] && awk -v t="$t" -v n="$n" 'BEGIN{printf "%.2f", t/n}'
}

# "b-a (x.yx)". Both empty-safe, because a skipped arm must read as a gap rather than as zero cost.
delta() {
  { [ -n "$1" ] && [ -n "$2" ]; } || { printf 'n/a'; return; }
  awk -v a="$1" -v b="$2" 'BEGIN{ printf "+%.2f (%.2fx)", b-a, (a>0 ? b/a : 0) }'
}

# What the run exists to produce, with the subtraction done: the price of synchronous replication.
# p99 in ms, meaned over the repeats.
pgsync_grid() {
  local dir="$1" run fa ga
  compgen -G "${dir}/pgsync/*" >/dev/null 2>&1 || return 0
  for run in c1 c8; do
    fa="$(mean_p99 "$dir" f-lh-async "$run")"; ga="$(mean_p99 "$dir" g-lh-sync "$run")"
    printf '\n#### pgsync %s, commit p99 ms (mean of %s repeats)\n\n' "$run" "$REPEATS"
    printf '| async (1 instance) | sync any 1 required (3 instances) | price of sync |\n|---|---|---|\n'
    printf '| %s | %s | %s |\n' "${fa:-n/a}" "${ga:-n/a}" "$(delta "$fa" "$ga")"
  done
}

pg_conn() {
  local pw; pw="$(kb get secret "pg-${1}-app" -o jsonpath='{.data.password}' | base64 -d)"
  printf 'postgresql://app:%s@pg-%s-rw.%s.svc:5432/app' "$pw" "$1" "$BENCH_NS"
}

# Predicates for wait_for. Functions rather than `bash -c` strings: the jsonpath filters carry nested
# quotes that do not survive a round trip through a shell string.
pvc_bound()   { [ "$(kb get pvc "$1" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Bound" ]; }
pg_healthy()  { [ "$(kb get cluster.postgresql.cnpg.io "$1" -o jsonpath='{.status.phase}' 2>/dev/null)" \
                  = "Cluster in healthy state" ]; }
# Which pod is primary, and on which node. Never assume `-1`: with several instances CNPG picks, and
# after any switchover the answer changes.
pg_primary()      { kb get cluster.postgresql.cnpg.io "$1" -o jsonpath='{.status.currentPrimary}' 2>/dev/null; }
pg_primary_node() { kb get pod "$(pg_primary "$1")" -o jsonpath='{.spec.nodeName}' 2>/dev/null; }
mq_ready()    { [ "$(kb get rabbitmqcluster "$1" \
                  -o jsonpath='{.status.conditions[?(@.type=="AllReplicasReady")].status}' 2>/dev/null)" = "True" ]; }
pod_done()    { case "$(kb get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null)" in
                  Succeeded|Failed) return 0 ;; *) return 1 ;; esac; }

wait_for() {
  local what="$1" secs="$2"; shift 2
  local i
  for ((i = 0; i < secs; i++)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  bad "timed out after ${secs}s waiting for ${what}"
  return 1
}

# Longhorn volume is healthy at exactly numberOfReplicas AND (for arm C) one replica sits on the
# bench node. best-effort adds the local replica on ATTACH and drops a remote one, which is a
# rebuild; measuring during it measures the rebuild.
volume_settled() {
  local pvc="$1" want_local="$2" vol rob cnt
  vol="$(kb get pvc "$pvc" -o jsonpath='{.spec.volumeName}' 2>/dev/null)" || return 1
  [ -n "$vol" ] || return 1
  rob="$(lh get volumes.longhorn.io "$vol" -o jsonpath='{.status.robustness}' 2>/dev/null)"
  [ "$rob" = "healthy" ] || return 1
  cnt="$(replica_nodes "$pvc" | wc -l | tr -d ' ')"
  [ "$cnt" = "2" ] || return 1
  case "$want_local" in
    yes) replica_nodes "$pvc" | grep -qx "$BENCH_NODE" ;;
    no)  ! replica_nodes "$pvc" | grep -qx "$BENCH_NODE" ;;
    *)   return 0 ;;
  esac
}

# ---- preflight ----

preflight() {
  say "preflight"
  local n mem fails=0
  local nodes; nodes="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"

  while read -r n; do
    [ -n "$n" ] || continue
    if [ "$(kubectl get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = "True" ]; then
      ok "node ${n} Ready"
    else
      bad "node ${n} NOT Ready"; fails=1
    fi
    mem="$(node_free_mem_mi "$n")"
    if [ "$mem" -ge "$MIN_FREE_MEM_MI" ]; then
      ok "node ${n} has ${mem}Mi free (need ${MIN_FREE_MEM_MI}Mi)"
    else
      bad "node ${n} has only ${mem}Mi free, the bench would risk evicting a live pod"; fails=1
    fi
  done <<< "$nodes"

  # 3 schedulable Longhorn disks is not cosmetic: with only 2, hard replica anti-affinity forces every
  # pair onto the same two nodes and arms B and C silently become the same measurement.
  local sched
  sched="$(lh get nodes.longhorn.io -o json | python3 -c '
import json,sys
n=0
for i in json.load(sys.stdin)["items"]:
    for d in i["status"]["diskStatus"].values():
        c={x["type"]:x["status"] for x in d["conditions"]}
        if c.get("Ready")=="True" and c.get("Schedulable")=="True": n+=1
print(n)')"
  if [ "$sched" = "3" ]; then
    ok "3 Longhorn disks Ready+Schedulable"
  else
    bad "only ${sched}/3 Longhorn disks schedulable; arms B and C collapse into each other, fix first"; fails=1
  fi

  local lhfree
  lhfree="$(lh get nodes.longhorn.io -o json | python3 -c '
import json,sys
print(min((d["storageAvailable"]//2**30) for i in json.load(sys.stdin)["items"] for d in i["status"]["diskStatus"].values()))')"
  [ "$lhfree" -ge "$MIN_FREE_LONGHORN_GI" ] \
    && ok "Longhorn min free ${lhfree}Gi" || { bad "Longhorn min free ${lhfree}Gi"; fails=1; }

  # A rebuild in flight saturates the exact replication path under test.
  local degraded
  degraded="$(lh get volumes.longhorn.io -o json \
    | python3 -c 'import json,sys; print(" ".join(v["metadata"]["name"] for v in json.load(sys.stdin)["items"] if v["status"]["state"]=="attached" and v["status"]["robustness"]!="healthy"))')"
  [ -z "$degraded" ] && ok "no attached Longhorn volume is rebuilding" \
    || { bad "rebuilding/degraded volumes: ${degraded}"; fails=1; }

  local unhealthy
  unhealthy="$(kubectl get cluster.postgresql.cnpg.io -A -o json \
    | python3 -c 'import json,sys; print(" ".join(c["metadata"]["name"] for c in json.load(sys.stdin)["items"] if c.get("status",{}).get("phase")!="Cluster in healthy state"))')"
  [ -z "$unhealthy" ] && ok "every live CNPG cluster healthy" \
    || { bad "unhealthy CNPG: ${unhealthy}"; fails=1; }

  [ "$(kubectl -n "$RABBIT_NS" get rabbitmqcluster rabbitmq -o jsonpath='{.status.conditions[?(@.type=="AllReplicasReady")].status}')" = "True" ] \
    && ok "live RabbitMQ AllReplicasReady" || { bad "live RabbitMQ not AllReplicasReady"; fails=1; }

  local syncing
  syncing="$(kubectl -n argocd get applications.argoproj.io -o json 2>/dev/null \
    | python3 -c 'import json,sys; print(" ".join(a["metadata"]["name"] for a in json.load(sys.stdin)["items"] if (a.get("status",{}).get("operationState") or {}).get("phase")=="Running"))')"
  [ -z "$syncing" ] && ok "no ArgoCD sync in flight" || { bad "ArgoCD syncing: ${syncing}"; fails=1; }

  local running_bk
  running_bk="$(kubectl get backup.postgresql.cnpg.io -A -o json 2>/dev/null \
    | python3 -c 'import json,sys; print(" ".join(b["metadata"]["name"] for b in json.load(sys.stdin)["items"] if b.get("status",{}).get("phase")=="running"))')"
  [ -z "$running_bk" ] && ok "no CNPG backup running" || { bad "backup running: ${running_bk}"; fails=1; }

  if kubectl get ns "$BENCH_NS" >/dev/null 2>&1; then
    bad "namespace ${BENCH_NS} already exists; run 'make storage-bench-teardown' first"; fails=1
  else
    ok "namespace ${BENCH_NS} is free"
  fi

  [ "$fails" -eq 0 ] || die "preflight failed, see above. Nothing was created."
}

# ---- setup / teardown ----

setup_ns() {
  kubectl create ns "$BENCH_NS" >/dev/null 2>&1
  kubectl label ns "$BENCH_NS" "$OWNER_LABEL" --overwrite >/dev/null
}

# Both bench classes copy longhorn-r2-ephemeral exactly. They differ only in where the two replicas
# may live relative to the pod, which is the comparison the whole benchmark exists to make.
#
# The tag is what makes arm b honest. Without it Longhorn picks any 2 of the 3 nodes by free space,
# so it can and does put a replica under the pod, and "both replicas remote" silently becomes "one
# replica local" - the exact thing arm c measures. Tagging the two non-bench nodes and selecting on
# it forces the pod's node out of the running. allow-empty-node-selector-volume is true here, so the
# existing no-selector volumes are unaffected by the tag.
setup_classes() {
  say "creating the two bench StorageClasses and tagging replica nodes"

  local n
  for n in $(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {end}'); do
    [ "$n" = "$BENCH_NODE" ] && continue
    lh patch nodes.longhorn.io "$n" --type=merge -p "{\"spec\":{\"tags\":[\"${REPLICA_TAG}\"]}}" >/dev/null \
      && ok "tagged ${n} ${REPLICA_TAG}" || bad "could not tag ${n}"
  done

  kubectl apply -f - >/dev/null <<YAML
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${BENCH_SC_REMOTE}
  labels: { $(labelled) }
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "30"
  fsType: "ext4"
  dataLocality: "disabled"
  nodeSelector: "${REPLICA_TAG}"
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${BENCH_SC_LOCAL}
  labels: { $(labelled) }
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "30"
  fsType: "ext4"
  dataLocality: "best-effort"
YAML
  ok "${BENCH_SC_REMOTE} (replicas off ${BENCH_NODE}) and ${BENCH_SC_LOCAL} (one replica on it) created"
}

setup_support() {
  # The live operator's 15672 egress rule is a bare matchLabels with no namespace key, which in Cilium
  # means its own namespace only, so it cannot reach a bench broker anywhere else and the cluster never
  # finishes forming. Cilium unions policies, so this widens that egress without editing the chart.
  kubectl apply -f - >/dev/null <<YAML
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: ${EGRESS_CNP}
  namespace: ${RABBIT_NS}
  labels: { $(labelled) }
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/component: rabbitmq-operator
      app.kubernetes.io/part-of: rabbitmq
  egress:
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: bench-mq
          matchExpressions:
            - { key: k8s:io.kubernetes.pod.namespace, operator: Exists }
      toPorts:
        - ports:
            - { port: "15672", protocol: TCP }
YAML

  kb create configmap bench-fio --from-file="${BENCH_LIB}/fio/" >/dev/null 2>&1
  kb label configmap bench-fio "$OWNER_LABEL" --overwrite >/dev/null
  ok "${EGRESS_CNP} in ${RABBIT_NS} and the fio job ConfigMap created"
}

teardown() {
  say "teardown"
  # The RabbitmqCluster carries a finalizer; deleting the namespace first wedges it in Terminating.
  if kb get rabbitmqcluster bench-mq >/dev/null 2>&1; then
    kb delete rabbitmqcluster bench-mq --wait=true --timeout=180s >/dev/null 2>&1 \
      && ok "bench-mq deleted" \
      || bad "bench-mq stuck; clear it with: kubectl -n ${BENCH_NS} patch rabbitmqcluster bench-mq --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
  fi
  kb delete cluster.postgresql.cnpg.io --all --wait=true --timeout=180s >/dev/null 2>&1
  kb delete pvc --all --wait=true --timeout=180s >/dev/null 2>&1

  if kubectl get ns "$BENCH_NS" >/dev/null 2>&1; then
    kubectl delete ns "$BENCH_NS" --wait=true --timeout=300s >/dev/null 2>&1 \
      && ok "namespace ${BENCH_NS} deleted" || bad "namespace ${BENCH_NS} did not delete"
  else
    ok "namespace ${BENCH_NS} absent"
  fi

  # These three live outside the namespace, so `delete ns` does not reach them.
  kubectl delete storageclass "$BENCH_SC_REMOTE" "$BENCH_SC_LOCAL" --ignore-not-found >/dev/null 2>&1 \
    && ok "bench StorageClasses gone"
  kubectl -n "$RABBIT_NS" delete ciliumnetworkpolicy "$EGRESS_CNP" --ignore-not-found >/dev/null 2>&1 \
    && ok "${EGRESS_CNP} in ${RABBIT_NS} gone"

  local n tags
  for n in $(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {end}'); do
    tags="$(lh get nodes.longhorn.io "$n" -o jsonpath='{.spec.tags}' 2>/dev/null)"
    case "$tags" in *"$REPLICA_TAG"*)
      lh patch nodes.longhorn.io "$n" --type=merge -p '{"spec":{"tags":[]}}' >/dev/null 2>&1 \
        && ok "untagged ${n}" || bad "could not untag ${n}, remove ${REPLICA_TAG} by hand" ;;
    esac
  done

  local orphans
  orphans="$(lh get volumes.longhorn.io -o json \
    | python3 -c 'import json,sys; print(" ".join(v["metadata"]["name"] for v in json.load(sys.stdin)["items"] if (v["status"].get("kubernetesStatus") or {}).get("namespace")=="'"$BENCH_NS"'"))' 2>/dev/null)"
  [ -z "$orphans" ] && ok "no orphaned Longhorn volumes" || bad "orphaned Longhorn volumes: ${orphans}"
}

# ---- bench node ----

# Every arm runs on ONE node, so storage is the only variable. Pick the node with the most free
# memory: the bench adds ~1.5Gi and these are 8Gi boards, so this is the choice least likely to
# evict something real. Replica placement is then forced by the tag in setup_classes, not left to
# Longhorn's free-space heuristic.
pick_nodes() {
  say "picking the bench node"
  local n best=-1 mem
  for n in $(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {end}'); do
    mem="$(node_free_mem_mi "$n")"
    if [ "$mem" -gt "$best" ]; then best="$mem"; BENCH_NODE="$n"; fi
  done
  [ -n "$BENCH_NODE" ] || die "could not pick a bench node"

  # pgbench and perf-test clients run elsewhere so client CPU never contends with the thing under test.
  for n in $(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {end}'); do
    [ "$n" != "$BENCH_NODE" ] && OFF_NODE="$n" && break
  done
  ok "bench node ${BENCH_NODE} (${best}Mi free); clients on ${OFF_NODE}"
}

# ---- fio ----

fio_arm() {
  local arm="$1" sc="$2" rep="$3" out="${RUN_DIR}/fio/${1}/r${3}"
  mkdir -p "$out"
  local want_local=skip
  [ "$arm" = "c-lh-local" ] && want_local=yes
  [ "$arm" = "b-lh-remote" ] && want_local=no

  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: fio-${arm}, namespace: ${BENCH_NS}, labels: { $(labelled) } }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ${sc}
  resources: { requests: { storage: ${PVC_SIZE} } }
---
apiVersion: v1
kind: Pod
metadata: { name: fio-${arm}, namespace: ${BENCH_NS}, labels: { $(labelled) } }
spec:
  # No priorityClassName on purpose: priority 0 puts the bench below data-critical, so node-pressure
  # eviction reaches the benchmark before it reaches any database.
  nodeSelector: { kubernetes.io/hostname: ${BENCH_NODE} }
  restartPolicy: Never
  containers:
    - name: fio
      image: ${FIO_IMAGE}
      command: [sh, -c, "apk add --no-cache fio >/dev/null && sleep infinity"]
      # PSA enforces baseline here, so root is permitted and apk needs it. Drop everything baseline
      # does not already require, so this is only as privileged as the package install forces.
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: [ALL] }
        seccompProfile: { type: RuntimeDefault }
      resources: { requests: { cpu: 200m, memory: 128Mi }, limits: { cpu: "2", memory: 512Mi } }
      volumeMounts:
        - { name: data, mountPath: /data }
        - { name: jobs, mountPath: /jobs }
  volumes:
    - { name: data, persistentVolumeClaim: { claimName: fio-${arm} } }
    - { name: jobs, configMap: { name: bench-fio } }
YAML

  wait_for "fio pod on ${arm}" 300 kb exec "fio-${arm}" -- which fio || return 1
  if [ "$want_local" != skip ]; then
    wait_for "${arm} replica layout to settle" 300 volume_settled "fio-${arm}" "$want_local" || return 1
  fi
  replica_nodes "fio-${arm}" > "${out}/replica-nodes.txt" 2>/dev/null

  local job
  for job in "${FIO_JOBS[@]}"; do
    kb exec "fio-${arm}" -- fio --output-format=json "/jobs/${job}.fio" > "${out}/${job}.json" 2>"${out}/${job}.err" \
      && ok "${arm} r${rep} fio ${job}" || bad "${arm} r${rep} fio ${job} failed"
  done

  kb delete pod "fio-${arm}" --wait=true --timeout=120s >/dev/null 2>&1
  kb delete pvc "fio-${arm}" --wait=true --timeout=120s >/dev/null 2>&1
}

# ---- pgbench ----

pg_arm_up() {
  local arm="$1" sc="$2" instances="${3:-1}" sync="${4:-off}"

  # One instance is pinned to BENCH_NODE so storage is the only variable, which is what the three
  # locality arms need. Several instances cannot be: they have to sit on DIFFERENT nodes or the
  # synchronous ack never crosses the network and the measurement is meaningless. So required
  # anti-affinity spreads them one per node instead, and which node ends up primary is recorded
  # per cell rather than controlled. See the threats section in docs/12_storage_bench.md.
  local placement="    nodeSelector: { kubernetes.io/hostname: ${BENCH_NODE} }"
  [ "$instances" -gt 1 ] && placement="    podAntiAffinityType: required
    topologyKey: kubernetes.io/hostname"

  local syncblock=""
  [ "$sync" = on ] && syncblock="    synchronous: { method: any, number: 1, dataDurability: required }"

  kubectl apply -f - >/dev/null <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: pg-${arm}, namespace: ${BENCH_NS}, labels: { $(labelled) } }
spec:
  instances: ${instances}
  imageName: ${PG_IMAGE}
  postgresUID: 26
  postgresGID: 26
  storage: { size: ${PVC_SIZE}, storageClass: ${sc} }
  affinity:
${placement}
  enableSuperuserAccess: false
  postgresql:
${syncblock}
    parameters:
      # The live pg-cluster values verbatim, plus the two timing counters. Everything that decides
      # commit cost (synchronous_commit, fsync, full_page_writes, checkpoint_timeout) stays at its
      # production value, or the result would not transfer.
      max_connections: "50"
      shared_buffers: "128MB"
      effective_cache_size: "256MB"
      track_io_timing: "on"
      track_wal_io_timing: "on"
  bootstrap: { initdb: { database: app, owner: app } }
  resources:
    requests: { cpu: 250m, memory: 256Mi }
    limits: { cpu: "1", memory: 512Mi }
YAML
  wait_for "pg-${arm} healthy" 900 pg_healthy "pg-${arm}"
}

# The one failure that would silently ruin a pgsync run: CNPG ignoring a malformed `synchronous` block,
# so the arm measures async and the grid reports "sync is free". Postgres itself is asked, twice, and a
# failure SKIPS the arm rather than recording a number nobody can trust. Written to synchronous.txt as
# the run's evidence that the arm was what it claimed.
pg_assert_sync() {
  local arm="$1" out="$2" names states pod
  pod="$(pg_primary "pg-${arm}")"
  [ -n "$pod" ] || { bad "${arm}: no primary to interrogate"; return 1; }
  mkdir -p "$out"
  # -At leaves psql's default '|' between columns, which avoids quoting a separator into the SQL.
  names="$(kb exec "$pod" -c postgres -- psql -U postgres -Atc 'show synchronous_standby_names;' 2>/dev/null)"
  states="$(kb exec "$pod" -c postgres -- psql -U postgres -Atc \
            'select application_name, sync_state from pg_stat_replication;' 2>/dev/null)"
  printf 'primary: %s on %s\nsynchronous_standby_names: %s\npg_stat_replication:\n%s\n' \
    "$pod" "$(pg_primary_node "pg-${arm}")" "${names:-<empty>}" "${states:-<none>}" > "${out}/synchronous.txt"

  [ -n "$names" ] || { bad "${arm}: synchronous_standby_names is EMPTY, so this arm is async; skipping"; return 1; }
  grep -qE '\|(sync|quorum)$' <<< "$states" \
    || { bad "${arm}: no standby reports sync_state sync/quorum (${states:-none}); skipping"; return 1; }
  ok "${arm} is genuinely synchronous (${names})"
}

pg_client_up() {
  kb get pod pgclient >/dev/null 2>&1 && return 0
  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: pgclient, namespace: ${BENCH_NS}, labels: { $(labelled) } }
spec:
  nodeSelector: { kubernetes.io/hostname: ${OFF_NODE} }
  restartPolicy: Never
  containers:
    - name: c
      image: ${PG_IMAGE}
      command: [sleep, infinity]
      resources: { requests: { cpu: 200m, memory: 128Mi }, limits: { cpu: "1", memory: 256Mi } }
YAML
  wait_for "pgbench client pod" 300 kb exec pgclient -- test -x "/usr/lib/postgresql/${PG_MAJOR}/bin/pgbench"
}

pgbench_arm() {
  # 4th arg is the workload dir, so pgsync's cells land beside pgbench's rather than mixed in with them.
  # The cell body is identical for both: only how the cluster was provisioned differs.
  local arm="$1" sc="$2" rep="$3" kind="${4:-pgbench}" out="${RUN_DIR}/${4:-pgbench}/${1}/r${3}"
  mkdir -p "$out"
  local bin="/usr/lib/postgresql/${PG_MAJOR}/bin"
  local conn; conn="$(pg_conn "$arm")"
  # Resolved, not assumed: with several instances the primary is whichever CNPG picked, and every
  # probe below has to hit THAT pod or it measures a standby's storage instead.
  local pri; pri="$(pg_primary "pg-${arm}")"
  [ -n "$pri" ] || { bad "${arm} r${rep}: no primary, skipping cell"; return 1; }

  replica_nodes "${pri}" > "${out}/replica-nodes.txt" 2>/dev/null
  pg_primary_node "pg-${arm}" > "${out}/primary-node.txt" 2>/dev/null

  # Zero-network cross-check on the same volume. If it disagrees with fio's sync p50 the fio job is wrong.
  kb_exec_retry "${arm} r${rep} pg_test_fsync" "${out}/pg_test_fsync.txt" 3 \
    "$pri" -c postgres -- "${bin}/pg_test_fsync" -f /var/lib/postgresql/data/pgdata/fsync-probe -s 5
  kb exec "$pri" -c postgres -- rm -f /var/lib/postgresql/data/pgdata/fsync-probe >/dev/null 2>&1

  kb exec pgclient -- psql "$conn" -Atc \
    "SELECT backend_type,object,context,writes,write_time,fsyncs,fsync_time FROM pg_stat_io WHERE object='wal';
     SELECT wal_records,wal_fpi,wal_bytes,wal_buffers_full FROM pg_stat_wal;
     SELECT blk_write_time,blk_read_time,xact_commit FROM pg_stat_database WHERE datname='app';" \
    > "${out}/pgstat.before" 2>&1
  # Separately, and as postgres from inside the primary: pg_stat_replication hides sync_state and the
  # lag columns from unprivileged roles, so via pgclient's app user they all come back NULL.
  kb exec "$pri" -c postgres -- psql -U postgres -Atc \
    'SELECT application_name,sync_state,write_lag,flush_lag,replay_lag FROM pg_stat_replication;' \
    > "${out}/replication.before" 2>&1

  local run
  for run in c1 c8; do
    local clients=1 threads=1
    [ "$run" = c8 ] && { clients=$PGBENCH_CLIENTS; threads=4; }
    # --log-prefix=/tmp/c1 writes /tmp/c1.<pid>[.<thread>], NOT /tmp/c1.log.*, so the glob is prefix.*
    kb exec pgclient -- sh -c \
      "rm -f /tmp/${run}.*; ${bin}/pgbench -c ${clients} -j ${threads} -T ${PGBENCH_SECONDS} -P 10 -r \
         --log --log-prefix=/tmp/${run} '${conn}'" \
      > "${out}/${run}.txt" 2>&1 \
      && ok "${arm} r${rep} pgbench ${run}" || bad "${arm} r${rep} pgbench ${run} failed"
    kb exec pgclient -- sh -c "cat /tmp/${run}.*" > "${out}/${run}.log" 2>/dev/null
    [ -s "${out}/${run}.log" ] || bad "${arm} r${rep} pgbench ${run}: no transaction log captured"
    awk -v warmup="$PGBENCH_WARMUP" -f "${BENCH_LIB}/pctl.awk" "${out}/${run}.log" > "${out}/${run}.pctl" 2>/dev/null
  done

  # Read-only control. Reads come from cache, so this MUST match across arms; if it does not, the arms
  # were never comparable and no verdict may be read off the write numbers.
  kb exec pgclient -- "${bin}/pgbench" -S -c 4 -j 4 -T 60 -P 10 "$conn" \
    > "${out}/select.txt" 2>&1 && ok "${arm} r${rep} pgbench -S control" || bad "${arm} r${rep} -S control failed"

  kb exec pgclient -- psql "$conn" -Atc \
    "SELECT backend_type,object,context,writes,write_time,fsyncs,fsync_time FROM pg_stat_io WHERE object='wal';
     SELECT wal_records,wal_fpi,wal_bytes,wal_buffers_full FROM pg_stat_wal;
     SELECT blk_write_time,blk_read_time,xact_commit FROM pg_stat_database WHERE datname='app';" \
    > "${out}/pgstat.after" 2>&1
  # Separately, and as postgres from inside the primary: pg_stat_replication hides sync_state and the
  # lag columns from unprivileged roles, so via pgclient's app user they all come back NULL.
  kb exec "$pri" -c postgres -- psql -U postgres -Atc \
    'SELECT application_name,sync_state,write_lag,flush_lag,replay_lag FROM pg_stat_replication;' \
    > "${out}/replication.after" 2>&1
}

# ---- rabbitmq ----

mq_arm_up() {
  local arm="$1" sc="$2"
  kubectl apply -f - >/dev/null <<YAML
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata: { name: bench-mq, namespace: ${BENCH_NS}, labels: { $(labelled) } }
spec:
  replicas: ${MQ_REPLICAS}
  image: ${MQ_IMAGE}
  # The live CR says 604800 (7 days). Inheriting that would wedge teardown for a week; this is the one
  # place the bench deliberately breaks parity with production.
  terminationGracePeriodSeconds: 30
  persistence: { storage: ${MQ_PVC_SIZE}, storageClassName: ${sc} }
  resources:
    requests: { cpu: 200m, memory: 384Mi }
    limits: { cpu: "1", memory: 384Mi }
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector: { matchLabels: { app.kubernetes.io/name: bench-mq } }
          topologyKey: kubernetes.io/hostname
  rabbitmq:
    additionalConfig: |
      default_queue_type = quorum
      total_memory_available_override_value = 402653184
      vm_memory_high_watermark.relative = 0.85
YAML
  wait_for "bench-mq AllReplicasReady" 900 mq_ready bench-mq
}

amqp_arm() {
  local arm="$1" rep="$2" out="${RUN_DIR}/amqp/${1}/r${2}"
  mkdir -p "$out"
  local u p
  u="$(kb get secret bench-mq-default-user -o jsonpath='{.data.username}' | base64 -d)"
  p="$(kb get secret bench-mq-default-user -o jsonpath='{.data.password}' | base64 -d)"
  local uri="amqp://${u}:${p}@bench-mq.${BENCH_NS}.svc:5672/%2f"

  kb get pods -l app.kubernetes.io/name=bench-mq \
    -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName' --no-headers > "${out}/broker-nodes.txt" 2>/dev/null

  # -c 1 is one outstanding confirm, so every publish waits on the Raft majority fsync: that IS the
  # write-latency number. -c 100 pipelines and shows whether the cost amortizes into throughput.
  local c
  for c in 1 100; do
    kb delete pod "perftest-c${c}" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1
    kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: perftest-c${c}, namespace: ${BENCH_NS}, labels: { $(labelled) } }
spec:
  nodeSelector: { kubernetes.io/hostname: ${OFF_NODE} }
  restartPolicy: Never
  containers:
    - name: perftest
      image: ${PERFTEST_IMAGE}
      args:
        - --uri
        - "${uri}"
        - -x
        - "1"
        - -y
        - "1"
        - -u
        - "bench-qq-c${c}"
        - --quorum-queue
        - -s
        - "1024"
        - -c
        - "${c}"
        - -z
        - "${PERFTEST_SECONDS}"
        - -i
        - "10"
        - -mf
        - compact
      resources: { requests: { cpu: 200m, memory: 256Mi }, limits: { cpu: "1", memory: 512Mi } }
YAML
    if wait_for "perf-test -c ${c} to finish" $((PERFTEST_SECONDS + 300)) pod_done "perftest-c${c}"; then
      kb logs "perftest-c${c}" > "${out}/c${c}.txt" 2>&1
      [ "$(kb get pod "perftest-c${c}" -o jsonpath='{.status.phase}')" = "Succeeded" ] \
        && ok "${arm} r${rep} perf-test -c ${c}" || bad "${arm} r${rep} perf-test -c ${c} exited non-zero"
    else
      kb logs "perftest-c${c}" > "${out}/c${c}.txt" 2>&1
      bad "${arm} r${rep} perf-test -c ${c} never finished"
    fi
    kb delete pod "perftest-c${c}" --wait=false >/dev/null 2>&1
  done
}

# ---- cell driver ----

# Records BACKGROUND load either side of a cell, to catch a neighbour (a CronJob, an ArgoCD sync, a
# Longhorn rebuild) turning up mid-measurement. A cell that ran through a big swing measured the
# neighbour, not the storage, so it is flagged void rather than averaged in.
#
# Both samples must be of an IDLE cluster, hence the settle sleep BEFORE the second one. `kubectl top`
# serves a rolling average, so sampling the instant the load stops just re-reads the benchmark's own
# CPU and flags every single cell. That is exactly what the first smoke run did.
cell() {
  local kind="$1" arm="$2" sc="$3" rep="$4"
  local before after n
  before=""; for n in $(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {end}'); do
    before="${before}${n}=$(node_cpu_pct "$n") "
  done

  case "$kind" in
    fio)     fio_arm "$arm" "$sc" "$rep" ;;
    pgbench|pgsync) pgbench_arm "$arm" "$sc" "$rep" "$kind" ;;
    amqp)    amqp_arm "$arm" "$rep" ;;
  esac

  sleep "$INTER_CELL_SLEEP"   # let the load drain out of metrics-server's window before re-sampling
  after=""; for n in $(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {end}'); do
    after="${after}${n}=$(node_cpu_pct "$n") "
  done
  printf '%s r%s\n  before: %s\n  after:  %s\n' "$arm" "$rep" "$before" "$after" \
    >> "${RUN_DIR}/${kind}/load.txt"

  local drift=0 b a
  for n in $(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {end}'); do
    b="$(grep -o "${n}=[0-9]*" <<< "$before" | cut -d= -f2)"
    a="$(grep -o "${n}=[0-9]*" <<< "$after" | cut -d= -f2)"
    [ -n "$b" ] && [ -n "$a" ] && [ "$(( b > a ? b - a : a - b ))" -gt "$CPU_DRIFT_ABORT" ] && drift=1
  done
  [ "$drift" -eq 1 ] \
    && warn "${kind} ${arm} r${rep}: background node CPU moved >${CPU_DRIFT_ABORT}pt across the cell, treat as void"
  return 0
}

# ---- run ----

do_run() {
  $SMOKE && apply_smoke_knobs
  preflight   # before the prompt: no point asking for hours of cluster time if it would fail anyway

  # Per arm: a one-off provisioning cost, plus a per-repeat measuring cost. Seconds, then minutes.
  local n_arms=${#ARMS[@]} slow_arms=${#ARMS[@]} fio_m=0 pg_m=0 mq_m=0 sy_m=0 est
  local sync_arms=${#SYNC_ARMS[@]}
  $SMOKE && slow_arms=1
  $SMOKE && sync_arms=2
  local fio_run=175; $SMOKE && fio_run=10
  case "$WORKLOADS" in fio|all)
    fio_m=$(( n_arms * (90 + REPEATS * (fio_run + INTER_CELL_SLEEP)) )) ;;
  esac
  case "$WORKLOADS" in pgbench|all)
    pg_m=$(( slow_arms * (210 + 150 + 90 + REPEATS * (2 * PGBENCH_SECONDS + 60 + INTER_CELL_SLEEP)) )) ;;
  esac
  case "$WORKLOADS" in amqp|all)
    mq_m=$(( slow_arms * (240 + 90 + REPEATS * (2 * PERFTEST_SECONDS + INTER_CELL_SLEEP)) )) ;;
  esac
  # A 3-instance cluster takes longer to form than a 1-instance one, hence 300 rather than 210.
  case "$WORKLOADS" in pgsync)
    sy_m=$(( sync_arms * (300 + 150 + 90 + REPEATS * (2 * PGBENCH_SECONDS + 60 + INTER_CELL_SLEEP)) )) ;;
  esac
  est=$(( (fio_m + pg_m + mq_m + sy_m) / 60 ))

  if $SMOKE; then
    say "SMOKE: ~${est} min. Exercises every path once; the numbers are garbage on purpose."
  else
    say "estimate: ~${est} min (fio $((fio_m/60)), pgbench $((pg_m/60)), amqp $((mq_m/60)), pgsync $((sy_m/60))) at --repeats ${REPEATS}"
    warn "the cluster is loaded the whole time; live apps will be slower. --workload fio is the shortest real answer."
  fi
  confirm "run the benchmark now?" || die "aborted"

  RUN_DIR="${REPO_ROOT}/.cache/storage-bench/$(date -u +%Y%m%dT%H%MZ)"
  $SMOKE && RUN_DIR="${RUN_DIR}-SMOKE"   # in the path, so nobody quotes these numbers by accident
  if [ -n "$RESUME_DIR" ]; then
    [ -d "$RESUME_DIR" ] || die "--resume: no such run dir: ${RESUME_DIR}"
    RUN_DIR="$RESUME_DIR"
    warn "resuming into ${RUN_DIR}: finished arms are skipped, so cells will span two points in time."
    warn "the pgbench -S control is what says whether they are still comparable. Check it before reading the grid."
  fi
  mkdir -p "${RUN_DIR}"/{fio,pgbench,amqp,pgsync}
  trap 'teardown' EXIT
  setup_ns
  pick_nodes            # must run before the classes: the tag they select on is "not the bench node"
  # pgsync measures the shipped longhorn class, so it needs neither bench class nor the replica tag.
  # No reason to tag every Longhorn node for a run that never selects on it.
  case "$WORKLOADS" in pgsync) say "skipping the bench StorageClasses: pgsync uses the shipped class" ;;
    *) setup_classes ;;
  esac
  setup_support

  {
    $SMOKE && echo "SMOKE RUN: plumbing check only, the numbers below are meaningless"
    echo "git: $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
    echo "benchNode: ${BENCH_NODE}"
    echo "clientNode: ${OFF_NODE}"
    echo "repeats: ${REPEATS}"
    echo "pgImage: ${PG_IMAGE}"
  } > "${RUN_DIR}/manifest.txt"

  # fio is cheap to set up (a PVC and a pod), so it runs repeat-major and PALINDROMIC: repeat 1
  # forward, repeat 2 reversed, repeat 3 forward, which cancels linear drift instead of loading it
  # onto whichever arm always goes last.
  case "$WORKLOADS" in fio|all)
    local rep i arm id sc
    for ((rep = 1; rep <= REPEATS; rep++)); do
      local order=()
      if (( rep % 2 == 1 )); then
        for i in "${!ARMS[@]}"; do order+=("${ARMS[$i]}"); done
      else
        for ((i = ${#ARMS[@]} - 1; i >= 0; i--)); do order+=("${ARMS[$i]}"); done
      fi
      for arm in "${order[@]}"; do
        id="${arm%%|*}"; sc="$(cut -d'|' -f2 <<< "$arm")"
        say "fio repeat ${rep}/${REPEATS}: ${id} (${sc})"
        cell fio "$id" "$sc" "$rep"
      done
    done
    ;;
  esac

  # pgbench and amqp run ARM-MAJOR: provision once, then loop the repeats against it. Repeat-major
  # would rebuild a CNPG cluster and reload pgbench's dataset 9 times instead of 3, which is over an
  # hour of pure churn for no extra information. The cost is that an arm's repeats sit adjacent in
  # time, so drift shows up as within-cell variance rather than cancelling; the report prints the
  # per-repeat spread, and the 1.5x validity gate is what catches it.
  # Under --smoke only the first arm: a second CNPG cluster forming proves nothing the first did not,
  # and it is 6 of the 10 minutes.
  local slow=("${ARMS[@]}"); $SMOKE && slow=("${ARMS[0]}")

  case "$WORKLOADS" in pgbench|all)
    for arm in "${slow[@]}"; do
      id="${arm%%|*}"; sc="$(cut -d'|' -f2 <<< "$arm")"
      if [ -f "${RUN_DIR}/pgbench/${id}/r${REPEATS}/c8.txt" ]; then
        ok "pgbench: ${id} already complete, skipping (--resume)"; continue
      fi
      say "pgbench: ${id} (${sc})"
      if pg_arm_up "$id" "$sc"; then
        pg_client_up
        kb exec pgclient -- "/usr/lib/postgresql/${PG_MAJOR}/bin/pgbench" \
          -i -s "$PGBENCH_SCALE" "$(pg_conn "$id")" >/dev/null 2>&1 \
          && ok "${id} pgbench -i -s ${PGBENCH_SCALE}" || bad "${id} pgbench init failed"
        for ((rep = 1; rep <= REPEATS; rep++)); do cell pgbench "$id" "$sc" "$rep"; done
        kb delete cluster.postgresql.cnpg.io "pg-${id}" --wait=true --timeout=180s >/dev/null 2>&1
        kb delete pvc -l "cnpg.io/cluster=pg-${id}" --wait=true --timeout=180s >/dev/null 2>&1
      else
        bad "${id}: CNPG cluster never became healthy, skipping pgbench"
      fi
    done
    ;;
  esac

  # pgsync: same cell body, different provisioning. Under --smoke only the two sync arms, since the
  # async ones are just pgbench again and prove nothing new about the synchronous path.
  local syncset=("${SYNC_ARMS[@]}")
  $SMOKE && syncset=("${SYNC_ARMS[1]}" "${SYNC_ARMS[3]}")

  case "$WORKLOADS" in pgsync)
    for arm in "${syncset[@]}"; do
      id="${arm%%|*}"; sc="$(cut -d'|' -f2 <<< "$arm")"
      local inst syn; inst="$(cut -d'|' -f3 <<< "$arm")"; syn="$(cut -d'|' -f4 <<< "$arm")"
      if [ -f "${RUN_DIR}/pgsync/${id}/r${REPEATS}/c8.pctl" ]; then
        ok "pgsync: ${id} already complete, skipping (--resume)"; continue
      fi
      say "pgsync: ${id} (${sc}, ${inst} instance(s), sync ${syn})"
      if pg_arm_up "$id" "$sc" "$inst" "$syn"; then
        # An arm that claims to be synchronous and is not would report "sync is free", so it is proved
        # against Postgres before a single number is taken, and skipped rather than half-trusted.
        if [ "$syn" = on ] && ! pg_assert_sync "$id" "${RUN_DIR}/pgsync/${id}"; then
          kb delete cluster.postgresql.cnpg.io "pg-${id}" --wait=true --timeout=180s >/dev/null 2>&1
          kb delete pvc -l "cnpg.io/cluster=pg-${id}" --wait=true --timeout=180s >/dev/null 2>&1
          continue
        fi
        pg_client_up
        kb exec pgclient -- "/usr/lib/postgresql/${PG_MAJOR}/bin/pgbench" \
          -i -s "$PGBENCH_SCALE" "$(pg_conn "$id")" >/dev/null 2>&1 \
          && ok "${id} pgbench -i -s ${PGBENCH_SCALE}" || bad "${id} pgbench init failed"
        for ((rep = 1; rep <= REPEATS; rep++)); do cell pgsync "$id" "$sc" "$rep"; done
        kb delete cluster.postgresql.cnpg.io "pg-${id}" --wait=true --timeout=180s >/dev/null 2>&1
        kb delete pvc -l "cnpg.io/cluster=pg-${id}" --wait=true --timeout=180s >/dev/null 2>&1
      else
        bad "${id}: CNPG cluster never became healthy, skipping pgsync"
      fi
    done
    ;;
  esac

  case "$WORKLOADS" in amqp|all)
    for arm in "${slow[@]}"; do
      id="${arm%%|*}"; sc="$(cut -d'|' -f2 <<< "$arm")"
      if [ -f "${RUN_DIR}/amqp/${id}/r${REPEATS}/c100.txt" ]; then
        ok "amqp: ${id} already complete, skipping (--resume)"; continue
      fi
      say "amqp: ${id} (${sc})"
      if mq_arm_up "$id" "$sc"; then
        for ((rep = 1; rep <= REPEATS; rep++)); do cell amqp "$id" "$sc" "$rep"; done
        kb delete rabbitmqcluster bench-mq --wait=true --timeout=180s >/dev/null 2>&1
        kb delete pvc -l app.kubernetes.io/name=bench-mq --wait=true --timeout=180s >/dev/null 2>&1
      else
        bad "${id}: bench-mq never became ready, skipping amqp"
      fi
    done
    ;;
  esac

  do_report "$RUN_DIR"
  say "raw output: ${RUN_DIR}"
  summary || exit 1
}

# ---- report ----

do_report() {
  local dir="${1:?usage: report <run-dir>}"
  [ -d "$dir" ] || die "no such run dir: ${dir}"
  local md="${dir}/summary.md"

  {
    echo "# storage-bench $(basename "$dir")"
    echo
    sed 's/^/    /' "${dir}/manifest.txt" 2>/dev/null
    echo
    echo '| workload | arm | rep | p50 ms | p95 ms | p99 ms | max ms | rate |'
    echo '|---|---|---|---|---|---|---|---|'

    local f arm rep
    for f in "${dir}"/fio/*/r*/wal-fsync.json "${dir}"/fio/*/r*/smoke.json; do
      [ -f "$f" ] || continue
      rep="$(basename "$(dirname "$f")")"; arm="$(basename "$(dirname "$(dirname "$f")")")"
      python3 - "$f" "$arm" "$rep" <<'PY'
import json,sys
try: j=json.load(open(sys.argv[1]))
except Exception: sys.exit()
job=j["jobs"][0]
s=job.get("sync",{}).get("lat_ns",{})
if not s: sys.exit()
p=s.get("percentile",{})
g=lambda k: p.get(k,0)/1e6
print("| fio fdatasync | %s | %s | %.3f | %.3f | %.3f | %.3f | %.0f iops |" % (
  sys.argv[2], sys.argv[3], g("50.000000"), g("95.000000"), g("99.000000"),
  s.get("max",0)/1e6, job["write"]["iops"]))
PY
    done

    local line
    for f in "${dir}"/pgbench/*/r*/c1.pctl "${dir}"/pgbench/*/r*/c8.pctl; do
      [ -f "$f" ] || continue
      rep="$(basename "$(dirname "$f")")"; arm="$(basename "$(dirname "$(dirname "$f")")")"
      line="$(cat "$f")"
      [ "$(kv n "$line")" = "0" ] && continue
      printf '| pgbench %s | %s | %s | %s | %s | %s | %s | %s tps |\n' \
        "$(basename "$f" .pctl)" "$arm" "$rep" \
        "$(kv p50 "$line")" "$(kv p95 "$line")" "$(kv p99 "$line")" \
        "$(kv max "$line")" "$(kv tps "$line")"
    done

    for f in "${dir}"/pgsync/*/r*/c1.pctl "${dir}"/pgsync/*/r*/c8.pctl; do
      [ -f "$f" ] || continue
      rep="$(basename "$(dirname "$f")")"; arm="$(basename "$(dirname "$(dirname "$f")")")"
      line="$(cat "$f")"
      [ "$(kv n "$line")" = "0" ] && continue
      printf '| pgsync %s | %s | %s | %s | %s | %s | %s | %s tps |\n' \
        "$(basename "$f" .pctl)" "$arm" "$rep" \
        "$(kv p50 "$line")" "$(kv p95 "$line")" "$(kv p99 "$line")" \
        "$(kv max "$line")" "$(kv tps "$line")"
    done

    # perf-test's closing summary, e.g.
    #   confirm latency min/median/75th/95th/99th/max 3219/5697/6025/7984/10703/48067 us
    # The per-interval lines carry the same numbers but "confirm latency" there is a column HEADER,
    # so anchor on the summary line and take the slash-separated field.
    for f in "${dir}"/amqp/*/r*/c1.txt "${dir}"/amqp/*/r*/c100.txt; do
      [ -f "$f" ] || continue
      rep="$(basename "$(dirname "$f")")"; arm="$(basename "$(dirname "$(dirname "$f")")")"
      awk -v arm="$arm" -v rep="$rep" -v run="$(basename "$f" .txt)" '
        /^confirm latency/ {
          for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+(\/[0-9]+)+$/) { split($i, v, "/"); found = 1 }
        }
        /^sending rate avg/ { rate = $4 }
        END {
          if (found)
            printf "| perf-test %s | %s | %s | %.3f | %.3f | %.3f | %.3f | %s msg/s |\n",
              run, arm, rep, v[2]/1000, v[4]/1000, v[5]/1000, v[6]/1000, rate
        }' "$f"
    done

    echo
    echo '## Validity gates'
    echo
    pgsync_grid "$dir"
    echo
    echo '#### validity gates'
    echo '- [ ] pgbench -S read-only control within 10% across arms (see per-arm select.txt)'
    echo '- [ ] max/min of p99 across repeats under 1.5x in every cell'
    echo '- [ ] pg_test_fsync and fio sync p50 within 2x AND ranking the arms the same way'
    echo '- [ ] no cell flagged by the CPU-drift guard (see fio/load.txt, pgbench/load.txt)'
    echo '- [ ] c-lh-local had a local replica and b-lh-remote did not (replica-nodes.txt per cell)'
    if compgen -G "${dir}/pgsync/*" >/dev/null; then
      echo '- [ ] both sync arms show a real sync/quorum standby (pgsync/*/synchronous.txt)'
      echo '- [ ] primary on the same node in every pgsync arm (pgsync/*/r*/primary-node.txt)'
      echo '- [ ] g-lh-sync minus e-local-sync is near 2x the f-lh-async minus d-local-async gap;'
      echo '      far off means the network dominates both, or a cell is invalid'
    fi
    echo
    echo 'Any unchecked box means INVALID: publish no verdict.'
  } > "$md"

  cat "$md"
}

# ---- corroborate ----

# Deliberately a separate sub-command, never a hidden port-forward inside a run. At scrapeInterval 60s
# and dedup.minScrapeInterval 60s a 150s cell yields two samples, so this can contradict the tools but
# it cannot replace them.
do_corroborate() {
  local dir="${1:?usage: corroborate <run-dir>}"
  local svc="vmsingle-victoria-metrics-k8s-stack" port=8428
  require kubectl

  local pf=""
  cleanup_pf() { [ -n "$pf" ] && kill "$pf" 2>/dev/null; }
  trap cleanup_pf EXIT

  say "port-forwarding svc/${svc} (${MONITORING_NS}) -> 127.0.0.1:${port}"
  kubectl -n "$MONITORING_NS" port-forward "svc/${svc}" "${port}:${port}" >/dev/null 2>&1 &
  pf=$!
  local i
  for i in $(seq 1 30); do
    (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null && { exec 3>&- 3<&-; break; }
    kill -0 "$pf" 2>/dev/null || die "port-forward died (is the monitoring stack up?)"
    sleep 1
  done

  local q
  for q in 'longhorn_volume_write_latency' 'longhorn_volume_write_iops' \
           'rate(node_disk_flush_requests_time_seconds_total[5m])'; do
    say "$q"
    curl -sG "http://127.0.0.1:${port}/api/v1/query" --data-urlencode "query=${q}" \
      | python3 -c 'import json,sys
for r in json.load(sys.stdin)["data"]["result"]:
    m=r["metric"]; print(" ", m.get("volume") or m.get("device"), m.get("node") or m.get("instance"), r["value"][1])'
  done | tee "${dir}/corroborate.txt"
}

# ---- main ----

CMD="run"
case "${1:-run}" in
  run|teardown|report|corroborate) CMD="$1"; shift ;;
  -*) ;;
  "") ;;
  *) usage ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --workload) WORKLOADS="$2"
                case "$WORKLOADS" in fio|pgbench|amqp|pgsync|all) ;;
                  *) die "unknown --workload '${WORKLOADS}': every case below would miss it and the run would do nothing" ;;
                esac
                shift 2 ;;
    --repeats)  REPEATS="$2"; shift 2 ;;
    --smoke)    SMOKE=true; shift ;;
    --resume)   RESUME_DIR="$2"; shift 2 ;;
    -h|--help)  usage ;;
    *)          break ;;
  esac
done

require kubectl yq python3
use_kubeconfig
assert_api

case "$CMD" in
  run)         do_run ;;
  teardown)    teardown; summary || exit 1 ;;
  report)      do_report "${1:-}" ;;
  corroborate) do_corroborate "${1:-}" ;;
esac
