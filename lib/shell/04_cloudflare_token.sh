#!/usr/bin/env bash
# Seals the Cloudflare API token from .env into cert-manager, where the DNS-01 ClusterIssuer's
# apiTokenSecretRef resolves it. Split out of 04_values.sh because sealing needs the LIVE sealed-secrets
# controller, and 04_values runs before ArgoCD exists.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
GW_VALUES="${PLATFORM_CHARTS}/03_gateway/values.yaml"   # source for the Secret name + key
CM_CHART="${PLATFORM_CHARTS}/02_cert_manager"
SEALED_OUT="${CM_CHART}/templates/cloudflare-api-token-sealedsecret.yaml"    # sealed CF token (committed)
SEAL_NS="cert-manager"   # the ClusterIssuer dns01 apiTokenSecretRef resolves in cert-manager's ns

# ---- state ----
SEAL_NAME=""   # set by read_secret_ref
SEAL_KEY=""

# ---- functions ----

# An empty token means DNS-01 off. Drop any stale sealed file so a now-disabled deploy does not ship a
# dangling Secret ArgoCD would keep.
handle_disabled() {
  [ -n "${CLOUDFLARE_API_TOKEN_SECRET}" ] && return 0
  say "CLOUDFLARE_API_TOKEN_SECRET empty in .env -> DNS-01 disabled (HTTP-01 per-host for all)"
  if [ -f "$SEALED_OUT" ]; then
    rm -f "$SEALED_OUT" && ok "removed stale $(basename "$SEALED_OUT")" || bad "failed to remove ${SEALED_OUT}"
  else
    ok "no sealed token to clean up"
  fi
  summary
  exit 0
}

check_prerequisites() {
  say "prerequisites"
  require kubeseal kubectl yq
  use_kubeconfig
  [ -f "$GW_VALUES" ] || die "missing ${GW_VALUES} (the 03_gateway chart should ship it)"
  assert_api
  assert_sealed_secrets_ready
  ok "kubeseal/kubectl/yq present, API + sealed-secrets controller reachable"
}

# Read from the gateway values rather than hardcoded, so the issuer and this Secret always agree.
read_secret_ref() {
  say "reading the token Secret name + key from ${GW_VALUES}"
  SEAL_NAME="$(yq -r '.acme.cloudflare.apiTokenSecretName' "$GW_VALUES" 2>/dev/null)"
  SEAL_KEY="$(yq -r '.acme.cloudflare.apiTokenSecretKey' "$GW_VALUES" 2>/dev/null)"
  [ -n "$SEAL_NAME" ] && [ "$SEAL_NAME" != "null" ] || die "couldn't read .acme.cloudflare.apiTokenSecretName from ${GW_VALUES}"
  [ -n "$SEAL_KEY" ]  && [ "$SEAL_KEY" != "null" ]  || die "couldn't read .acme.cloudflare.apiTokenSecretKey from ${GW_VALUES}"
  ok "seal ${SEAL_NAME}/${SEAL_NS}, key ${SEAL_KEY}"
}

seal_token() {
  say "sealing Cloudflare API token -> ${SEALED_OUT}"
  seal_secret "$SEAL_NAME" "$SEAL_NS" "$SEALED_OUT" "${SEAL_KEY}=${CLOUDFLARE_API_TOKEN_SECRET}"
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Something failed, see above. Fix and re-run (idempotent)."
    return 0
  fi
cat <<EOF
Cloudflare token sealed -> ${SEALED_OUT#"${REPO_ROOT}/"}

Next:
  - git add -A && git commit && git push   # ArgoCD (02_cert_manager, wave 2) unseals it into cert-manager
  - the DNS-01 ClusterIssuer solver then authenticates to Cloudflare. Watch:
      kubectl -n gateway get certificate,secret | grep wildcard   # READY=True
      kubectl -n cert-manager get challenges                      # dns-01 for the CF zones
  - re-run this script to rotate the token.
EOF
}

# ---- main ----

handle_disabled
check_prerequisites
read_secret_ref
seal_token

summary
print_result
[ "$FAIL" -eq 0 ]
