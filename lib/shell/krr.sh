#!/usr/bin/env bash
# On-demand rightsizing: runs Robusta KRR against the cluster and prints, per workload, current CPU/memory
# requests next to what usage history says they should be. Read the numbers, then hand-edit the chart values.
# KRR needs the kube API and a Prometheus-API metrics source. Ours is VMSingle, a ClusterIP with no external
# programmatic auth, so we reach it over the documented break-glass port-forward.
# Runs our own `conservative` strategy from lib/krr/. The series it reads are all kept by vmagent's drop
# list, so check there before pruning more metrics.

set -euo pipefail

SVC="vmsingle-victoria-metrics-k8s-stack"   # the VMSingle PromQL API service in $MONITORING_NS
PORT=8428                                    # vmsingle's port; same on both sides of the forward
# renovate: datasource=docker
KRR_IMAGE="us-central1-docker.pkg.dev/genuine-flight-317411/devel/krr:v1.29.0"  # hoisted here so renovate tracks the pin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"             # common.sh is a sibling in lib/shell/

require docker kubectl
use_kubeconfig
assert_api

# Mount a temp copy, not $KUBECONFIG itself: it lives under the repo's .cache/, which Docker Desktop's file
# sharing may not expose for bind-mounts. A plain copy is enough because use_kubeconfig already pinned it to
# one context with the certs inlined, so it stands alone inside the container.
TMP_KUBECONFIG="$(mktemp -t krr-kubeconfig.XXXXXX)"
cp "$KUBECONFIG" "$TMP_KUBECONFIG"

PF_PID=""
cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  rm -f "$TMP_KUBECONFIG"
}
trap cleanup EXIT

say "port-forwarding svc/${SVC} (${MONITORING_NS}) -> 127.0.0.1:${PORT}"
kubectl -n "$MONITORING_NS" port-forward "svc/${SVC}" "${PORT}:${PORT}" >/dev/null 2>&1 &
PF_PID=$!

# Wait for the port-forward's listener, with a bounded window, rather than hanging.
for _ in $(seq 1 30); do
  (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null && { exec 3>&- 3<&-; break; }
  kill -0 "$PF_PID" 2>/dev/null || die "port-forward to ${SVC} died (is the monitoring stack up?)"
  sleep 1
done
(exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null \
  || die "port-forward to ${SVC} never became ready on 127.0.0.1:${PORT}"
exec 3>&- 3<&-

# Bridge network, NOT --network host: on Docker Desktop a host-network container cannot see the host-side
# port-forward, whereas the bridge reaches it via host.docker.internal.
# The image has no ENTRYPOINT, so passing args would REPLACE its whole command; hence --entrypoint python.
# The two extra -v mounts drop our strategy into the image's strategies package and replace its __init__.py
# with one that imports ours. KRR finds strategies by walking the subclasses of its base class, and a class
# only exists to be found once its module has been imported, so that import is what registers ours. No image
# rebuild needed.
# --mem-min 0 disables KRR's built-in memory floor, which applies to request AND limit alike, so the
# strategy owns the asymmetric floors instead.
say "running KRR (conservative) against http://host.docker.internal:${PORT}"
TTY=""; [ -t 1 ] && TTY="-t"
docker run --rm ${TTY} \
  -v "${TMP_KUBECONFIG}:/kubeconfig:ro" -e KUBECONFIG=/kubeconfig \
  -v "${REPO_ROOT}/lib/krr/conservative.py:/app/robusta_krr/strategies/conservative.py:ro" \
  -v "${REPO_ROOT}/lib/krr/strategies_init.py:/app/robusta_krr/strategies/__init__.py:ro" \
  --entrypoint python \
  "$KRR_IMAGE" krr.py conservative \
  -p "http://host.docker.internal:${PORT}" \
  --memory_request_min 16 --memory_limit_min 32 \
  --mem-min 0 --use-oomkill-data "$@"
