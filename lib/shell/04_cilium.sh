#!/usr/bin/env bash
#
# 04_cilium.sh  (macOS)
#
# Installs Cilium as the CNI on the cluster brought up by step 03 (03d: cni: none,
# proxy: disabled). One-time imperative bootstrap, the chicken-and-egg breaker,
# since ArgoCD and everything else need pod networking to exist first.
#
# SINGLE SOURCE OF TRUTH is the wrapper chart at argo_apps/platform/charts/00_cilium/:
#   - Chart.yaml  pins the cilium chart version (dependency)
#   - values.yaml holds the Talos-flavoured cilium values + the loadBalancer gate
#   - templates/cilium-lb.yaml is the LB-IPAM pool + L2 policy
# This script just installs THAT chart; ArgoCD later adopts the same release. No
# versions, CRD lists, or values are defined here. See 04_networking.md.
#
# Brings up: WireGuard transparent encryption, kube-proxy replacement (via KubePrism),
# LB-IPAM + L2 announcements (replaces MetalLB), Hubble. (Cilium's gatewayAPI is OFF, the ingress
# data plane is Envoy Gateway; see 07_ingress.md.)
#
# Also installs the prometheus-operator CRDs FIRST (rendered from argo_apps/platform/charts/
# 00_prometheus_operator_crds): 00_cilium enables a ServiceMonitor, and cilium's chart hard-fails if
# the monitoring.coreos.com CRDs don't exist yet. ArgoCD's wave-0 CRD app adopts them later. See 09_monitoring.md.
#
# Uses NATIVE helm + kubectl (errors out if either is missing). Talks to the cluster
# via the kubeconfig step 03 (03d) wrote to secrets/kubeconfig.
#
# Idempotent: re-run safely (helm upgrade --install).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
CHART_DIR="${REPO_ROOT}/argo_apps/platform/charts/00_cilium"   # the wrapper chart (Argo consumes it too)
CRDS_CHART_DIR="${REPO_ROOT}/argo_apps/platform/charts/00_prometheus_operator_crds"  # monitoring CRDs (cilium's ServiceMonitor needs them)
RELEASE="cilium"
NS="kube-system"
API_WAIT=300                                       # secs to wait for the API to answer (the VIP lags the 03e reboot)
VALUES="${CHART_DIR}/values.yaml"
# LB-IPAM range (LB_RANGE_START/STOP) comes from .env via the lib; we write it into the chart's
# values.yaml below so ArgoCD renders the same pool.
# -----------------------------------------------------------------------------

# === 0. prereqs ==============================================================
say "prerequisites"
require kubectl helm yq
[ -f "${CHART_DIR}/Chart.yaml" ] || die "no chart at ${CHART_DIR} (expected argo_apps/platform/charts/00_cilium)"
[ -f "$VALUES" ] || die "missing ${VALUES}"
use_kubeconfig
ok "kubectl + helm + yq present, chart + values found"

# The API/VIP can take a minute or two to answer right after 03e (the NIC-hardening reboot), so
# PROBE instead of dying on the first miss. Poll every 5s up to API_WAIT, then give up with a clear
# message. Override the budget with API_WAIT=<secs>.
say "waiting for the Kubernetes API to answer (up to ${API_WAIT}s; the VIP lags the 03e reboot)"
deadline=$(( $(date +%s) + API_WAIT ))
until kubectl get nodes >/dev/null 2>&1; do
  [ "$(date +%s)" -lt "$deadline" ] \
    || die "API still unreachable via ${KUBECONFIG} after ${API_WAIT}s, is the cluster up? (run step 03, or wait longer after the 03e reboot, or raise API_WAIT)"
  printf '.'; sleep 5
done
echo
ok "Kubernetes API reachable"

# === 0b. write the LB-IPAM range from .env into the chart's values.yaml ===
# yq edits the chart's plain-YAML values (NOT the helm-templated cilium-lb.yaml, which references
# .Values.loadBalancer.ipPool). Committing values.yaml is what keeps ArgoCD's render in sync with
# this bootstrap. strenv() forces the IPs to stay quoted strings.
say "LB-IPAM range -> values.yaml (${LB_RANGE_START}-${LB_RANGE_STOP})"
if LB_RANGE_START="$LB_RANGE_START" LB_RANGE_STOP="$LB_RANGE_STOP" \
     yq -i '.loadBalancer.ipPool.start = strenv(LB_RANGE_START)
          | .loadBalancer.ipPool.stop  = strenv(LB_RANGE_STOP)' "$VALUES"; then
  ok "LB range written to values.yaml (commit this so ArgoCD renders the same pool)"
else
  bad "yq failed to write LB range into ${VALUES}"
fi

# === 0c. prometheus-operator CRDs (cilium's ServiceMonitor prerequisite) ======
# 00_cilium's values enable prometheus.serviceMonitor, and cilium's chart HARD-FAILS at template
# time if the monitoring.coreos.com CRDs are absent (validate.yaml), then couldn't apply the
# ServiceMonitor anyway (its template is value-gated, not capability-gated). On a fresh cluster
# nothing has installed those CRDs yet: ArgoCD's 00_prometheus_operator_crds app only lands at
# step 05. So install them HERE, first, rendered from that SAME pinned chart (no version in this
# script), server-side (the CRDs are huge), with NO helm release so ArgoCD's wave-0 app adopts them
# with no churn. Idempotent; --force-conflicts so a re-run after ArgoCD has adopted them still applies.
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

# === 1. resolve the cilium subchart ==========================================
say "helm dependency build (${CHART_DIR})"
helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null 2>&1 || helm repo update >/dev/null
# build wants an existing Chart.lock; update generates one. Try build, fall back to update.
if helm dependency build "$CHART_DIR" >/dev/null 2>&1 || helm dependency update "$CHART_DIR" >/dev/null 2>&1; then
  ok "cilium subchart vendored under charts/"
else
  bad "helm dependency build/update failed (see: helm dependency build ${CHART_DIR})"
fi

# === 2. install / upgrade ====================================================
# The CiliumLoadBalancerIPPool / L2 CRDs are registered by the cilium-operator at
# RUNTIME, not shipped by the chart, so on a FRESH cluster they don't exist when
# helm would apply the LB pool. Install with loadBalancer OFF first, let the operator
# come up (--wait), then re-apply with it ON. On a re-run (CRD already present) do it
# in one shot.
FRESH=0
kubectl get crd ciliumloadbalancerippools.cilium.io >/dev/null 2>&1 || FRESH=1
# Always pass loadBalancer.enabled EXPLICITLY: helm carries a release's previously-set values
# forward across upgrades, so a fresh run's "=false" would otherwise stick and the pool never
# renders. Fresh -> off first (CRD not registered yet); non-fresh -> straight on.
LB_FIRST=true; [ "$FRESH" -eq 1 ] && LB_FIRST=false

# --reset-values: recompute from the chart's values.yaml + our explicit --set on every upgrade.
# Without it, a value stored by a previous revision (e.g. the fresh-path "=false") carries forward
# and can win over the new --set, leaving the LB pool gated off. See 04_networking.md caveats.
say "helm upgrade --install ${RELEASE} (cilium)"
if helm upgrade --install "$RELEASE" "$CHART_DIR" --namespace "$NS" \
     --reset-values --set loadBalancer.enabled="$LB_FIRST" --wait --timeout 5m; then
  ok "cilium release applied"
else
  bad "helm install failed (see output above)"
fi

# === 3. wait for nodes Ready (they were NotReady until a CNI existed) =========
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

# === 4. enable the LB-IPAM pool + L2 policy (operator CRDs now registered) =====
if [ "$FRESH" -eq 1 ]; then
  say "helm upgrade ${RELEASE} (now with LB-IPAM pool + L2 policy)"
  helm upgrade --install "$RELEASE" "$CHART_DIR" --namespace "$NS" \
    --reset-values --set loadBalancer.enabled=true --wait --timeout 5m \
    && ok "LB pool + L2 policy applied" || bad "enabling LB pool failed"
fi

# === 5. verify ===============================================================
say "verify Cilium core"
kubectl -n "$NS" rollout status ds/cilium --timeout=120s >/dev/null 2>&1 \
  && ok "cilium agent DaemonSet rolled out" || bad "cilium DaemonSet not ready"
kubectl -n "$NS" rollout status deploy/cilium-operator --timeout=120s >/dev/null 2>&1 \
  && ok "cilium-operator ready" || bad "cilium-operator not ready"
# (No Gateway API CRD check here, Cilium's gatewayAPI is OFF; Envoy Gateway installs those later, see
# 07_ingress.md.)
# fully-qualified name + retry: the cilium.io CRDs may have only just been registered by the
# operator, so kubectl's API-discovery cache can lag a few seconds behind reality.
pool_ok=1
for _ in 1 2 3 4 5 6; do
  if kubectl get ciliumloadbalancerippools.cilium.io pool-default >/dev/null 2>&1; then pool_ok=0; break; fi
  kubectl api-resources >/dev/null 2>&1 || true   # nudge a discovery refresh
  sleep 5
done
[ "$pool_ok" -eq 0 ] && ok "LB-IPAM pool present" || bad "LB-IPAM pool missing"

# === 6. summary ==============================================================
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
