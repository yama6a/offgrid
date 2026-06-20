#!/usr/bin/env bash
#
# 04_cilium.sh  (macOS)
#
# Installs Cilium as the CNI on the cluster brought up by step 03 (03d: cni: none,
# proxy: disabled). One-time imperative bootstrap — the chicken-and-egg breaker,
# since ArgoCD and everything else need pod networking to exist first.
#
# SINGLE SOURCE OF TRUTH is the wrapper chart at argo_apps/charts/01_cilium/:
#   - Chart.yaml  pins the cilium chart version (dependency)
#   - values.yaml holds the Talos-flavoured cilium values + the loadBalancer gate
#   - crds/       vendors the Gateway API CRDs (v1.4.1)
#   - templates/cilium-lb.yaml is the LB-IPAM pool + L2 policy
# This script just installs THAT chart; ArgoCD later adopts the same release. No
# versions, CRD lists, or values are defined here. See 04_networking.md.
#
# Brings up: WireGuard transparent encryption, kube-proxy replacement (via KubePrism),
# LB-IPAM + L2 announcements (replaces MetalLB), Gateway API, Hubble.
#
# Uses NATIVE helm + kubectl (errors out if either is missing). Talks to the cluster
# via the kubeconfig step 03 (03d) wrote to 03_operating_system/talos-cluster/kubeconfig.
#
# Idempotent: re-run safely (helm upgrade --install).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- knobs ------------------------------------------------------------------
OUTDIR="${OUTDIR:-${SCRIPT_DIR}/../03_operating_system/talos-cluster}"  # talosconfig + kubeconfig (from 03d)
CHART_DIR="${CHART_DIR:-${SCRIPT_DIR}/../argo_apps/charts/01_cilium}"   # the wrapper chart (Argo consumes it too)
RELEASE="cilium"
NS="kube-system"
export KUBECONFIG="${OUTDIR}/kubeconfig"          # the 03d kubeconfig (points at the VIP)
# -----------------------------------------------------------------------------

say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
PASS=0; FAIL=0
ok()  { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# === 0. prereqs ==============================================================
say "prerequisites"
command -v kubectl >/dev/null || die "kubectl not found on PATH — install it (https://kubernetes.io/docs/tasks/tools/)"
command -v helm    >/dev/null || die "helm not found on PATH — install it (https://helm.sh/docs/intro/install/)"
[ -f "${CHART_DIR}/Chart.yaml" ] || die "no chart at ${CHART_DIR} (expected argo_apps/charts/01_cilium)"
[ -f "$KUBECONFIG" ] || die "missing ${KUBECONFIG} — run step 03 (03d) first"
kubectl get nodes >/dev/null 2>&1 || die "kubectl can't reach the API via ${KUBECONFIG}"
ok "kubectl + helm present, API reachable, chart found"

# === 1. resolve the cilium subchart (Gateway API CRDs ride along in crds/) ====
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
# RUNTIME, not shipped by the chart — so on a FRESH cluster they don't exist when
# helm would apply the LB pool. Install with loadBalancer OFF first, let the operator
# come up (--wait), then re-apply with it ON. On a re-run (CRD already present) do it
# in one shot. Gateway API CRDs come from the chart's crds/ on first install.
FRESH=0
kubectl get crd ciliumloadbalancerippools.cilium.io >/dev/null 2>&1 || FRESH=1
# Always pass loadBalancer.enabled EXPLICITLY: helm carries a release's previously-set values
# forward across upgrades, so a fresh run's "=false" would otherwise stick and the pool never
# renders. Fresh -> off first (CRD not registered yet); non-fresh -> straight on.
LB_FIRST=true; [ "$FRESH" -eq 1 ] && LB_FIRST=false

# --reset-values: recompute from the chart's values.yaml + our explicit --set on every upgrade.
# Without it, a value stored by a previous revision (e.g. the fresh-path "=false") carries forward
# and can win over the new --set, leaving the LB pool gated off. See 04_networking.md caveats.
say "helm upgrade --install ${RELEASE} (cilium + Gateway API CRDs)"
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
kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 \
  && ok "Gateway API CRDs present" || bad "Gateway API CRDs missing"
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
echo ""
echo "=============== summary: ${PASS} passed, ${FAIL} failed ==============="
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
Cilium is the CNI. Encryption (WireGuard), LB-IPAM/L2, Gateway API, Hubble are live.
Single source of truth: argo_apps/charts/01_cilium/ (Chart.yaml + values.yaml + crds/ + templates/).

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
