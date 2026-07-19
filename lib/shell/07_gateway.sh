#!/usr/bin/env bash
#
# 07_gateway.sh  (macOS)
#
# Propagates the gateway/ACME knobs from .env into the charts ArgoCD renders (so the shell side and ArgoCD
# render the SAME values) and, when Cloudflare DNS-01 is enabled, seals the Cloudflare API token:
#   - LE_EMAIL                     -> 03_gateway/values.yaml  (acme.email)
#   - CLOUDFLARE_ZONES             -> 03_gateway/values.yaml  (acme.cloudflare.zones: the DNS-01 solver scope +
#                                     the shared wildcard certs) AND lib/helm/ingress/values.yaml
#                                     (cloudflareZones: so CF domains reference the shared wildcard secret and
#                                     skip their per-ingress cert — every consumer inherits this library default)
#   - CLOUDFLARE_API_TOKEN_SECRET  -> sealed into cert-manager's namespace (02_cert_manager templates), when set
#
# Empty token => DNS-01 OFF: zones are forced to [] in the rendered values, so it's HTTP-01 per-host for
# everything (unchanged) and NO cluster access is needed (pure yq). A non-empty token seals against the live
# sealed-secrets controller (like 07_google_sso.sh). The Gateway + ClusterIssuers (+ wildcard certs) are
# delivered by ArgoCD (03_gateway, wave 3); the token SealedSecret by 02_cert_manager (wave 2).
#
# NOTE: the ingress library (lib/helm/ingress) is vendored into its consumers; after this feature landed you
# MUST re-vendor them once (`helm dependency update` per consumer) so they pick up the new templates + the
# cloudflareZones default. See 07_ingress.md.
#
# SINGLE SOURCE OF TRUTH:
#   - .env (here)  -> LE_EMAIL + CLOUDFLARE_ZONES + CLOUDFLARE_API_TOKEN_SECRET
#   - argo_apps/platform/charts/03_gateway/values.yaml + lib/helm/ingress/values.yaml -> what ArgoCD renders
# This script writes the former into the latter (yq). No values are hardcoded in this script.
#
# Idempotent: re-run safely. Non-interactive: NO prompting, knobs come from .env.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
GW_CHART="${REPO_ROOT}/argo_apps/platform/charts/03_gateway"   # the gateway wrapper chart (Argo consumes it too)
GW_VALUES="${GW_CHART}/values.yaml"
LIB_VALUES="${REPO_ROOT}/lib/helm/ingress/values.yaml"         # shared ingress-lib default (all consumers inherit)
CM_CHART="${REPO_ROOT}/argo_apps/platform/charts/02_cert_manager"
CF_SEALED_OUT="${CM_CHART}/templates/cloudflare-api-token-sealedsecret.yaml"  # sealed CF token (committed)
CF_SEAL_NS="cert-manager"   # ClusterIssuer dns01 apiTokenSecretRef resolves in cert-manager's ns (cluster-resource ns)
# CF secret name + key are read from GW_VALUES below (single source) so the ClusterIssuer + the sealed Secret agree.
# -----------------------------------------------------------------------------

# === 0. prereqs ==============================================================
say "prerequisites"
require yq
[ -f "${GW_CHART}/Chart.yaml" ] || die "no chart at ${GW_CHART} (expected argo_apps/platform/charts/03_gateway)"
[ -f "$GW_VALUES" ]  || die "missing ${GW_VALUES}"
[ -f "$LIB_VALUES" ] || die "missing ${LIB_VALUES} (the ingress library should ship it)"
[ -n "${LE_EMAIL}" ] || die "LE_EMAIL is empty (set it in .env)"
ok "yq present, charts + values found, knobs set"

# === 1. write LE email from .env into values.yaml ===========================
# yq edits the chart's plain-YAML values; committing it keeps ArgoCD's render in sync with .env. strenv()
# forces it to stay a quoted string.
say ".env -> 03_gateway values  (email=${LE_EMAIL})"
if LE_EMAIL="$LE_EMAIL" yq -i '.acme.email = strenv(LE_EMAIL)' "$GW_VALUES"; then
  ok "email written"
else
  bad "yq failed to write email into ${GW_VALUES}"
fi

# === 2. Cloudflare DNS-01 zones: gateway solver + ingress-lib wildcard decision ===============
# DNS-01 needs the token; without it a rendered dns01 solver would reference a missing Secret and every
# challenge would fail. So the token gates the zones: no token => force zones to [] (HTTP-01 for all).
EFFECTIVE_ZONES="$CLOUDFLARE_ZONES"
if [ -z "${CLOUDFLARE_API_TOKEN_SECRET}" ] && [ -n "${CLOUDFLARE_ZONES}" ]; then
  warn "CLOUDFLARE_ZONES set but CLOUDFLARE_API_TOKEN_SECRET empty -> DNS-01 stays OFF (need the token); zones ignored"
  EFFECTIVE_ZONES=""
fi
say ".env CLOUDFLARE_ZONES -> gateway + ingress-lib values  (${EFFECTIVE_ZONES:-<none, HTTP-01 for all>})"
# split(" ") + map(select) turns the space-separated scalar into a YAML list, and "" -> [] (not [""]).
if CF_ZONES="$EFFECTIVE_ZONES" yq -i '.acme.cloudflare.zones = (strenv(CF_ZONES) | split(" ") | map(select(. != "")))' "$GW_VALUES"; then
  ok "03_gateway acme.cloudflare.zones written"
else
  bad "yq failed writing acme.cloudflare.zones into ${GW_VALUES}"
fi
if CF_ZONES="$EFFECTIVE_ZONES" yq -i '.cloudflareZones = (strenv(CF_ZONES) | split(" ") | map(select(. != "")))' "$LIB_VALUES"; then
  ok "ingress-lib cloudflareZones written (re-vendor consumers to propagate)"
else
  bad "yq failed writing cloudflareZones into ${LIB_VALUES}"
fi

# === 3. Cloudflare API token: seal into cert-manager (or skip + clean up) =====================
if [ -n "${CLOUDFLARE_API_TOKEN_SECRET}" ]; then
  say "sealing Cloudflare API token -> ${CF_SEALED_OUT}"
  require kubeseal kubectl
  use_kubeconfig
  assert_api
  kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" >/dev/null 2>&1 \
    || die "sealed-secrets controller not reachable in ns/${SS_CONTROLLER_NS}, is step 06 synced? (kubectl -n ${SS_CONTROLLER_NS} get pods)"
  # name + key from GW_VALUES so the ClusterIssuer's apiTokenSecretRef and this Secret always agree.
  CF_SEAL_NAME="$(yq -r '.acme.cloudflare.apiTokenSecretName' "$GW_VALUES" 2>/dev/null)"
  CF_SEAL_KEY="$(yq -r '.acme.cloudflare.apiTokenSecretKey' "$GW_VALUES" 2>/dev/null)"
  [ -n "$CF_SEAL_NAME" ] && [ "$CF_SEAL_NAME" != "null" ] || die "couldn't read acme.cloudflare.apiTokenSecretName from ${GW_VALUES}"
  [ -n "$CF_SEAL_KEY" ]  && [ "$CF_SEAL_KEY" != "null" ]  || die "couldn't read acme.cloudflare.apiTokenSecretKey from ${GW_VALUES}"
  seal_secret "$CF_SEAL_NAME" "$CF_SEAL_NS" "$CF_SEAL_KEY" "$CLOUDFLARE_API_TOKEN_SECRET" "$CF_SEALED_OUT"
else
  say "CLOUDFLARE_API_TOKEN_SECRET empty in .env -> DNS-01 disabled (HTTP-01 per-host for all)"
  # Remove any stale sealed token so a now-disabled deploy doesn't ship a dangling Secret ArgoCD would keep.
  if [ -f "$CF_SEALED_OUT" ]; then
    rm -f "$CF_SEALED_OUT" && ok "removed stale $(basename "$CF_SEALED_OUT")" || bad "failed to remove ${CF_SEALED_OUT}"
  else
    ok "no sealed token to clean up"
  fi
fi

# === 4. verify the writes round-trip ========================================
say "verify"
got_email="$(yq -r '.acme.email' "$GW_VALUES" 2>/dev/null)"
got_gw_zones="$(yq -r '.acme.cloudflare.zones | join(" ")' "$GW_VALUES" 2>/dev/null)"
got_lib_zones="$(yq -r '.cloudflareZones | join(" ")' "$LIB_VALUES" 2>/dev/null)"
[ "$got_email" = "$LE_EMAIL" ]     && ok "acme.email == ${LE_EMAIL}"       || bad "acme.email is '${got_email}', expected '${LE_EMAIL}'"
[ "$got_gw_zones" = "$EFFECTIVE_ZONES" ]  && ok "gateway zones == '${EFFECTIVE_ZONES}'"     || bad "gateway zones are '${got_gw_zones}', expected '${EFFECTIVE_ZONES}'"
[ "$got_lib_zones" = "$EFFECTIVE_ZONES" ] && ok "ingress-lib zones == '${EFFECTIVE_ZONES}'" || bad "ingress-lib zones are '${got_lib_zones}', expected '${EFFECTIVE_ZONES}'"

# === 5. summary ==============================================================
summary
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
values written: 03_gateway (email=${LE_EMAIL}, zones='${EFFECTIVE_ZONES:-<none>}')
                ingress-lib cloudflareZones='${EFFECTIVE_ZONES:-<none>}'${CLOUDFLARE_API_TOKEN_SECRET:+, Cloudflare token sealed}

Next:
  - re-vendor the ingress-library consumers so they pick up the new templates + zone list:
      for c in argo_apps/platform/charts/06_platform_ingress \\
               argo_apps/platform/charts/04_google_sso \\
               argo_apps/workloads/charts/sample_user_manager; do
        helm dependency update "\$c"; done
  - git add -A && git commit && git push   # ArgoCD (wave 3) applies the Gateway + ClusterIssuers + wildcard certs
  - watch:  kubectl -n gateway get certificate,secret | grep wildcard   # READY=True (DNS-01)
            kubectl -n cert-manager get challenges                       # dns-01 for CF names, http-01 for the rest
  - once wildcard issuance works on staging, flip acme.cloudflare.wildcardIssuer -> letsencrypt-prod, push. See 07_ingress.md.
EOF
else
  echo "Some checks failed, see above. Fix .env and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
