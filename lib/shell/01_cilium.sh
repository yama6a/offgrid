#!/usr/bin/env bash
# Installs Cilium as the CNI. It runs before ArgoCD because ArgoCD needs pod networking to start.
# ArgoCD later adopts the same release from argo_apps/platform/charts/00_cilium, so no versions or values live here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
CHART_DIR="${PLATFORM_CHARTS}/00_cilium"                        # the wrapper chart, which Argo CD also syncs
CRDS_CHART_DIR="${PLATFORM_CHARTS}/00_prometheus_operator_crds" # monitoring CRDs that the Cilium ServiceMonitor needs
RELEASE="cilium"
NS="kube-system"
API_WAIT=300 # seconds to wait for the API after a node-level change
VALUES="${CHART_DIR}/values.yaml"

# ---- state ----
FRESH=0 # 1 when the LB-IPAM CRDs do not exist yet

# ---- functions ----

check_prerequisites() {
  say "prerequisites"
  require kubectl helm yq
  [ -f "${CHART_DIR}/Chart.yaml" ] || die "no chart at ${CHART_DIR} (expected argo_apps/platform/charts/00_cilium)"
  [ -f "$VALUES" ] || die "missing ${VALUES}"
  use_kubeconfig
  ok "kubectl, helm and yq present, chart and values found"
}

wait_for_api() {
  local deadline
  say "waiting for the Kubernetes API to answer (up to ${API_WAIT}s)"
  deadline=$(($(date +%s) + API_WAIT))
  until kubectl get nodes > /dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] \
      || die "API still unreachable via ${KUBECONFIG} after ${API_WAIT}s. Is the cluster up and is KUBE_CONTEXT pointing at it? If a node-level change just landed, give it longer or raise API_WAIT."
    printf '.'
    sleep 5
  done
  echo
  ok "Kubernetes API reachable"
}

# Commit values.yaml afterwards, so ArgoCD renders the same pool as this bootstrap.
# The quotes are part of the value. The Cilium CRD rejects an unquoted 192.168.100.10 as a non-string.
write_lb_range() {
  say "writing the LB-IPAM range to values.yaml (${LB_RANGE_START}-${LB_RANGE_STOP})"
  ys_set "$VALUES" "\"${LB_RANGE_START}\"" loadBalancer ipPool start
  ys_set "$VALUES" "\"${LB_RANGE_STOP}\"" loadBalancer ipPool stop
  [ "$(yq -r '.loadBalancer.ipPool.start' "$VALUES")" = "$LB_RANGE_START" ] \
    && ok "ipPool.start=${LB_RANGE_START} (commit this so ArgoCD renders the same pool)" || bad "ipPool.start not written to ${VALUES}"
  [ "$(yq -r '.loadBalancer.ipPool.stop' "$VALUES")" = "$LB_RANGE_STOP" ] \
    && ok "ipPool.stop=${LB_RANGE_STOP}" || bad "ipPool.stop not written to ${VALUES}"
}

# The Cilium chart fails at template time without the monitoring.coreos.com CRDs, and ArgoCD is not installed yet.
# No helm release, so the wave-0 ArgoCD app adopts the CRDs with no churn. --force-conflicts lets a re-run apply.
install_monitoring_crds() {
  say "prometheus-operator CRDs, needed by the Cilium ServiceMonitor"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts > /dev/null 2>&1 || true
  helm repo update prometheus-community > /dev/null 2>&1 || helm repo update > /dev/null
  if ! helm dependency build "$CRDS_CHART_DIR" > /dev/null 2>&1 && ! helm dependency update "$CRDS_CHART_DIR" > /dev/null 2>&1; then
    bad "helm dependency build/update failed for ${CRDS_CHART_DIR}"
    return 0
  fi
  pin_chart_lock_timestamp "$CRDS_CHART_DIR"
  if ! helm template prometheus-operator-crds "$CRDS_CHART_DIR" | kubectl apply --server-side --force-conflicts -f - > /dev/null 2>&1; then
    bad "failed to apply prometheus-operator CRDs (kubectl apply --server-side)"
    return 0
  fi
  # The Cilium render fails until API discovery registers the new group and version.
  if kubectl wait --for=condition=established crd/servicemonitors.monitoring.coreos.com --timeout=60s > /dev/null 2>&1; then
    ok "monitoring.coreos.com CRDs applied and established"
  else
    bad "monitoring CRDs applied but not Established after 60s. The Cilium render can still fail."
  fi
}

vendor_cilium_subchart() {
  say "helm dependency build (${CHART_DIR})"
  helm repo add cilium https://helm.cilium.io > /dev/null 2>&1 || true
  helm repo update cilium > /dev/null 2>&1 || helm repo update > /dev/null
  # build needs an existing Chart.lock. update generates one.
  if helm dependency build "$CHART_DIR" > /dev/null 2>&1 || helm dependency update "$CHART_DIR" > /dev/null 2>&1; then
    pin_chart_lock_timestamp "$CHART_DIR"
    ok "Cilium subchart vendored under charts/"
  else
    bad "helm dependency build and update failed. Run: helm dependency build ${CHART_DIR}"
  fi
}

# The cilium-operator registers the LB-IPAM and L2 CRDs at runtime. The chart does not ship them.
detect_fresh_cluster() {
  kubectl get crd ciliumloadbalancerippools.cilium.io > /dev/null 2>&1 || FRESH=1
  return 0
}

# Helm carries set values forward, so a fresh run's loadBalancer.enabled=false would stick without --reset-values.
install_cilium() {
  local lb_first=true
  [ "$FRESH" -eq 1 ] && lb_first=false
  say "helm upgrade --install ${RELEASE}"
  if helm upgrade --install "$RELEASE" "$CHART_DIR" --namespace "$NS" \
    --reset-values --set loadBalancer.enabled="$lb_first" --wait --timeout 5m; then
    ok "Cilium release applied"
  else
    bad "helm install failed. See the output above."
  fi
}

wait_for_nodes_ready() {
  local deadline
  say "waiting for nodes Ready"
  deadline=$(($(date +%s) + 180))
  while :; do
    if kubectl get nodes --no-headers 2> /dev/null | awk '$2!="Ready"{f=1} END{exit f}'; then
      ok "all nodes Ready"
      break
    fi
    [ "$(date +%s)" -lt "$deadline" ] || {
      bad "nodes still NotReady after 180s"
      break
    }
    printf '.'
    sleep 5
  done
  echo
  kubectl get nodes -o wide 2> /dev/null | sed 's/^/   /'
}

# On a fresh cluster the operator has registered the LB-IPAM CRDs by now, so the pool can render.
enable_lb_pool() {
  [ "$FRESH" -eq 1 ] || return 0
  say "helm upgrade ${RELEASE} with the LB-IPAM pool and L2 policy"
  helm upgrade --install "$RELEASE" "$CHART_DIR" --namespace "$NS" \
    --reset-values --set loadBalancer.enabled=true --wait --timeout 5m \
    && ok "LB pool and L2 policy applied" || bad "enabling LB pool failed"
}

# The kubectl discovery cache can lag the operator's CRD registration by a few seconds, so the pool lookup retries.
verify_cilium() {
  local pool_ok=1 _
  say "verify Cilium core"
  kubectl -n "$NS" rollout status ds/cilium --timeout=120s > /dev/null 2>&1 \
    && ok "Cilium agent DaemonSet rolled out" || bad "Cilium DaemonSet not ready"
  kubectl -n "$NS" rollout status deploy/cilium-operator --timeout=120s > /dev/null 2>&1 \
    && ok "cilium-operator ready" || bad "cilium-operator not ready"
  for _ in 1 2 3 4 5 6; do
    if kubectl get ciliumloadbalancerippools.cilium.io pool-default > /dev/null 2>&1; then
      pool_ok=0
      break
    fi
    kubectl api-resources > /dev/null 2>&1 || true
    sleep 5
  done
  [ "$pool_ok" -eq 0 ] && ok "LB-IPAM pool present" || bad "LB-IPAM pool missing"
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Some checks failed. If helm timed out, run this script again."
    echo "If nodes stayed NotReady, confirm that the node config sets cni: none and proxy: disabled."
    echo "Also confirm that KubePrism answers on :7445."
    return 0
  fi
  cat << EOF
Cilium is the CNI. WireGuard encryption, LB-IPAM, L2 announcements and Hubble are live.
All Cilium config lives in argo_apps/platform/charts/00_cilium/.

Next:
  - test a LoadBalancer:  kubectl create deploy nginx --image=nginx
                          kubectl expose deploy nginx --type=LoadBalancer --port=80
                          kubectl get svc nginx   # EXTERNAL-IP comes from your pool
EOF
}

# ---- main ----

check_prerequisites
wait_for_api
write_lb_range
install_monitoring_crds
vendor_cilium_subchart
detect_fresh_cluster
install_cilium
wait_for_nodes_ready
enable_lb_pool
verify_cilium

summary
print_result
[ "$FAIL" -eq 0 ]
