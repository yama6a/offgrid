#!/usr/bin/env bash
# Seals the Cloudflare API token from .env into cert-manager's namespace, where the DNS-01 ClusterIssuer's
# apiTokenSecretRef resolves it. The Secret name and data key are READ from 03_gateway/values.yaml, so the
# issuer and this Secret always agree.
# Split out of 07_gateway.sh because sealing needs the LIVE sealed-secrets controller, and 07_gateway runs
# before ArgoCD exists.
# Empty token means DNS-01 off: removes any stale sealed file and exits 0.
# Idempotent: re-run to rotate.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
GW_VALUES="${REPO_ROOT}/argo_apps/platform/charts/03_gateway/values.yaml"   # source for the Secret name + key
CM_CHART="${REPO_ROOT}/argo_apps/platform/charts/02_cert_manager"
SEALED_OUT="${CM_CHART}/templates/cloudflare-api-token-sealedsecret.yaml"    # sealed CF token (committed)
SEAL_NS="cert-manager"   # ClusterIssuer dns01 apiTokenSecretRef resolves in cert-manager's ns (cluster-resource ns)

if [ -z "${CLOUDFLARE_API_TOKEN_SECRET}" ]; then
  say "CLOUDFLARE_API_TOKEN_SECRET empty in .env -> DNS-01 disabled (HTTP-01 per-host for all)"
  # Drop any stale sealed token so a now-disabled deploy doesn't ship a dangling Secret ArgoCD would keep.
  if [ -f "$SEALED_OUT" ]; then
    rm -f "$SEALED_OUT" && ok "removed stale $(basename "$SEALED_OUT")" || bad "failed to remove ${SEALED_OUT}"
  else
    ok "no sealed token to clean up"
  fi
  summary
  exit 0
fi

say "prerequisites"
require kubeseal kubectl yq
use_kubeconfig
[ -f "$GW_VALUES" ] || die "missing ${GW_VALUES} (the 03_gateway chart should ship it)"
assert_api
kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" >/dev/null 2>&1 \
  || die "sealed-secrets controller not reachable in ns/${SS_CONTROLLER_NS}, is step 06 synced? (kubectl -n ${SS_CONTROLLER_NS} get pods)"
ok "kubeseal/kubectl/yq present, API + sealed-secrets controller reachable"

say "reading the token Secret name + key from ${GW_VALUES}"
SEAL_NAME="$(yq -r '.acme.cloudflare.apiTokenSecretName' "$GW_VALUES" 2>/dev/null)"
SEAL_KEY="$(yq -r '.acme.cloudflare.apiTokenSecretKey' "$GW_VALUES" 2>/dev/null)"
[ -n "$SEAL_NAME" ] && [ "$SEAL_NAME" != "null" ] || die "couldn't read .acme.cloudflare.apiTokenSecretName from ${GW_VALUES}"
[ -n "$SEAL_KEY" ]  && [ "$SEAL_KEY" != "null" ]  || die "couldn't read .acme.cloudflare.apiTokenSecretKey from ${GW_VALUES}"
ok "seal ${SEAL_NAME}/${SEAL_NS}, key ${SEAL_KEY}"

say "sealing Cloudflare API token -> ${SEALED_OUT}"
seal_secret "$SEAL_NAME" "$SEAL_NS" "$SEAL_KEY" "$CLOUDFLARE_API_TOKEN_SECRET" "$SEALED_OUT"

summary
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
Cloudflare token sealed -> ${SEALED_OUT#"${REPO_ROOT}/"}

Next:
  - git add -A && git commit && git push   # ArgoCD (02_cert_manager, wave 2) unseals it into cert-manager
  - the DNS-01 ClusterIssuer solver then authenticates to Cloudflare. Watch:
      kubectl -n gateway get certificate,secret | grep wildcard   # READY=True
      kubectl -n cert-manager get challenges                      # dns-01 for the CF zones
  - re-run this script to rotate the token.
EOF
else
  echo "Something failed, see above. Fix and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
