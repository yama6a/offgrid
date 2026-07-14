#!/usr/bin/env bash
#
# krr.sh  (macOS)
#
# On-demand rightsizing: runs Robusta KRR (Kubernetes Resource Recommender) against the cluster and
# prints, per workload, the current CPU/memory requests next to what usage history says they SHOULD be.
# Ad-hoc inspection tool, not a numbered runbook step (like the DANGEROUS_* scripts it carries no NN_
# prefix); run it whenever you want to retune, read the numbers, then hand-edit the relevant chart values.
#
# Continuous *visualization* is already covered by Grafana (the k8s_views_pods dashboard, usage-vs-requests);
# KRR is the companion that answers "what number should I set". A weekly in-cluster CronJob + report store +
# Robusta UI would be overkill at 3-node homelab scale, so this stays on-demand. See docs/09_monitoring.md.
#
# KRR needs two things: the kube API (workload specs + current requests) via the 03d kubeconfig, and a
# Prometheus-API metrics source (usage history). Our metrics live in VictoriaMetrics' VMSingle, a ClusterIP
# with no external programmatic auth, so we reach it over the documented break-glass port-forward and point
# KRR at it. KRR itself runs DOCKERIZED (repo convention: tooling in Docker), like talosctl().
#
# Runs our custom `conservative` strategy (lib/krr/conservative.py): memory request = max(avg, 16Mi), limit =
# max(peak*1.2, 32Mi). It reads container_cpu_usage_seconds_total + container_memory_working_set_bytes (and,
# for the OOMKill floor, the KSM limit/last-terminated series) — all kept by vmagent's metricRelabelConfigs
# drop list (see 05_victoria_metrics_k8s_stack values). See docs/09_monitoring.md.

set -euo pipefail

# Reused in several places, so kept as locals; every other value is a one-shot constant inlined where used.
SVC="vmsingle-victoria-metrics-k8s-stack"   # the VMSingle PromQL API service in $MONITORING_NS
PORT=8428                                    # vmsingle's port; same on both sides of the forward
# renovate: datasource=docker
KRR_IMAGE="us-central1-docker.pkg.dev/genuine-flight-317411/devel/krr:v1.28.0"  # hoisted here so renovate tracks the pin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"             # common.sh is a sibling in lib/shell/

require docker kubectl
use_kubeconfig
assert_api

# The live kubeconfig is a symlink into an off-repo synced drive that Docker Desktop's file-sharing may not
# expose for bind-mounts; mount a plain temp COPY instead. Cleaned up (with the port-forward) on exit.
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

# Wait for the local listener to answer (bash /dev/tcp, no curl/nc dependency). port-forward opens it once
# the tunnel is established; give it a bounded window, then bail with a clear error rather than hang.
for _ in $(seq 1 30); do
  (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null && { exec 3>&- 3<&-; break; }
  kill -0 "$PF_PID" 2>/dev/null || die "port-forward to ${SVC} died (is the monitoring stack up?)"
  sleep 1
done
(exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null \
  || die "port-forward to ${SVC} never became ready on 127.0.0.1:${PORT}"
exec 3>&- 3<&-

# Bridge network (NOT --network host): on Docker Desktop/macOS a host-network container can't see the
# host-side port-forward, whereas the default bridge reaches it via host.docker.internal. The kube API VIP
# is a LAN IP reachable from the bridge via NAT. Pass "$@" through so extra KRR flags (e.g. -n <ns>) work.
# The image has no ENTRYPOINT (its Cmd is `python krr.py simple`), so passing args would REPLACE the whole
# command; invoke krr.py explicitly via --entrypoint python (WorkingDir is /app, where krr.py lives).
# The two extra -v mounts drop our custom strategy into the image's strategies package (conservative.py) and
# shadow its __init__.py so KRR's __subclasses__() discovery registers it — no image rebuild. See lib/krr/.
# --mem-min 0 disables KRR's single built-in memory floor (default 100Mi, applied to request AND limit alike)
# so the strategy owns the asymmetric floors; --use-oomkill-data bumps a workload's limit if it OOMKilled.
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
