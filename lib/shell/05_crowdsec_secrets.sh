#!/usr/bin/env bash
# Generates and seals the CrowdSec LAPI secrets: the JWT signing key and the agent registration token.
# The chart would generate them with `lookup`, which Argo CD cannot run. A human supplies neither value.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
CS_VALUES="${PLATFORM_CHARTS}/03_crowdsec/values.yaml" # names the Secret and its keys
SEALED_OUT="${PLATFORM_CHARTS}/03_crowdsec/templates/crowdsec-lapi-secrets-sealedsecret.yaml"
SEAL_NS="crowdsec"

# ---- state ----
SEAL_NAME="" # set by read_secret_ref
JWT_KEY=""
TOKEN_KEY=""

# ---- functions ----

check_prerequisites() {
  say "prerequisites"
  require kubeseal kubectl yq openssl
  use_kubeconfig
  [ -f "$CS_VALUES" ] || die "missing ${CS_VALUES}. The 03_crowdsec chart ships it."
  assert_api
  assert_sealed_secrets_ready
  ok "kubeseal, kubectl, yq and openssl present. API and sealed-secrets controller reachable."
}

# The chart values name the Secret, so the pods and this Secret always agree.
read_secret_ref() {
  say "reading the Secret name and keys from ${CS_VALUES}"
  SEAL_NAME="$(yq -r '.crowdsec.secrets.externalSecret.name' "$CS_VALUES")"
  JWT_KEY="$(yq -r '.crowdsec.secrets.externalSecret.csLapiSecretKey' "$CS_VALUES")"
  TOKEN_KEY="$(yq -r '.crowdsec.secrets.externalSecret.registrationTokenKey' "$CS_VALUES")"
  for v in "$SEAL_NAME" "$JWT_KEY" "$TOKEN_KEY"; do
    [ -n "$v" ] && [ "$v" != "null" ] || die "could not read .crowdsec.secrets.externalSecret from ${CS_VALUES}"
  done
  ok "seal ${SEAL_NAME}/${SEAL_NS}, keys ${JWT_KEY} and ${TOKEN_KEY}"
}

# Every run generates new values. A fresh cluster cannot decrypt the old file. Nothing outside this Secret holds
# either value, so a rotation needs no other change.
seal_secrets() {
  say "sealing new LAPI secrets into ${SEALED_OUT#"${REPO_ROOT}/"}"
  seal_secret "$SEAL_NAME" "$SEAL_NS" "$SEALED_OUT" \
    "${JWT_KEY}=$(openssl rand -hex 32)" \
    "${TOKEN_KEY}=$(openssl rand -hex 24)"
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Something failed. See above. Fix it and run this script again."
    return 0
  fi
  cat << EOF

Next:
  - git add -A && git commit && git push   # the wave-3 crowdsec app unseals it
  - Watch: kubectl -n crowdsec get pods    # LAPI, then the agent, become Ready
  - Each run rotates both values. Reloader restarts LAPI and the agent, and the agent registers again.
EOF
}

# ---- main ----

check_prerequisites
read_secret_ref
seal_secrets

summary
print_result
[ "$FAIL" -eq 0 ]
