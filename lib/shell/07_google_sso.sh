#!/usr/bin/env bash
#
# 07_google_sso.sh  (macOS)
#
# Wires up the SHARED Google-OIDC client: reads the ONE OAuth client-id + client-secret from .env, writes
# the (non-secret) client-id into the CENTRAL google-sso chart values, and seals the client SECRET into a
# committable SealedSecret. The callback hosts + the one-per-domain SecurityPolicy are delivered by ArgoCD
# (04_google_sso, wave 4). See 07_ingress.md.
#
# WHERE SSO LIVES NOW: everything google-sso is central in argo_apps/platform/charts/04_google_sso. Which
# hosts are gated (and by which email allowlist) is the `domains[].hosts` map there — edit that to protect
# a host; workloads configure nothing. This script only touches the shared client-id + the sealed secret.
#
# client-id + client-secret come from the gitignored .env (GOOGLE_SSO_CLIENT_ID / GOOGLE_SSO_CLIENT_SECRET).
# Nothing is prompted, so a non-interactive re-run (DANGEROUS_bootstrap_cluster.sh piping </dev/null) just
# re-writes the client-id and re-seals the secret. No cookie secret (Envoy Gateway signs its own cookies).
#
# SINGLE SOURCE OF TRUTH (read, not duplicated), all from the google-sso chart values
# (argo_apps/platform/charts/04_google_sso/values.yaml):
#   - the shared OIDC config (authSubdomain, clientSecretName) <- .oidc.*
#   - the seal namespace <- .namespace ; the SSO domains <- .domains[].domain
# Written by this script:
#   - argo_apps/platform/charts/04_google_sso/values.yaml  (.oidc.clientID)
#   - argo_apps/platform/charts/04_google_sso/templates/google-oauth-sealedsecret.yaml  (the sealed secret)
#
# Native kubeseal + kubectl + yq (hard-fails if missing), apply-to-cluster work is native, like 04/05/07.
# Talks to the cluster via the step-03 kubeconfig (kubeseal fetches the controller's cert).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
SSO_CHART="${REPO_ROOT}/argo_apps/platform/charts/04_google_sso"                 # the central google-sso chart
SSO_VALUES="${SSO_CHART}/values.yaml"                                            # oidc config + domains live here; clientID written here
SEALED_OUT="${SSO_CHART}/templates/google-oauth-sealedsecret.yaml"              # sealed client secret (committed)
CLIENT_SECRET_KEY="client-secret"   # Secret data key EG's OIDC clientSecret expects (fixed by Envoy Gateway)
# -----------------------------------------------------------------------------

# === 0. prereqs ==============================================================
say "prerequisites"
require kubeseal kubectl yq
use_kubeconfig
[ -f "$SSO_VALUES" ] || die "missing ${SSO_VALUES} (the 04_google_sso chart should ship it)"
assert_api
kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" >/dev/null 2>&1 \
  || die "sealed-secrets controller not reachable in ns/${SS_CONTROLLER_NS}, is step 06 synced? (kubectl -n ${SS_CONTROLLER_NS} get pods)"
ok "kubeseal/kubectl/yq present, API + sealed-secrets controller reachable"

# === 1. read the shared OIDC config + SSO domains (single source of truth) ==============
say "reading OIDC config + domains from ${SSO_VALUES}"
AUTH_SUBDOMAIN="$(yq -r '.oidc.authSubdomain' "$SSO_VALUES" 2>/dev/null)"
SEAL_NAME="$(yq -r '.oidc.clientSecretName' "$SSO_VALUES" 2>/dev/null)"
SEAL_NAMESPACE="$(yq -r '.namespace' "$SSO_VALUES" 2>/dev/null)"
for v in AUTH_SUBDOMAIN:"$AUTH_SUBDOMAIN" SEAL_NAME:"$SEAL_NAME" SEAL_NAMESPACE:"$SEAL_NAMESPACE"; do
  [ -n "${v#*:}" ] && [ "${v#*:}" != "null" ] || die "couldn't read ${v%%:*} from ${SSO_VALUES}"
done
DOMAINS=()
while IFS= read -r d; do [ -n "$d" ] && [ "$d" != "null" ] && DOMAINS+=("$d"); done \
  < <(yq -r '.domains[].domain' "$SSO_VALUES" 2>/dev/null)
[ "${#DOMAINS[@]}" -ge 1 ] || die "no SSO domains (.domains[].domain) in ${SSO_VALUES}"
ok "domains: ${DOMAINS[*]}  callback: ${AUTH_SUBDOMAIN}.<domain>  seal: ${SEAL_NAME}/${SEAL_NAMESPACE}"

# === 2. how to set up the Google OAuth client (ONE client, all domains) ======
say "Google OAuth client, ONE client covers all domains"
echo "  In Google Cloud Console (https://console.cloud.google.com/apis/credentials):"
echo "    1. OAuth consent screen: 'External', Published. Under 'Authorized domains' add each apex:"
for d in "${DOMAINS[@]}"; do echo "         ${d}"; done
echo "    2. Credentials -> Create credentials -> 'OAuth client ID' -> type 'Web application'."
echo "    3. Authorized redirect URIs -> add ONE per domain, EXACTLY:"
for d in "${DOMAINS[@]}"; do echo "         https://${AUTH_SUBDOMAIN}.${d}/oauth2/callback"; done
echo "    4. Create -> copy the Client ID (...apps.googleusercontent.com) and Client secret."
echo "  No service account needed (that's only for Google Workspace *group* restriction)."

# === 3. read the shared client id + secret from .env =========================
say "reading the shared Google OAuth client credentials from .env"
CLIENT_ID="$GOOGLE_SSO_CLIENT_ID"
CLIENT_SECRET="$GOOGLE_SSO_CLIENT_SECRET"
[ -n "$CLIENT_ID" ]     || die "GOOGLE_SSO_CLIENT_ID is empty in .env"
[ -n "$CLIENT_SECRET" ] || die "GOOGLE_SSO_CLIENT_SECRET is empty in .env"
case "$CLIENT_ID" in *.apps.googleusercontent.com) ;; *)
  warn "client id does not end in .apps.googleusercontent.com, double-check it" ;;
esac

# === 4. write the shared clientID into the google-sso chart values ===========
say "writing clientID into ${SSO_VALUES}"
if CLIENT_ID="$CLIENT_ID" yq -i '.oidc.clientID = strenv(CLIENT_ID)' "$SSO_VALUES"; then
  [ "$(yq -r '.oidc.clientID' "$SSO_VALUES")" = "$CLIENT_ID" ] && ok "oidc.clientID set" || bad "clientID not written"
else
  bad "yq failed to write oidc.clientID"
fi

# === 5. seal the shared client secret (overwrite) ============================
# One key: ${CLIENT_SECRET_KEY} (what Envoy Gateway's OIDC clientSecret reads). --dry-run=client builds the
# manifest locally; kubeseal encrypts it against THIS cluster's controller key. Strict scope binds it to
# exactly ${SEAL_NAME}/${SEAL_NAMESPACE}. Referenced by every domain's SecurityPolicy.
say "sealing client secret -> ${SEALED_OUT}"
seal_secret "$SEAL_NAME" "$SEAL_NAMESPACE" "$CLIENT_SECRET_KEY" "$CLIENT_SECRET" "$SEALED_OUT"

# === 6. summary ==============================================================
summary
if [ "$FAIL" -eq 0 ]; then
  echo "Google SSO client wired for ${#DOMAINS[@]} domain(s). Register these redirect URIs on the OAuth client:"
  for d in "${DOMAINS[@]}"; do echo "  https://${AUTH_SUBDOMAIN}.${d}/oauth2/callback"; done
  cat <<EOF

Next:
  - git add -A && git commit && git push   # ArgoCD unseals the secret + applies the callbacks/policies
  - for EACH domain's callback host (${AUTH_SUBDOMAIN}.<domain>) AND each gated app host: point public DNS
    at the home router + forward :80 to the Gateway IP on the old Pi so cert-manager's HTTP-01 issues.
  - test:  open https://sample-workload-sso.example.com/  -> Google login; only its allowlist passes.
           (sample-workload.example.com stays OPEN, not listed in google-sso.)
  - protect another host: add it to \`domains[].hosts\` in 04_google_sso/values.yaml (with its allowlist).
    No Google change if that domain already has a callback host; a NEW domain = add a \`domains\` entry +
    register one more redirect URI here. See 07_ingress.md.
  - change WHO may log in: edit that host's \`allowlist\` in 04_google_sso/values.yaml, commit, push.
  - re-run this script to rotate the client secret.
EOF
else
  echo "Something failed, see above. Fix and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
