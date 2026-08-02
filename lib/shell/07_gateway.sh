#!/usr/bin/env bash
# Propagates the gateway and ACME knobs from .env into the chart values ArgoCD renders, so the shell side and
# ArgoCD agree. Values-only, NO cluster access, so it is safe to run before ArgoCD and sealed-secrets exist.
# The Cloudflare token is NOT sealed here (07_cloudflare_token.sh does that once the controller is up). Here
# it only GATES the zones: an empty token forces zones to [], because a dns01 solver with no token would
# reference a missing Secret and fail every challenge.
# After changing lib/helm/ingress you must re-vendor its consumers once (`helm dependency update` per
# consumer) before a local render picks up the new templates and defaults.
# Idempotent and non-interactive.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
GW_CHART="${REPO_ROOT}/argo_apps/platform/charts/03_gateway"   # the gateway wrapper chart (Argo consumes it too)
GW_VALUES="${GW_CHART}/values.yaml"
LIB_VALUES="${REPO_ROOT}/lib/helm/ingress/values.yaml"         # shared ingress-lib default (all consumers inherit)

say "prerequisites"
require yq
[ -f "${GW_CHART}/Chart.yaml" ] || die "no chart at ${GW_CHART} (expected argo_apps/platform/charts/03_gateway)"
[ -f "$GW_VALUES" ]  || die "missing ${GW_VALUES}"
[ -f "$LIB_VALUES" ] || die "missing ${LIB_VALUES} (the ingress library should ship it)"
[ -n "${LE_EMAIL}" ] || die "LE_EMAIL is empty (set it in .env)"
ok "yq present, charts + values found, knobs set"

# Committing the rewritten values is what keeps ArgoCD's render in sync with .env. Values are passed WITH
# their quotes so they stay strings.
say ".env -> 03_gateway values  (email=${LE_EMAIL})"
ys_set "$GW_VALUES" "\"${LE_EMAIL}\"" acme email

# DNS-01 needs the token; without it a rendered dns01 solver would reference a missing Secret and every
# challenge would fail. So the token gates the zones: no token => force zones to [] (HTTP-01 for all).
EFFECTIVE_ZONES="$CLOUDFLARE_WILDCARD_DOMAINS"
if [ -z "${CLOUDFLARE_API_TOKEN_SECRET}" ] && [ -n "${CLOUDFLARE_WILDCARD_DOMAINS}" ]; then
  warn "CLOUDFLARE_WILDCARD_DOMAINS set but CLOUDFLARE_API_TOKEN_SECRET empty -> DNS-01 stays OFF (need the token); zones ignored"
  EFFECTIVE_ZONES=""
fi
say ".env CLOUDFLARE_WILDCARD_DOMAINS -> gateway + ingress-lib values  (${EFFECTIVE_ZONES:-<none, HTTP-01 for all>})"
# ys_set_list turns the space-separated scalar into a block sequence, and "" into an inline [] (not [""]).
ys_set_list "$GW_VALUES"  "$EFFECTIVE_ZONES" acme cloudflare zones
ys_set_list "$LIB_VALUES" "$EFFECTIVE_ZONES" cloudflareZones

say "verify"
got_email="$(yq -r '.acme.email' "$GW_VALUES" 2>/dev/null)"
got_gw_zones="$(yq -r '.acme.cloudflare.zones | join(" ")' "$GW_VALUES" 2>/dev/null)"
got_lib_zones="$(yq -r '.cloudflareZones | join(" ")' "$LIB_VALUES" 2>/dev/null)"
[ "$got_email" = "$LE_EMAIL" ]     && ok "acme.email == ${LE_EMAIL}"       || bad "acme.email is '${got_email}', expected '${LE_EMAIL}'"
[ "$got_gw_zones" = "$EFFECTIVE_ZONES" ]  && ok "gateway zones == '${EFFECTIVE_ZONES}'"     || bad "gateway zones are '${got_gw_zones}', expected '${EFFECTIVE_ZONES}'"
[ "$got_lib_zones" = "$EFFECTIVE_ZONES" ] && ok "ingress-lib zones == '${EFFECTIVE_ZONES}'" || bad "ingress-lib zones are '${got_lib_zones}', expected '${EFFECTIVE_ZONES}'"

summary
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
values written: 03_gateway (email=${LE_EMAIL}, zones='${EFFECTIVE_ZONES:-<none>}'), ingress-lib cloudflareZones='${EFFECTIVE_ZONES:-<none>}'

Next:
  - re-vendor the ingress-library consumers so they pick up the new templates + zone list:
      for c in argo_apps/platform/charts/06_platform_ingress \\
               argo_apps/platform/charts/04_google_sso \\
               argo_apps/workloads/charts/sample_user_manager; do
        helm dependency update "\$c"; done
  - git add -A && git commit && git push   # ArgoCD (wave 3) applies the Gateway + ClusterIssuers + wildcard certs
$(if [ -n "${CLOUDFLARE_WILDCARD_DOMAINS}" ]; then cat <<'HINT'
  - once ArgoCD + the sealed-secrets controller are up, seal the Cloudflare token:  make configure-cloudflare-token
    (the bootstrap orchestrator runs this for you). Without it the dns01 solver can't authenticate.
HINT
fi)
  - watch:  kubectl -n gateway get certificate,secret | grep wildcard   # READY=True (DNS-01)
            kubectl -n cert-manager get challenges                       # dns-01 for CF names, http-01 for the rest
  - once wildcard issuance works on staging, flip acme.cloudflare.wildcardIssuer -> letsencrypt-prod, push. See 07_ingress.md.
EOF
else
  echo "Some checks failed, see above. Fix .env and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
