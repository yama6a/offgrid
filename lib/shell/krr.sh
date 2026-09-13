#!/usr/bin/env bash
# On-demand rightsizing: runs Robusta KRR and prints, per workload, current CPU/memory requests next to what
# usage history says they should be. Read the numbers, then hand-edit the chart values. Extra args go to KRR.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
SVC="vmsingle-victoria-metrics-k8s-stack"   # the VMSingle PromQL API service in $MONITORING_NS
PORT=8428                                   # vmsingle's port; same on both sides of the forward
# renovate: datasource=docker
KRR_IMAGE="us-central1-docker.pkg.dev/genuine-flight-317411/devel/krr:v1.30.0"

# ---- state ----
TMP_KUBECONFIG=""   # set by copy_kubeconfig, removed by cleanup
PF_PID=""           # set by start_port_forward, killed by cleanup

# ---- functions ----

cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  rm -f "$TMP_KUBECONFIG"
}

# A temp copy, not $KUBECONFIG itself: it lives under the repo's .cache/, which Docker Desktop's file sharing
# may not expose for bind-mounts. A plain copy suffices because use_kubeconfig already pinned it to one
# context with the certs inlined, so it stands alone inside the container.
copy_kubeconfig() {
  TMP_KUBECONFIG="$(mktemp -t krr-kubeconfig.XXXXXX)"
  cp "$KUBECONFIG" "$TMP_KUBECONFIG"
}

# KRR needs a Prometheus-API metrics source. Ours is VMSingle, a ClusterIP with no external programmatic auth,
# so we reach it over the documented break-glass port-forward.
start_port_forward() {
  say "port-forwarding svc/${SVC} (${MONITORING_NS}) -> 127.0.0.1:${PORT}"
  kubectl -n "$MONITORING_NS" port-forward "svc/${SVC}" "${PORT}:${PORT}" >/dev/null 2>&1 &
  PF_PID=$!
}

# Waits for the listener in a bounded window rather than hanging.
wait_for_port_forward() {
  local _
  for _ in $(seq 1 30); do
    (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null && { exec 3>&- 3<&-; break; }
    kill -0 "$PF_PID" 2>/dev/null || die "port-forward to ${SVC} died (is the monitoring stack up?)"
    sleep 1
  done
  (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null \
    || die "port-forward to ${SVC} never became ready on 127.0.0.1:${PORT}"
  exec 3>&- 3<&-
}

# Bridge network, NOT --network host: on Docker Desktop a host-network container cannot see the host-side
# port-forward, whereas the bridge reaches it via host.docker.internal.
# The image has no ENTRYPOINT, so passing args would REPLACE its whole command, hence --entrypoint python.
# The two extra mounts drop our own `conservative` strategy into the image's strategies package and replace
# its __init__.py with one that imports ours: KRR finds strategies by walking the subclasses of its base
# class, and a class only exists to be found once its module has been imported. No image rebuild needed.
# The series the strategy reads are all kept by vmagent's drop list, so check there before pruning metrics.
# --mem-min 0 disables KRR's built-in memory floor, which applies to request AND limit alike, so the strategy
# owns the asymmetric floors instead.
run_krr() {
  local tty=""
  say "running KRR (conservative) against http://host.docker.internal:${PORT}"
  [ -t 1 ] && tty="-t"
  docker run --rm ${tty} \
    -v "${TMP_KUBECONFIG}:/kubeconfig:ro" -e KUBECONFIG=/kubeconfig \
    -v "${REPO_ROOT}/lib/krr/conservative.py:/app/robusta_krr/strategies/conservative.py:ro" \
    -v "${REPO_ROOT}/lib/krr/strategies_init.py:/app/robusta_krr/strategies/__init__.py:ro" \
    --entrypoint python \
    "$KRR_IMAGE" krr.py conservative \
    -p "http://host.docker.internal:${PORT}" \
    --memory_request_min 16 --memory_limit_min 32 \
    --mem-min 0 --use-oomkill-data "$@"
}

# ---- main ----

require docker kubectl
use_kubeconfig
assert_api

trap cleanup EXIT
copy_kubeconfig
start_port_forward
wait_for_port_forward
run_krr "$@"
