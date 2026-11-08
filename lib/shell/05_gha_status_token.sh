#!/usr/bin/env bash
# Seals the GitHub token from .env into the gha-status-exporter namespace, for the exporter's required secretKeyRef.
# Sealing needs the live sealed-secrets controller, and 04_values.sh runs before ArgoCD exists.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
GHS_VALUES="${PLATFORM_CHARTS}/05_gha_status_exporter/values.yaml" # holds the Secret name and key
GHS_CHART="${PLATFORM_CHARTS}/05_gha_status_exporter"
SEALED_OUT="${GHS_CHART}/templates/gha-status-exporter-token-sealedsecret.yaml" # the sealed token, committed
SEAL_NS="gha-status-exporter"                                                   # the Deployment reads its Secret here

# ---- state ----
SEAL_NAME="" # set by read_secret_ref
SEAL_KEY=""

# ---- functions ----

# An empty token seals nothing. The stale sealed file goes too, or ArgoCD keeps its Secret.
handle_disabled() {
  [ -n "${GHA_STATUS_TOKEN_SECRET}" ] && return 0
  say "GHA_STATUS_TOKEN_SECRET is empty in .env. No token is sealed."
  if [ -n "${GHA_STATUS_OWNER}" ]; then
    warn "GHA_STATUS_OWNER is set, so the exporter pod cannot start without the token."
  fi
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
  [ -f "$GHS_VALUES" ] || die "missing ${GHS_VALUES}. The 05_gha_status_exporter chart ships it."
  assert_api
  assert_sealed_secrets_ready
  ok "kubeseal, kubectl and yq present. API and sealed-secrets controller reachable."
}

# The chart values name the Secret, so the Deployment and this Secret always agree.
read_secret_ref() {
  say "reading the token Secret name and key from ${GHS_VALUES}"
  SEAL_NAME="$(yq -r '."gha-status-exporter".token.secretName' "$GHS_VALUES" 2> /dev/null)"
  SEAL_KEY="$(yq -r '."gha-status-exporter".token.secretKey' "$GHS_VALUES" 2> /dev/null)"
  [ -n "$SEAL_NAME" ] && [ "$SEAL_NAME" != "null" ] || die "could not read .gha-status-exporter.token.secretName from ${GHS_VALUES}"
  [ -n "$SEAL_KEY" ] && [ "$SEAL_KEY" != "null" ] || die "could not read .gha-status-exporter.token.secretKey from ${GHS_VALUES}"
  ok "seal ${SEAL_NAME}/${SEAL_NS}, key ${SEAL_KEY}"
}

seal_token() {
  say "sealing the GitHub token into ${SEALED_OUT}"
  seal_secret "$SEAL_NAME" "$SEAL_NS" "$SEALED_OUT" "${SEAL_KEY}=${GHA_STATUS_TOKEN_SECRET}"
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Something failed. See above. Fix it and run this script again."
    return 0
  fi
  cat << EOF
GitHub token sealed into ${SEALED_OUT#"${REPO_ROOT}/"}

Next:
  - git add -A && git commit && git push   # the wave-5 gha-status-exporter app unseals it into its namespace
  - Reloader restarts the exporter pod when the Secret changes. Watch:
      kubectl -n gha-status-exporter get pods   # expect 1/1 Running
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
