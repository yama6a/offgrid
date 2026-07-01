#!/usr/bin/env bash
#
# 07_gateway.sh  (macOS)
#
# Propagates the step-10 knobs (Let's Encrypt email + base domain) from .env into the gateway
# wrapper chart's values.yaml, so the shell side and ArgoCD render the SAME values. This step has NO
# imperative cluster bootstrap, the Gateway + ClusterIssuers (+ the sample app (sample-workload)) are
# delivered purely by ArgoCD from argo_apps/platform/charts/03_gateway/ (Application: argo_apps/platform/apps/
# 03_gateway.yaml, sync-wave 3). See 07_ingress.md.
#
# SINGLE SOURCE OF TRUTH:
#   - .env (here)                       -> LE_EMAIL + BASE_DOMAIN (the shell side)
#   - argo_apps/platform/charts/03_gateway/values.yaml -> everything ArgoCD renders
# This script writes the former into the latter (yq). No values are hardcoded in this script.
#
# Idempotent: re-run safely (it only rewrites the two values).
#
# Non-interactive: NO prompting, knobs come from .env.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# ---- knobs ------------------------------------------------------------------
CHART_DIR="${REPO_ROOT}/argo_apps/platform/charts/03_gateway"   # the wrapper chart (Argo consumes it too)
VALUES="${CHART_DIR}/values.yaml"
# LE_EMAIL + BASE_DOMAIN come from .env via the lib; we write them into values.yaml below.
# -----------------------------------------------------------------------------

# === 0. prereqs ==============================================================
say "prerequisites"
require yq
[ -f "${CHART_DIR}/Chart.yaml" ] || die "no chart at ${CHART_DIR} (expected argo_apps/platform/charts/03_gateway)"
[ -f "$VALUES" ] || die "missing ${VALUES}"
[ -n "${LE_EMAIL}" ]    || die "LE_EMAIL is empty (set it in .env)"
[ -n "${BASE_DOMAIN}" ] || die "BASE_DOMAIN is empty (set it in .env)"
ok "yq present, chart + values found, knobs set"

# === 1. write LE email + base domain from .env into values.yaml =========
# yq edits the chart's plain-YAML values; committing it is what keeps ArgoCD's render in sync with
# .env. strenv() forces both to stay quoted strings (an all-numeric subdomain etc. won't surprise us).
say ".env -> values.yaml  (email=${LE_EMAIL}, baseDomain=${BASE_DOMAIN})"
if LE_EMAIL="$LE_EMAIL" BASE_DOMAIN="$BASE_DOMAIN" \
     yq -i '.acme.email = strenv(LE_EMAIL)
          | .baseDomain = strenv(BASE_DOMAIN)' "$VALUES"; then
  ok "values.yaml updated (commit this so ArgoCD renders the same email + base domain)"
else
  bad "yq failed to write email/baseDomain into ${VALUES}"
fi

# === 2. verify the write round-trips ========================================
say "verify"
got_email="$(yq -r '.acme.email' "$VALUES" 2>/dev/null)"
got_domain="$(yq -r '.baseDomain' "$VALUES" 2>/dev/null)"
[ "$got_email" = "$LE_EMAIL" ]   && ok "acme.email == ${LE_EMAIL}"      || bad "acme.email is '${got_email}', expected '${LE_EMAIL}'"
[ "$got_domain" = "$BASE_DOMAIN" ] && ok "baseDomain == ${BASE_DOMAIN}" || bad "baseDomain is '${got_domain}', expected '${BASE_DOMAIN}'"

# === 3. summary ==============================================================
summary
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
values.yaml now carries email=${LE_EMAIL}, baseDomain=${BASE_DOMAIN}.
Single source of truth: .env -> argo_apps/platform/charts/03_gateway/values.yaml (ArgoCD renders it).

Next:
  - git add -A && git commit && git push   # ArgoCD (wave 3) applies the Gateway + ClusterIssuers only
    (the sample app is sample-workload, the SSO callback hosts 04_google_sso, each owns its cert+route)
  - watch the Gateway:  kubectl -n gateway get gateway shared-gateway   # PROGRAMMED=True, pinned LB IP
  - the per-host listeners stay not-Ready until their apps' certs issue (HTTP-01), expected. See 07_ingress.md.
EOF
else
  echo "Some checks failed, see above. Fix .env and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
