#!/usr/bin/env bash
#
# 07_google_sso.sh  (macOS)
#
# Wires up the multi-domain Google-SSO SecurityPolicies (04_google_sso chart): prompts for the ONE
# shared Google OAuth client-id + client-secret, and a SEPARATE email allowlist per SSO domain. Writes
# the non-secret bits (clientID + per-domain allowlists) into the chart values and seals the client
# SECRET into a committable SealedSecret. The SecurityPolicies are delivered purely by ArgoCD
# (argo_apps/platform/apps/04_google_sso.yaml, sync-wave 4). See 07_ingress.md.
#
# INTERACTIVE: prompts for client-id, client-secret (hidden), and one allowlist per domain. No cookie
# secret, Envoy Gateway signs its own session cookies. The redirectURL + cookieDomain are DERIVED in the
# chart (google-sso.<domain> / <domain>), not written here. Re-run to rotate the secret or edit allowlists.
#
# SINGLE SOURCE OF TRUTH (read, not duplicated):
#   - the SSO domains + seal target <- argo_apps/platform/charts/04_google_sso/values.yaml (ssoDomains, namespace,
#     oidc.clientSecretName, authSubdomain)
# Written by this script:
#   - argo_apps/platform/charts/04_google_sso/values.yaml  (oidc.clientID, ssoDomains[].allowlist)
#   - argo_apps/platform/charts/04_google_sso/templates/google-oauth-sealedsecret.yaml  (the sealed client secret)
#
# Native kubeseal + kubectl + yq (hard-fails if missing), apply-to-cluster work is native, like 04/05/07.
# Talks to the cluster via the step-03 kubeconfig (kubeseal fetches the controller's cert).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# ---- knobs ------------------------------------------------------------------
GATEWAY_VALUES="${REPO_ROOT}/argo_apps/platform/charts/03_gateway/values.yaml"   # cross-check the domain list
SSO_CHART="${REPO_ROOT}/argo_apps/platform/charts/04_google_sso"                 # the wrapper chart
SSO_VALUES="${SSO_CHART}/values.yaml"                                            # clientID/allowlists written here
SEALED_OUT="${SSO_CHART}/templates/google-oauth-sealedsecret.yaml"              # sealed client secret (committed)
CLIENT_SECRET_KEY="client-secret"   # Secret data key EG's OIDC clientSecret expects (fixed by Envoy Gateway)
# -----------------------------------------------------------------------------

# normalize a comma-separated email string -> newline list (lowercased, whitespace-stripped, validated).
# sed strips whitespace PER LINE so it can't eat the newlines tr just made (tr -d would).
normalize_emails() { printf '%s' "$1" | tr ',' '\n' | tr 'A-Z' 'a-z' | sed -E 's/[[:space:]]+//g' | grep -E '.+@.+\..+' || true; }

# === 0. prereqs ==============================================================
say "prerequisites"
require kubeseal kubectl yq
use_kubeconfig
[ -f "$SSO_VALUES" ]     || die "missing ${SSO_VALUES}, the 04_google_sso chart should ship it"
assert_api
kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" >/dev/null 2>&1 \
  || die "sealed-secrets controller not reachable in ns/${SS_CONTROLLER_NS}, is step 06 synced? (kubectl -n ${SS_CONTROLLER_NS} get pods)"
ok "kubeseal/kubectl/yq present, API + sealed-secrets controller reachable"

# === 1. read the SSO config from the chart (single source of truth) ==========
say "reading SSO domains + seal target from ${SSO_VALUES}"
AUTH_SUBDOMAIN="$(yq -r '.authSubdomain' "$SSO_VALUES" 2>/dev/null)"
SEAL_NAMESPACE="$(yq -r '.namespace' "$SSO_VALUES" 2>/dev/null)"
SEAL_NAME="$(yq -r '.oidc.clientSecretName' "$SSO_VALUES" 2>/dev/null)"
for v in AUTH_SUBDOMAIN:"$AUTH_SUBDOMAIN" SEAL_NAMESPACE:"$SEAL_NAMESPACE" SEAL_NAME:"$SEAL_NAME"; do
  [ -n "${v#*:}" ] && [ "${v#*:}" != "null" ] || die "couldn't read ${v%%:*} from ${SSO_VALUES}"
done
DOMAINS=()
while IFS= read -r d; do [ -n "$d" ] && DOMAINS+=("$d"); done < <(yq -r '.ssoDomains[].domain' "$SSO_VALUES" 2>/dev/null)
[ "${#DOMAINS[@]}" -ge 1 ] || die "no .ssoDomains in ${SSO_VALUES}"
ok "domains: ${DOMAINS[*]}  callback: ${AUTH_SUBDOMAIN}.<domain>  seal: ${SEAL_NAME}/${SEAL_NAMESPACE}"

# cross-check: the Gateway (03_gateway httpsHosts) must terminate TLS for each domain's callback host,# the listener can only live on the Gateway, so it's a separate list from the callbacks in this chart.
if [ -f "$GATEWAY_VALUES" ]; then
  gw_hosts="$(yq -r '.httpsHosts[].hostname' "$GATEWAY_VALUES" 2>/dev/null)"
  for d in "${DOMAINS[@]}"; do
    cb="${AUTH_SUBDOMAIN}.${d}"
    printf '%s\n' "$gw_hosts" | grep -qx "$cb" \
      || warn "03_gateway httpsHosts has no listener for ${cb}, ${d}'s login will 404 until you add it"
  done
fi

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

# === 3. prompt for the shared client id + secret =============================
say "enter the shared Google OAuth client credentials"
read -rp  "  Google OAuth Client ID: " CLIENT_ID
read -rsp "  Google OAuth Client secret (hidden): " CLIENT_SECRET; echo
[ -n "$CLIENT_ID" ]     || die "client id is empty"
[ -n "$CLIENT_SECRET" ] || die "client secret is empty"
case "$CLIENT_ID" in *.apps.googleusercontent.com) ;; *)
  warn "client id does not end in .apps.googleusercontent.com, double-check it" ;;
esac

# === 4. write clientID + a per-domain allowlist into the chart values ========
say "writing clientID + per-domain allowlists into ${SSO_VALUES}"
if CLIENT_ID="$CLIENT_ID" yq -i '.oidc.clientID = strenv(CLIENT_ID)' "$SSO_VALUES"; then
  [ "$(yq -r '.oidc.clientID' "$SSO_VALUES")" = "$CLIENT_ID" ] && ok "oidc.clientID set" || bad "clientID not written"
else
  bad "yq failed to write oidc.clientID"
fi
i=0
for d in "${DOMAINS[@]}"; do
  read -rp "  Allowed Google accounts for ${d} (comma-separated emails): " RAW
  LIST="$(normalize_emails "$RAW")"
  N="$(printf '%s\n' "$LIST" | grep -c . || true)"
  if [ "${N:-0}" -lt 1 ]; then bad "no valid emails for ${d}, left unchanged"; i=$((i+1)); continue; fi
  if EMAILS_LIST="$LIST" yq -i ".ssoDomains[$i].allowlist = (strenv(EMAILS_LIST) | split(\"\n\"))" "$SSO_VALUES"; then
    ok "${d}: ${N}-account allowlist written"
  else
    bad "${d}: yq failed to write allowlist"
  fi
  i=$((i+1))
done

# === 5. seal the shared client secret (overwrite) ============================
# One key: ${CLIENT_SECRET_KEY} (what Envoy Gateway's OIDC clientSecret reads). --dry-run=client builds
# the manifest locally; kubeseal encrypts it against THIS cluster's controller key. Strict scope binds it
# to exactly ${SEAL_NAME}/${SEAL_NAMESPACE}. The same Secret is referenced by every domain's policy.
say "sealing client secret -> ${SEALED_OUT}"
seal_secret "$SEAL_NAME" "$SEAL_NAMESPACE" "$CLIENT_SECRET_KEY" "$CLIENT_SECRET" "$SEALED_OUT"

# === 6. summary ==============================================================
summary
if [ "$FAIL" -eq 0 ]; then
  echo "Google SSO configured for ${#DOMAINS[@]} domain(s). Register these redirect URIs on the OAuth client:"
  for d in "${DOMAINS[@]}"; do echo "  https://${AUTH_SUBDOMAIN}.${d}/oauth2/callback"; done
  cat <<EOF

Next:
  - git add -A && git commit && git push   # ArgoCD (wave 4) unseals the secret + applies the policies
  - for EACH domain's callback host (${AUTH_SUBDOMAIN}.<domain>) AND each protected app host: point public
    DNS at the home router + forward :80 to the Gateway IP on the old Pi so cert-manager's HTTP-01 issues.
  - test:  open https://sample-workload-sso.example.com/  -> Google login; only example.com's allowlist passes.
           (sample-workload.example.com stays OPEN, no sso label.)
  - protect another host: label its HTTPRoute \`sso: <its-domain>\`. No Google change if that domain is
    already configured; a NEW domain = add it to BOTH charts' domain lists + register one more redirect URI.
  - re-run this script to rotate the client secret or edit any allowlist.
EOF
else
  echo "Something failed, see above. Fix and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
