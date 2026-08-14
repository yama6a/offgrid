#!/usr/bin/env bash
# Installs Cilium as the CNI on the cluster the OS repo built: the one imperative bootstrap that breaks the
# chicken-and-egg, since ArgoCD and everything else need pod networking first. ArgoCD later adopts the same
# release from argo_apps/platform/charts/00_cilium, so no versions or values live here.
# Idempotent: re-run safely.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
CHART_DIR="${PLATFORM_CHARTS}/00_cilium"                         # the wrapper chart (Argo consumes it too)
CRDS_CHART_DIR="${PLATFORM_CHARTS}/00_prometheus_operator_crds"  # monitoring CRDs (cilium's ServiceMonitor needs them)
RELEASE="cilium"
NS="kube-system"
API_WAIT=300                                       # secs; the VIP lags the OS repo's NIC-hardening reboot
VALUES="${CHART_DIR}/values.yaml"

# ---- state ----
FRESH=0        # set by detect_fresh_cluster, read by install_cilium + enable_lb_pool

# ---- functions ----

check_prerequisites() {
  say "prerequisites"
  require kubectl helm yq
  [ -f "${CHART_DIR}/Chart.yaml" ] || die "no chart at ${CHART_DIR} (expected argo_apps/platform/charts/00_cilium)"
  [ -f "$VALUES" ] || die "missing ${VALUES}"
  use_kubeconfig
  ok "kubectl + helm + yq present, chart + values found"
}

# The VIP can take a minute or two to answer after the OS repo's NIC-hardening reboot, so probe instead of
# dying on the first miss. Override the budget with API_WAIT=<secs>.
wait_for_api() {
  local deadline
  say "waiting for the Kubernetes API to answer (up to ${API_WAIT}s; the VIP lags the OS repo's NIC-hardening reboot)"
  deadline=$(( $(date +%s) + API_WAIT ))
  until kubectl get nodes >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] \
      || die "API still unreachable via ${KUBECONFIG} after ${API_WAIT}s, is the cluster up? (build it in the OS repo, or wait longer after its NIC-hardening reboot, or raise API_WAIT)"
    printf '.'; sleep 5
  done
  echo
  ok "Kubernetes API reachable"
}

# Edits the chart's plain-YAML values, NOT the helm-templated cilium-lb.yaml that references them. Committing
# values.yaml is what keeps ArgoCD's render in sync with this bootstrap.
# The IPs are written WITH their quotes: Cilium's CRD rejects an unquoted 192.168.100.10 as a non-string.
write_lb_range() {
  say "LB-IPAM range -> values.yaml (${LB_RANGE_START}-${LB_RANGE_STOP})"
  ys_set "$VALUES" "\"${LB_RANGE_START}\"" loadBalancer ipPool start
  ys_set "$VALUES" "\"${LB_RANGE_STOP}\""  loadBalancer ipPool stop
  [ "$(yq -r '.loadBalancer.ipPool.start' "$VALUES")" = "$LB_RANGE_START" ] \
    && ok "ipPool.start=${LB_RANGE_START} (commit this so ArgoCD renders the same pool)" || bad "ipPool.start not written to ${VALUES}"
  [ "$(yq -r '.loadBalancer.ipPool.stop' "$VALUES")" = "$LB_RANGE_STOP" ] \
    && ok "ipPool.stop=${LB_RANGE_STOP}" || bad "ipPool.stop not written to ${VALUES}"
}

# cilium's chart HARD-FAILS at template time if the monitoring.coreos.com CRDs are absent, and on a fresh
# cluster ArgoCD's CRD app only lands at step 05. Rendered from that SAME pinned chart with NO helm release,
# so ArgoCD's wave-0 app adopts them with no churn. --force-conflicts so a re-run after that adoption applies.
install_monitoring_crds() {
  say "prometheus-operator CRDs (cilium ServiceMonitor prerequisite)"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update prometheus-community >/dev/null 2>&1 || helm repo update >/dev/null
  if ! helm dependency build "$CRDS_CHART_DIR" >/dev/null 2>&1 && ! helm dependency update "$CRDS_CHART_DIR" >/dev/null 2>&1; then
    bad "helm dependency build/update failed for ${CRDS_CHART_DIR}"
    return 0
  fi
  if ! helm template prometheus-operator-crds "$CRDS_CHART_DIR" | kubectl apply --server-side --force-conflicts -f - >/dev/null 2>&1; then
    bad "failed to apply prometheus-operator CRDs (kubectl apply --server-side)"
    return 0
  fi
  # Wait for API discovery to register the new group/version, or cilium's render still won't see it.
  if kubectl wait --for=condition=established crd/servicemonitors.monitoring.coreos.com --timeout=60s >/dev/null 2>&1; then
    ok "monitoring.coreos.com CRDs applied + established (ServiceMonitor/Prometheus/...)"
  else
    bad "monitoring CRDs applied but not Established after 60s (cilium render may still fail)"
  fi
}

vendor_cilium_subchart() {
  say "helm dependency build (${CHART_DIR})"
  helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
  helm repo update cilium >/dev/null 2>&1 || helm repo update >/dev/null
  # build wants an existing Chart.lock; update generates one. Try build, fall back to update.
  if helm dependency build "$CHART_DIR" >/dev/null 2>&1 || helm dependency update "$CHART_DIR" >/dev/null 2>&1; then
    ok "cilium subchart vendored under charts/"
  else
    bad "helm dependency build/update failed (see: helm dependency build ${CHART_DIR})"
  fi
}

# The LB-IPAM and L2 CRDs are registered by the cilium-operator at RUNTIME, not shipped by the chart, so on a
# FRESH cluster they do not exist when helm would apply the pool.
detect_fresh_cluster() {
  kubectl get crd ciliumloadbalancerippools.cilium.io >/dev/null 2>&1 || FRESH=1
  return 0
}

# loadBalancer.enabled is always passed EXPLICITLY: helm carries a release's previously-set values forward, so
# a fresh run's "=false" would otherwise stick and the pool would never render.
# --reset-values recomputes from the chart on every upgrade; without it a value stored by a previous revision
# can win over the new --set and leave the LB pool gated off.
install_cilium() {
  local lb_first=true
  [ "$FRESH" -eq 1 ] && lb_first=false
  say "helm upgrade --install ${RELEASE} (cilium)"
  if helm upgrade --install "$RELEASE" "$CHART_DIR" --namespace "$NS" \
       --reset-values --set loadBalancer.enabled="$lb_first" --wait --timeout 5m; then
    ok "cilium release applied"
  else
    bad "helm install failed (see output above)"
  fi
}

wait_for_nodes_ready() {
  local deadline
  say "waiting for nodes Ready"
  deadline=$(( $(date +%s) + 180 ))
  while :; do
    # awk exits 0 only when every node's STATUS column is exactly "Ready"
    if kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{f=1} END{exit f}'; then
      ok "all nodes Ready"; break
    fi
    [ "$(date +%s)" -lt "$deadline" ] || { bad "nodes still NotReady after 180s"; break; }
    printf '.'; sleep 5
  done
  echo
  kubectl get nodes -o wide 2>/dev/null | sed 's/^/   /'
}

# Second pass, only on a fresh cluster: the operator has registered the CRDs by now, so the pool can render.
enable_lb_pool() {
  [ "$FRESH" -eq 1 ] || return 0
  say "helm upgrade ${RELEASE} (now with LB-IPAM pool + L2 policy)"
  helm upgrade --install "$RELEASE" "$CHART_DIR" --namespace "$NS" \
    --reset-values --set loadBalancer.enabled=true --wait --timeout 5m \
    && ok "LB pool + L2 policy applied" || bad "enabling LB pool failed"
}

# No Gateway API CRD check: Cilium's gatewayAPI is off, Envoy Gateway installs those later.
# The pool lookup is fully-qualified and retried, because kubectl's API-discovery cache can lag the operator's
# CRD registration by a few seconds.
verify_cilium() {
  local pool_ok=1 _
  say "verify Cilium core"
  kubectl -n "$NS" rollout status ds/cilium --timeout=120s >/dev/null 2>&1 \
    && ok "cilium agent DaemonSet rolled out" || bad "cilium DaemonSet not ready"
  kubectl -n "$NS" rollout status deploy/cilium-operator --timeout=120s >/dev/null 2>&1 \
    && ok "cilium-operator ready" || bad "cilium-operator not ready"
  for _ in 1 2 3 4 5 6; do
    if kubectl get ciliumloadbalancerippools.cilium.io pool-default >/dev/null 2>&1; then pool_ok=0; break; fi
    kubectl api-resources >/dev/null 2>&1 || true   # nudge a discovery refresh
    sleep 5
  done
  [ "$pool_ok" -eq 0 ] && ok "LB-IPAM pool present" || bad "LB-IPAM pool missing"
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Some checks failed. If helm timed out, re-run (idempotent). If nodes stayed NotReady,"
    echo "confirm cni:none + proxy:disabled landed (preflight) and KubePrism answers on :7445."
    return 0
  fi
cat <<EOF
Cilium is the CNI. Encryption (WireGuard), LB-IPAM/L2, Hubble are live. (Gateway API is Envoy Gateway, not Cilium.)
Single source of truth: argo_apps/platform/charts/00_cilium/ (Chart.yaml + values.yaml + templates/).

Next:
  - smoke-test a LoadBalancer:  kubectl create deploy nginx --image=nginx
                                kubectl expose deploy nginx --type=LoadBalancer --port=80
                                kubectl get svc nginx   # EXTERNAL-IP from your pool
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
