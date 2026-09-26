#!/usr/bin/env bash
# Runs Robusta KRR and prints the CPU and memory requests of each workload next to the values its usage suggests.
# Read the numbers, then edit the chart values by hand. Extra arguments go to KRR.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
SVC="vmsingle-victoria-metrics-k8s-stack" # the VMSingle PromQL API service in $MONITORING_NS
PORT=8428                                 # the vmsingle port, the same on both sides of the forward
# renovate: datasource=docker
KRR_IMAGE="us-central1-docker.pkg.dev/genuine-flight-317411/devel/krr:v1.30.0"

# ---- state ----
TMP_KUBECONFIG="" # set by copy_kubeconfig, removed by cleanup
PF_PID=""         # set by start_port_forward, killed by cleanup

# ---- functions ----

cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2> /dev/null || true
  rm -f "$TMP_KUBECONFIG"
}

# Docker Desktop file sharing may not expose .cache/kubeconfig for a bind mount, so this mounts a copy.
# The copy works alone in the container, because use_kubeconfig pinned one context and inlined the certs.
copy_kubeconfig() {
  TMP_KUBECONFIG="$(mktemp -p "${REPO_ROOT}/.cache" krr-kubeconfig.XXXXXX)"
  cp "$KUBECONFIG" "$TMP_KUBECONFIG"
}

# VMSingle is a ClusterIP service with no external auth, so KRR reaches it over a port-forward.
start_port_forward() {
  say "port-forwarding svc/${SVC} (${MONITORING_NS}) to 127.0.0.1:${PORT}"
  kubectl -n "$MONITORING_NS" port-forward "svc/${SVC}" "${PORT}:${PORT}" > /dev/null 2>&1 &
  PF_PID=$!
}

wait_for_port_forward() {
  local _
  for _ in $(seq 1 30); do
    (exec 3<> "/dev/tcp/127.0.0.1/${PORT}") 2> /dev/null && {
      exec 3>&- 3<&-
      break
    }
    kill -0 "$PF_PID" 2> /dev/null || die "port-forward to ${SVC} died. Check that the monitoring stack is up."
    sleep 1
  done
  (exec 3<> "/dev/tcp/127.0.0.1/${PORT}") 2> /dev/null \
    || die "port-forward to ${SVC} never became ready on 127.0.0.1:${PORT}"
  exec 3>&- 3<&-
}

# Uses the bridge network. On Docker Desktop only the bridge reaches the host port-forward, via host.docker.internal.
# The image has no ENTRYPOINT, so arguments would replace its whole command. Hence --entrypoint python.
# KRR finds a strategy only after its module is imported. So the mounts add `conservative` and an __init__.py
# that imports it.
# The vmagent drop list keeps every series this strategy reads. Keep them when you prune metrics.
# --mem-min 0 turns off the KRR memory floor, which applies to request and limit alike.
# The strategy sets separate floors for each instead.
run_krr() {
  local tty="" arg
  # A scan of all namespaces skips kube-system, which hides Cilium. A match-all regex scans every namespace.
  # A -n from the caller replaces it.
  local ns_args=(--namespace '.*')
  for arg in "$@"; do
    case "$arg" in -n | --namespace | --namespace=*) ns_args=() ;; esac
  done
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
    --mem-min 0 --use-oomkill-data "${ns_args[@]}" "$@"
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
