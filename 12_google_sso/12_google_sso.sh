#!/usr/bin/env bash
#
# 12_google_sso.sh  (macOS)
#
# Wires up the Google-SSO SecurityPolicy (04_google_sso chart): prompts for the Google OAuth client-id
# + the email allowlist (written plaintext into the chart values — Envoy Gateway can't read them from a
# Secret, and they're low-sensitivity), and seals the client SECRET into a committable SealedSecret.
# Also (re)writes the host-derived redirectURL + cookieDomain into the chart values. The SecurityPolicy
# itself is delivered purely by ArgoCD (argo_apps/apps/04_google_sso.yaml, sync-wave 4). See 12_google_sso.md.
#
# INTERACTIVE: prompts for client-id, client-secret (hidden) and the allowed emails (comma-separated).
# No cookie secret — Envoy Gateway signs its own session cookies. Re-run to rotate the client secret or
# change the allowlist; it OVERWRITES the sealed secret and the values.
#
# SINGLE SOURCE OF TRUTH (read, not duplicated):
#   - SSO host  <- argo_apps/charts/03_gateway/values.yaml  (baseDomain + gatewayTestSso.subdomain)
#   - seal ns + Secret name <- argo_apps/charts/04_google_sso/values.yaml (namespace + oidc.clientSecretName)
# Written by this script:
#   - argo_apps/charts/04_google_sso/values.yaml            (clientID, redirectURL, cookieDomain, allowlist)
#   - argo_apps/charts/04_google_sso/templates/google-oauth-sealedsecret.yaml  (the sealed client secret)
#
# Native kubeseal + kubectl + yq (hard-fails if missing) — apply-to-cluster work is native, like 04/05/07.
# Talks to the cluster via the step-03 kubeconfig (kubeseal fetches the controller's cert).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.sh}"
# shellcheck source=config.sh
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# ---- knobs ------------------------------------------------------------------
REPO_ROOT="${REPO_ROOT:-${SCRIPT_DIR}/..}"
GATEWAY_VALUES="${GATEWAY_VALUES:-${REPO_ROOT}/argo_apps/charts/03_gateway/values.yaml}"   # SoT for the host
SSO_CHART="${SSO_CHART:-${REPO_ROOT}/argo_apps/charts/04_google_sso}"                      # the wrapper chart
SSO_VALUES="${SSO_VALUES:-${SSO_CHART}/values.yaml}"                                       # clientID/allowlist/redirect written here
SEALED_OUT="${SEALED_OUT:-${SSO_CHART}/templates/google-oauth-sealedsecret.yaml}"         # sealed client secret (committed)
OUTDIR="${OUTDIR:-${REPO_ROOT}/03_operating_system/talos-cluster}"                         # kubeconfig (from 03d); gitignored
export KUBECONFIG="${KUBECONFIG:-${OUTDIR}/kubeconfig}"
# -----------------------------------------------------------------------------

say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
PASS=0; FAIL=0
ok()  { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# === 0. prereqs ==============================================================
say "prerequisites"
command -v kubeseal >/dev/null || die "kubeseal not found on PATH — install it (brew install kubeseal)"
command -v kubectl  >/dev/null || die "kubectl not found on PATH — install it (https://kubernetes.io/docs/tasks/tools/)"
command -v yq       >/dev/null || die "yq not found on PATH — install it (brew install yq)"
[ -f "$KUBECONFIG" ]     || die "missing ${KUBECONFIG} — run step 03 (03d) first"
[ -f "$GATEWAY_VALUES" ] || die "missing ${GATEWAY_VALUES} — run/commit step 10 first"
[ -f "$SSO_VALUES" ]     || die "missing ${SSO_VALUES} — the 04_google_sso chart should ship it"
kubectl get nodes >/dev/null 2>&1 || die "kubectl can't reach the API via ${KUBECONFIG}"
kubectl get pods -n "$SS_CONTROLLER_NS" -l app.kubernetes.io/name=sealed-secrets >/dev/null 2>&1 \
  || die "sealed-secrets controller not reachable in ns/${SS_CONTROLLER_NS} — is step 07 synced? (kubectl -n ${SS_CONTROLLER_NS} get pods)"
ok "kubeseal/kubectl/yq present, API + sealed-secrets controller reachable"

# === 1. derive host + read seal target from the charts (single source of truth) ===
say "reading host + seal target from the charts"
BASE_DOMAIN="$(yq -r '.baseDomain' "$GATEWAY_VALUES" 2>/dev/null)"
SSO_SUBDOMAIN="$(yq -r '.gatewayTestSso.subdomain' "$GATEWAY_VALUES" 2>/dev/null)"
SEAL_NAMESPACE="$(yq -r '.namespace' "$SSO_VALUES" 2>/dev/null)"
SEAL_NAME="$(yq -r '.oidc.clientSecretName' "$SSO_VALUES" 2>/dev/null)"
for v in BASE_DOMAIN:"$BASE_DOMAIN" SSO_SUBDOMAIN:"$SSO_SUBDOMAIN" SEAL_NAMESPACE:"$SEAL_NAMESPACE" SEAL_NAME:"$SEAL_NAME"; do
  [ -n "${v#*:}" ] && [ "${v#*:}" != "null" ] || die "couldn't read ${v%%:*} from the chart values"
done
HOST="${SSO_SUBDOMAIN}.${BASE_DOMAIN}"
REDIRECT_URL="https://${HOST}/oauth2/callback"
ok "host=${HOST}  redirect-url=${REDIRECT_URL}  seal=${SEAL_NAME}/${SEAL_NAMESPACE}"

# === 2. how to create the Google OAuth client ================================
say "Google OAuth client — create one if you don't have it"
cat <<EOF
  In Google Cloud Console (https://console.cloud.google.com/apis/credentials):
    1. OAuth consent screen: "External", and Publish it ("In production") so accounts outside any
       test-user list can sign in (they're still gated by the email allowlist below).
    2. Credentials -> Create credentials -> "OAuth client ID" -> type "Web application".
    3. Authorized redirect URIs -> add EXACTLY:
         ${REDIRECT_URL}
       (Optionally add the JavaScript origin: https://${HOST})
    4. Create -> copy the Client ID (…apps.googleusercontent.com) and Client secret.

  No service account / JSON key needed — that's only for Google Workspace *group* restriction.
EOF

# === 3. prompt for client id, client secret, allowlist =======================
say "enter the Google OAuth client credentials + the email allowlist"
read -rp  "  Google OAuth Client ID: " CLIENT_ID
read -rsp "  Google OAuth Client secret (hidden): " CLIENT_SECRET; echo
read -rp  "  Allowed Google accounts (comma-separated emails): " EMAILS_RAW

[ -n "$CLIENT_ID" ]     || die "client id is empty"
[ -n "$CLIENT_SECRET" ] || die "client secret is empty"
case "$CLIENT_ID" in *.apps.googleusercontent.com) ;; *)
  printf '  \033[33m[warn]\033[0m client id does not end in .apps.googleusercontent.com — double-check it\n' ;;
esac

# normalize emails: split on commas, lowercase, strip whitespace PER LINE (sed, so it keeps the newlines
# tr just made — tr -d would eat them), keep only things shaped like an email.
EMAILS_LIST="$(printf '%s' "$EMAILS_RAW" | tr ',' '\n' | tr 'A-Z' 'a-z' | sed -E 's/[[:space:]]+//g' | grep -E '.+@.+\..+' || true)"
EMAIL_COUNT="$(printf '%s\n' "$EMAILS_LIST" | grep -c . || true)"
[ "${EMAIL_COUNT:-0}" -ge 1 ] || die "no valid emails parsed from: ${EMAILS_RAW}"
say "allowlist (${EMAIL_COUNT} account(s)):"
printf '%s\n' "$EMAILS_LIST" | sed 's/^/    /'

# === 4. write clientID, redirectURL, cookieDomain, allowlist into the chart values ===
say "writing clientID + redirectURL + cookieDomain + allowlist into ${SSO_VALUES} (commit so ArgoCD renders the same)"
if CLIENT_ID="$CLIENT_ID" REDIRECT_URL="$REDIRECT_URL" BASE_DOMAIN="$BASE_DOMAIN" EMAILS_LIST="$EMAILS_LIST" \
     yq -i '.oidc.clientID = strenv(CLIENT_ID)
          | .oidc.redirectURL = strenv(REDIRECT_URL)
          | .oidc.cookieDomain = strenv(BASE_DOMAIN)
          | .allowlist = (strenv(EMAILS_LIST) | split("\n"))' "$SSO_VALUES"; then
  got_cid="$(yq -r '.oidc.clientID' "$SSO_VALUES")"
  got_rurl="$(yq -r '.oidc.redirectURL' "$SSO_VALUES")"
  got_n="$(yq -r '.allowlist | length' "$SSO_VALUES")"
  [ "$got_cid" = "$CLIENT_ID" ]    && ok "oidc.clientID set"                      || bad "clientID is '${got_cid}'"
  [ "$got_rurl" = "$REDIRECT_URL" ] && ok "oidc.redirectURL == ${REDIRECT_URL}"   || bad "redirectURL is '${got_rurl}'"
  [ "$got_n" = "$EMAIL_COUNT" ]    && ok "allowlist has ${got_n} account(s)"      || bad "allowlist length is '${got_n}', expected ${EMAIL_COUNT}"
else
  bad "yq failed to write into ${SSO_VALUES}"
fi

# === 5. seal the client secret (overwrite) ===================================
# One key: ${CLIENT_SECRET_KEY} (what Envoy Gateway's OIDC clientSecret reads). --dry-run=client builds
# the manifest locally; kubeseal encrypts it against THIS cluster's controller key. Strict scope binds
# it to exactly ${SEAL_NAME}/${SEAL_NAMESPACE}.
say "sealing client secret -> ${SEALED_OUT}"
mkdir -p "$(dirname "$SEALED_OUT")"
if kubectl create secret generic "$SEAL_NAME" -n "$SEAL_NAMESPACE" \
      --dry-run=client -o yaml \
      --from-literal="${CLIENT_SECRET_KEY}=${CLIENT_SECRET}" \
   | kubeseal --controller-namespace "$SS_CONTROLLER_NS" --controller-name "$SS_CONTROLLER_NAME" \
       --format yaml --scope strict > "${SEALED_OUT}.tmp" 2>/dev/null; then
  mv "${SEALED_OUT}.tmp" "$SEALED_OUT"
  ok "SealedSecret written (overwritten if it existed)"
else
  rm -f "${SEALED_OUT}.tmp"
  bad "kubeseal failed — SealedSecret NOT written (controller name/ns right? sealed-secrets/${SS_CONTROLLER_NS})"
fi

# === 6. sanity-check the sealed output =======================================
say "verifying the sealed output"
if [ -s "$SEALED_OUT" ]; then
  grep -q 'kind: SealedSecret' "$SEALED_OUT" && ok "contains kind: SealedSecret" || bad "not a SealedSecret manifest"
  grep -q "$CLIENT_SECRET_KEY" "$SEALED_OUT" && ok "encryptedData has ${CLIENT_SECRET_KEY}" || bad "encryptedData missing ${CLIENT_SECRET_KEY}"
  grep -q "$CLIENT_SECRET" "$SEALED_OUT" && bad "PLAINTEXT client secret found in output — DO NOT COMMIT" || ok "no plaintext secret in output"
else
  bad "sealed output is empty/missing"
fi

# === 7. summary ==============================================================
echo ""
echo "=============== summary: ${PASS} passed, ${FAIL} failed ==============="
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
Google SSO configured for ${HOST}:
  ${SSO_VALUES}   (clientID, redirectURL=${REDIRECT_URL}, cookieDomain=${BASE_DOMAIN}, ${EMAIL_COUNT}-account allowlist)
  ${SEALED_OUT}   (sealed client secret)

Next:
  - git add -A && git commit && git push   # ArgoCD (wave 4) unseals the secret + applies the SecurityPolicy
  - point ${HOST} (public DNS) at the home router + forward :80 for it to the Gateway IP on the old Pi
    (same as gateway-test, see 10_gateway.md) so cert-manager's HTTP-01 can issue the cert
  - test:  open https://${HOST}/   -> Google login; only allowlisted accounts reach the whoami echo.
           (gateway-test.<domain> stays OPEN — it has no auth label.)
  - to protect another host: add the label \`auth: google-sso\` to its HTTPRoute. Nothing to change here
    (the redirect-url is per-host though: register each host's /oauth2/callback on the Google client, or
    move to a shared auth-host + cookieDomain — see 12_google_sso.md).
  - re-run this script to rotate the client secret or change the allowlist (it overwrites both).
EOF
else
  echo "Something failed — see above. Fix and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
