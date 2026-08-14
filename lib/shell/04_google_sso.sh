#!/usr/bin/env bash
# Writes the shared Google OAuth client-id into the central google-sso chart values and seals the client
# secret. Both come from .env, nothing is prompted, so a non-interactive re-run just rewrites and re-seals.
# WHICH hosts are gated, and by which allowlist, is that chart's domains[].hosts map, not this script.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
SSO_CHART="${PLATFORM_CHARTS}/04_google_sso"
SSO_VALUES="${SSO_CHART}/values.yaml"                               # oidc config + domains; clientID written here
SEALED_OUT="${SSO_CHART}/templates/google-oauth-sealedsecret.yaml"  # sealed client secret (committed)
CLIENT_SECRET_KEY="client-secret"   # the data key Envoy Gateway's OIDC clientSecret reads; not ours to choose

# ---- state ----
AUTH_SUBDOMAIN=""   # set by read_chart_config
SEAL_NAME=""
SEAL_NAMESPACE=""
DOMAIN=""
CLIENT_ID=""        # set by read_client_credentials
CLIENT_SECRET=""

# ---- functions ----

check_prerequisites() {
  say "prerequisites"
  require kubeseal kubectl yq
  use_kubeconfig
  [ -f "$SSO_VALUES" ] || die "missing ${SSO_VALUES} (the 04_google_sso chart should ship it)"
  assert_api
  assert_sealed_secrets_ready
  ok "kubeseal/kubectl/yq present, API + sealed-secrets controller reachable"
}

read_chart_config() {
  local v
  say "reading OIDC config + domain from ${SSO_VALUES}"
  AUTH_SUBDOMAIN="$(yq -r '.oidc.authSubdomain' "$SSO_VALUES" 2>/dev/null)"
  SEAL_NAME="$(yq -r '.oidc.clientSecretName' "$SSO_VALUES" 2>/dev/null)"
  SEAL_NAMESPACE="$(yq -r '.namespace' "$SSO_VALUES" 2>/dev/null)"
  DOMAIN="$(yq -r '.domain' "$SSO_VALUES" 2>/dev/null)"
  for v in AUTH_SUBDOMAIN:"$AUTH_SUBDOMAIN" SEAL_NAME:"$SEAL_NAME" SEAL_NAMESPACE:"$SEAL_NAMESPACE" DOMAIN:"$DOMAIN"; do
    [ -n "${v#*:}" ] && [ "${v#*:}" != "null" ] || die "couldn't read ${v%%:*} from ${SSO_VALUES}"
  done
  ok "domain: ${DOMAIN}  callback: ${AUTH_SUBDOMAIN}.${DOMAIN}  seal: ${SEAL_NAME}/${SEAL_NAMESPACE}"
}

print_oauth_client_setup() {
  say "Google OAuth client"
  echo "  In Google Cloud Console (https://console.cloud.google.com/apis/credentials):"
  echo "    1. OAuth consent screen: 'External', Published. Under 'Authorized domains' add the apex:"
  echo "         ${DOMAIN}"
  echo "    2. Credentials -> Create credentials -> 'OAuth client ID' -> type 'Web application'."
  echo "    3. Authorized redirect URIs -> add EXACTLY:"
  echo "         https://${AUTH_SUBDOMAIN}.${DOMAIN}/oauth2/callback"
  echo "    4. Create -> copy the Client ID (...apps.googleusercontent.com) and Client secret."
  echo "  No service account needed (that's only for Google Workspace *group* restriction)."
}

read_client_credentials() {
  say "reading the shared Google OAuth client credentials from .env"
  CLIENT_ID="$GOOGLE_SSO_CLIENT_ID"
  CLIENT_SECRET="$GOOGLE_SSO_CLIENT_SECRET"
  [ -n "$CLIENT_ID" ]     || die "GOOGLE_SSO_CLIENT_ID is empty in .env"
  [ -n "$CLIENT_SECRET" ] || die "GOOGLE_SSO_CLIENT_SECRET is empty in .env"
  case "$CLIENT_ID" in *.apps.googleusercontent.com) ;; *)
    warn "client id does not end in .apps.googleusercontent.com, double-check it" ;;
  esac
}

write_client_id() {
  say "writing clientID into ${SSO_VALUES}"
  ys_set "$SSO_VALUES" "\"${CLIENT_ID}\"" oidc clientID
  [ "$(yq -r '.oidc.clientID' "$SSO_VALUES")" = "$CLIENT_ID" ] && ok "oidc.clientID set" || bad "clientID not written"
}

# Strict scope binds the ciphertext to exactly ${SEAL_NAME}/${SEAL_NAMESPACE}, which every domain's
# SecurityPolicy references. No cookie secret is sealed: Envoy Gateway signs its own cookies.
seal_client_secret() {
  say "sealing client secret -> ${SEALED_OUT}"
  seal_secret "$SEAL_NAME" "$SEAL_NAMESPACE" "$SEALED_OUT" "${CLIENT_SECRET_KEY}=${CLIENT_SECRET}"
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Something failed, see above. Fix and re-run (idempotent)."
    return 0
  fi
cat <<EOF
Google SSO client wired for ${DOMAIN}. Register this redirect URI on the OAuth client:
  https://${AUTH_SUBDOMAIN}.${DOMAIN}/oauth2/callback

Next:
  - git add -A && git commit && git push   # ArgoCD unseals the secret + applies the callbacks/policies
  - for the callback host (${AUTH_SUBDOMAIN}.${DOMAIN}) AND each gated app host: point public DNS at your
    router + forward :80 to the Gateway IP so cert-manager's HTTP-01 issues.
  - test:  open https://sample-user-manager-sso.app.${DOMAIN}/  -> Google login; only the allowlist passes.
           (sample-user-manager.app.${DOMAIN} stays OPEN, not listed in google-sso.)
  - protect another host: add a \`subdomain\` under \`hosts\` in 04_google_sso/values.yaml. It must sit under
    \`domain\`, else the login cookie never reaches it and the host loops through Google forever.
  - change WHO may log in: set SSO_ALLOWLIST in .env and re-run \`make configure-values\`, commit, push.
  - re-run this script to rotate the client secret.
EOF
}

# ---- main ----

check_prerequisites
read_chart_config
print_oauth_client_setup
read_client_credentials
write_client_id
seal_client_secret

summary
print_result
[ "$FAIL" -eq 0 ]
