#!/usr/bin/env bash
# Installs Cilium as the CNI on the cluster from 03c. The one-time imperative bootstrap that breaks the
# chicken-and-egg: ArgoCD and everything else need pod networking to exist first. ArgoCD later adopts the
# same release from argo_apps/platform/charts/00_cilium, so no versions or values live here.
# Also installs the prometheus-operator CRDs FIRST: 00_cilium enables a ServiceMonitor and cilium's chart
# hard-fails at template time if the monitoring.coreos.com CRDs are absent.
# Idempotent: re-run safely.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
CHART_DIR="${REPO_ROOT}/argo_apps/platform/charts/00_cilium"   # the wrapper chart (Argo consumes it too)
CRDS_CHART_DIR="${REPO_ROOT}/argo_apps/platform/charts/00_prometheus_operator_crds"  # monitoring CRDs (cilium's ServiceMonitor needs them)
RELEASE="cilium"
NS="kube-system"
API_WAIT=300                                       # secs to wait for the API to answer (the VIP lags the 03d reboot)
VALUES="${CHART_DIR}/values.yaml"

say "prerequisites"
require kubectl helm yq
[ -f "${CHART_DIR}/Chart.yaml" ] || die "no chart at ${CHART_DIR} (expected argo_apps/platform/charts/00_cilium)"
[ -f "$VALUES" ] || die "missing ${VALUES}"
use_kubeconfig
ok "kubectl + helm + yq present, chart + values found"

# The VIP can take a minute or two to answer after the 03d reboot, so probe instead of dying on the first
# miss. Override the budget with API_WAIT=<secs>.
say "waiting for the Kubernetes API to answer (up to ${API_WAIT}s; the VIP lags the 03d reboot)"
deadline=$(( $(date +%s) + API_WAIT ))
until kubectl get nodes >/dev/null 2>&1; do
  [ "$(date +%s)" -lt "$deadline" ] \
    || die "API still unreachable via ${KUBECONFIG} after ${API_WAIT}s, is the cluster up? (run step 03, or wait longer after the 03d reboot, or raise API_WAIT)"
  printf '.'; sleep 5
done
echo
ok "Kubernetes API reachable"

# Edits the chart's plain-YAML values, NOT the helm-templated cilium-lb.yaml that references them.
# Committing values.yaml is what keeps ArgoCD's render in sync with this bootstrap.
# The IPs are written WITH their quotes: Cilium's CRD rejects an unquoted 192.168.100.10 as a non-string.
say "LB-IPAM range -> values.yaml (${LB_RANGE_START}-${LB_RANGE_STOP})"
ys_set "$VALUES" "\"${LB_RANGE_START}\"" loadBalancer ipPool start
ys_set "$VALUES" "\"${LB_RANGE_STOP}\""  loadBalancer ipPool stop
[ "$(yq -r '.loadBalancer.ipPool.start' "$VALUES")" = "$LB_RANGE_START" ] \
  && ok "ipPool.start=${LB_RANGE_START} (commit this so ArgoCD renders the same pool)" || bad "ipPool.start not written to ${VALUES}"
[ "$(yq -r '.loadBalancer.ipPool.stop' "$VALUES")" = "$LB_RANGE_STOP" ] \
  && ok "ipPool.stop=${LB_RANGE_STOP}" || bad "ipPool.stop not written to ${VALUES}"

# cilium's chart HARD-FAILS at template time if the monitoring.coreos.com CRDs are absent, and on a fresh
# cluster ArgoCD's CRD app only lands at step 05. So install them here first, rendered from that SAME pinned
# chart, with NO helm release, so ArgoCD's wave-0 app adopts them with no churn.
# --force-conflicts so a re-run after ArgoCD has adopted them still applies.
say "prometheus-operator CRDs (cilium ServiceMonitor prerequisite)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null 2>&1 || helm repo update >/dev/null
if helm dependency build "$CRDS_CHART_DIR" >/dev/null 2>&1 || helm dependency update "$CRDS_CHART_DIR" >/dev/null 2>&1; then
  if helm template prometheus-operator-crds "$CRDS_CHART_DIR" | kubectl apply --server-side --force-conflicts -f - >/dev/null 2>&1; then
    # wait for API discovery to register the new group/version, or cilium's render still won't see it.
    if kubectl wait --for=condition=established crd/servicemonitors.monitoring.coreos.com --timeout=60s >/dev/null 2>&1; then
      ok "monitoring.coreos.com CRDs applied + established (ServiceMonitor/Prometheus/...)"
    else
      bad "monitoring CRDs applied but not Established after 60s (cilium render may still fail)"
    fi
  else
    bad "failed to apply prometheus-operator CRDs (kubectl apply --server-side)"
  fi
else
  bad "helm dependency build/update failed for ${CRDS_CHART_DIR}"
fi

say "helm dependency build (${CHART_DIR})"
helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null 2>&1 || helm repo update >/dev/null
# build wants an existing Chart.lock; update generates one. Try build, fall back to update.
if helm dependency build "$CHART_DIR" >/dev/null 2>&1 || helm dependency update "$CHART_DIR" >/dev/null 2>&1; then
  ok "cilium subchart vendored under charts/"
else
  bad "helm dependency build/update failed (see: helm dependency build ${CHART_DIR})"
fi

# The LB-IPAM and L2 CRDs are registered by the cilium-operator at RUNTIME, not shipped by the chart, so on
# a FRESH cluster they do not exist when helm would apply the pool. Install with loadBalancer OFF, wait for
# the operator, then re-apply with it ON. On a re-run the CRD is already there, so do it in one shot.
FRESH=0
kubectl get crd ciliumloadbalancerippools.cilium.io >/dev/null 2>&1 || FRESH=1
# Always pass loadBalancer.enabled EXPLICITLY: helm carries a release's previously-set values forward, so a
# fresh run's "=false" would otherwise stick and the pool would never render.
LB_FIRST=true; [ "$FRESH" -eq 1 ] && LB_FIRST=false

# --reset-values recomputes from the chart on every upgrade. Without it, a value stored by a previous
# revision can win over the new --set and leave the LB pool gated off.
say "helm upgrade --install ${RELEASE} (cilium)"
if helm upgrade --install "$RELEASE" "$CHART_DIR" --namespace "$NS" \
     --reset-values --set loadBalancer.enabled="$LB_FIRST" --wait --timeout 5m; then
  ok "cilium release applied"
else
  bad "helm install failed (see output above)"
fi

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

if [ "$FRESH" -eq 1 ]; then
  say "helm upgrade ${RELEASE} (now with LB-IPAM pool + L2 policy)"
  helm upgrade --install "$RELEASE" "$CHART_DIR" --namespace "$NS" \
    --reset-values --set loadBalancer.enabled=true --wait --timeout 5m \
    && ok "LB pool + L2 policy applied" || bad "enabling LB pool failed"
fi

say "verify Cilium core"
kubectl -n "$NS" rollout status ds/cilium --timeout=120s >/dev/null 2>&1 \
  && ok "cilium agent DaemonSet rolled out" || bad "cilium DaemonSet not ready"
kubectl -n "$NS" rollout status deploy/cilium-operator --timeout=120s >/dev/null 2>&1 \
  && ok "cilium-operator ready" || bad "cilium-operator not ready"
# No Gateway API CRD check: Cilium's gatewayAPI is off, Envoy Gateway installs those later.
# Fully-qualified name plus retry, because kubectl's API-discovery cache can lag the operator's CRD
# registration by a few seconds.
pool_ok=1
for _ in 1 2 3 4 5 6; do
  if kubectl get ciliumloadbalancerippools.cilium.io pool-default >/dev/null 2>&1; then pool_ok=0; break; fi
  kubectl api-resources >/dev/null 2>&1 || true   # nudge a discovery refresh
  sleep 5
done
[ "$pool_ok" -eq 0 ] && ok "LB-IPAM pool present" || bad "LB-IPAM pool missing"

summary
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
Cilium is the CNI. Encryption (WireGuard), LB-IPAM/L2, Hubble are live. (Gateway API is Envoy Gateway, not Cilium.)
Single source of truth: argo_apps/platform/charts/00_cilium/ (Chart.yaml + values.yaml + templates/).

Next:
  - smoke-test a LoadBalancer:  kubectl create deploy nginx --image=nginx
                                kubectl expose deploy nginx --type=LoadBalancer --port=80
                                kubectl get svc nginx   # EXTERNAL-IP from your pool
EOF
else
  echo "Some checks failed. If helm timed out, re-run (idempotent). If nodes stayed NotReady,"
  echo "confirm cni:none + proxy:disabled landed (preflight) and KubePrism answers on :7445."
fi
[ "$FAIL" -eq 0 ]
