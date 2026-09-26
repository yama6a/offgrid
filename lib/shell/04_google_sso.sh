#!/usr/bin/env bash
# Writes the shared Google OAuth client ID into the google-sso chart values and seals the client secret.
# Both come from .env. The chart's `hosts` and `extraDomains[].hosts` decide which hosts SSO protects.
# A new domain needs no new seal, because the Secret is sealed to a name and namespace only.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
SSO_CHART="${PLATFORM_CHARTS}/04_google_sso"
SSO_VALUES="${SSO_CHART}/values.yaml"                              # OIDC config and domains. Gets the clientID.
SEALED_OUT="${SSO_CHART}/templates/google-oauth-sealedsecret.yaml" # the sealed client secret, committed
CLIENT_SECRET_KEY="client-secret"                                  # the key name Envoy Gateway requires

# ---- state ----
AUTH_SUBDOMAIN="" # set by read_chart_config
SEAL_NAME=""
SEAL_NAMESPACE=""
DOMAINS=""   # the base domain and every extraDomains entry, space-separated
CLIENT_ID="" # set by read_client_credentials
CLIENT_SECRET=""

# ---- functions ----

# Separate from check_prerequisites, so the Console checklist prints without a cluster.
check_values_readable() {
  require yq
  [ -f "$SSO_VALUES" ] || die "missing ${SSO_VALUES}. The 04_google_sso chart ships it."
}

check_prerequisites() {
  say "prerequisites"
  require kubeseal kubectl
  use_kubeconfig
  assert_api
  assert_sealed_secrets_ready
  ok "kubeseal, kubectl and yq present. API and sealed-secrets controller reachable."
}

read_chart_config() {
  local v d
  say "reading OIDC config and domains from ${SSO_VALUES}"
  AUTH_SUBDOMAIN="$(yq -r '.oidc.authSubdomain' "$SSO_VALUES" 2> /dev/null)"
  SEAL_NAME="$(yq -r '.oidc.clientSecretName' "$SSO_VALUES" 2> /dev/null)"
  SEAL_NAMESPACE="$(yq -r '.namespace' "$SSO_VALUES" 2> /dev/null)"
  DOMAINS="$(yq -r '[.domain] + [(.extraDomains // [])[].domain] | join(" ")' "$SSO_VALUES" 2> /dev/null)"
  for v in AUTH_SUBDOMAIN:"$AUTH_SUBDOMAIN" SEAL_NAME:"$SEAL_NAME" SEAL_NAMESPACE:"$SEAL_NAMESPACE" DOMAINS:"$DOMAINS"; do
    [ -n "${v#*:}" ] && [ "${v#*:}" != "null" ] || die "could not read ${v%%:*} from ${SSO_VALUES}"
  done
  for d in $DOMAINS; do ok "domain ${d}  callback: ${AUTH_SUBDOMAIN}.${d}"; done
  ok "seal: ${SEAL_NAME}/${SEAL_NAMESPACE}"
}

# Google accepts many redirect URIs and authorized domains on one client, so one client serves every domain.
print_oauth_client_setup() {
  local d
  say "Google OAuth client"
  echo "  In Google Cloud Console (https://console.cloud.google.com/apis/credentials), on one client:"
  echo "    1. OAuth consent screen: 'External', Published. Under 'Authorized domains', add each apex domain:"
  for d in $DOMAINS; do echo "         ${d}"; done
  echo "    2. Credentials, Create credentials, 'OAuth client ID', type 'Web application'."
  echo "    3. Authorized redirect URIs: add these exactly, one per domain:"
  for d in $DOMAINS; do echo "         https://${AUTH_SUBDOMAIN}.${d}/oauth2/callback"; done
  echo "    4. Create. Copy the Client ID, which ends in apps.googleusercontent.com, and the Client secret."
  echo "  No service account needed. Only a Google Workspace group restriction needs one."
}

read_client_credentials() {
  say "reading the shared Google OAuth client credentials from .env"
  CLIENT_ID="$GOOGLE_SSO_CLIENT_ID"
  CLIENT_SECRET="$GOOGLE_SSO_CLIENT_SECRET"
  [ -n "$CLIENT_ID" ] || die "GOOGLE_SSO_CLIENT_ID is empty in .env"
  [ -n "$CLIENT_SECRET" ] || die "GOOGLE_SSO_CLIENT_SECRET is empty in .env"
  case "$CLIENT_ID" in *.apps.googleusercontent.com) ;; *)
    warn "client ID does not end in .apps.googleusercontent.com. Check it."
    ;;
  esac
}

write_client_id() {
  say "writing clientID into ${SSO_VALUES}"
  ys_set "$SSO_VALUES" "\"${CLIENT_ID}\"" oidc clientID
  [ "$(yq -r '.oidc.clientID' "$SSO_VALUES")" = "$CLIENT_ID" ] && ok "oidc.clientID set" || bad "clientID not written"
}

# Strict scope binds the ciphertext to ${SEAL_NAME}/${SEAL_NAMESPACE}, which every domain's SecurityPolicy uses.
# Envoy Gateway signs its own cookies, so no cookie secret is sealed.
seal_client_secret() {
  say "sealing the client secret into ${SEALED_OUT}"
  seal_secret "$SEAL_NAME" "$SEAL_NAMESPACE" "$SEALED_OUT" "${CLIENT_SECRET_KEY}=${CLIENT_SECRET}"
}

print_result() {
  local base d
  if [ "$FAIL" -ne 0 ]; then
    echo "Something failed. See above. Fix it and run this script again."
    return 0
  fi
  base="${DOMAINS%% *}"
  cat << EOF
Google SSO client set up for: ${DOMAINS}. Register one redirect URI per domain on the OAuth client:
$(for d in $DOMAINS; do echo "  https://${AUTH_SUBDOMAIN}.${d}/oauth2/callback"; done)

Next:
  - git add -A && git commit && git push   # ArgoCD unseals the secret and applies the callbacks and policies
  - for every callback host above and every app host behind SSO: point public DNS at your router, and forward
    port 80 to the Gateway IP, so cert-manager can pass HTTP-01.
  - test: open https://sample-user-manager-sso.app.${base}/. It shows the Google login, and only the allowlist passes.
    sample-user-manager.app.${base} stays open, because google-sso does not list it.
  - to protect another host on a listed domain, add a \`subdomain\` under that domain's \`hosts\`.
    The host must be under that domain. Otherwise the login cookie never reaches it, and the login loops forever.
  - for a host on a new registrable domain, add an \`extraDomains\` entry. Then run this script again to get
    the URIs to register. No new seal is needed, because the client and its sealed Secret are shared.
    See docs/04_ingress.md.
  - to change who can log in, set SSO_ALLOWLIST in .env, run \`make configure-values\` again, then commit and push.
    A single host can override it with its own \`allowlist\`.
  - run this script again to rotate the client secret.
EOF
}

# ---- main ----

check_values_readable
read_chart_config
print_oauth_client_setup
check_prerequisites
read_client_credentials
write_client_id
seal_client_secret

summary
print_result
[ "$FAIL" -eq 0 ]
