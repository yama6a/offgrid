#!/usr/bin/env bash
# Seals the Cloudflare API token from .env into cert-manager, for the DNS-01 ClusterIssuer's apiTokenSecretRef.
# Sealing needs the live sealed-secrets controller, and 04_values.sh runs before ArgoCD exists.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
GW_VALUES="${PLATFORM_CHARTS}/03_gateway/values.yaml" # holds the Secret name and key
CM_CHART="${PLATFORM_CHARTS}/02_cert_manager"
SEALED_OUT="${CM_CHART}/templates/cloudflare-api-token-sealedsecret.yaml" # the sealed token, committed
SEAL_NS="cert-manager"                                                    # a ClusterIssuer looks up its Secret here

# ---- state ----
SEAL_NAME="" # set by read_secret_ref
SEAL_KEY=""

# ---- functions ----

# An empty token turns DNS-01 off. The stale sealed file goes too, or ArgoCD keeps its Secret.
handle_disabled() {
  [ -n "${CLOUDFLARE_API_TOKEN_SECRET}" ] && return 0
  say "CLOUDFLARE_API_TOKEN_SECRET is empty in .env. DNS-01 is off, and every host uses HTTP-01."
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
  [ -f "$GW_VALUES" ] || die "missing ${GW_VALUES}. The 03_gateway chart ships it."
  assert_api
  assert_sealed_secrets_ready
  ok "kubeseal, kubectl and yq present. API and sealed-secrets controller reachable."
}

# The gateway values name the Secret, so the issuer and this Secret always agree.
read_secret_ref() {
  say "reading the token Secret name and key from ${GW_VALUES}"
  SEAL_NAME="$(yq -r '.acme.cloudflare.apiTokenSecretName' "$GW_VALUES" 2> /dev/null)"
  SEAL_KEY="$(yq -r '.acme.cloudflare.apiTokenSecretKey' "$GW_VALUES" 2> /dev/null)"
  [ -n "$SEAL_NAME" ] && [ "$SEAL_NAME" != "null" ] || die "could not read .acme.cloudflare.apiTokenSecretName from ${GW_VALUES}"
  [ -n "$SEAL_KEY" ] && [ "$SEAL_KEY" != "null" ] || die "could not read .acme.cloudflare.apiTokenSecretKey from ${GW_VALUES}"
  ok "seal ${SEAL_NAME}/${SEAL_NS}, key ${SEAL_KEY}"
}

seal_token() {
  say "sealing the Cloudflare API token into ${SEALED_OUT}"
  seal_secret "$SEAL_NAME" "$SEAL_NS" "$SEALED_OUT" "${SEAL_KEY}=${CLOUDFLARE_API_TOKEN_SECRET}"
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Something failed. See above. Fix it and run this script again."
    return 0
  fi
  cat << EOF
Cloudflare token sealed into ${SEALED_OUT#"${REPO_ROOT}/"}

Next:
  - git add -A && git commit && git push   # the wave-2 02_cert_manager app unseals it into cert-manager
  - the DNS-01 ClusterIssuer solver then logs in to Cloudflare. Watch:
      kubectl -n gateway get certificate,secret | grep wildcard   # expect READY=True
      kubectl -n cert-manager get challenges                      # dns-01 challenges for the Cloudflare zones
  - run this script again to rotate the token.
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
