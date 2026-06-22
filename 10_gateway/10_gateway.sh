#!/usr/bin/env bash
#
# 10_gateway.sh  (macOS)
#
# Propagates the step-10 knobs (Let's Encrypt email + base domain) from config.sh into the gateway
# wrapper chart's values.yaml, so the shell side and ArgoCD render the SAME values. This step has NO
# imperative cluster bootstrap — the Gateway + ClusterIssuers (+ the gateway-test echo app) are
# delivered purely by ArgoCD from argo_apps/charts/03_gateway/ (Application: argo_apps/apps/
# 03_gateway.yaml, sync-wave 3). See 10_gateway.md.
#
# SINGLE SOURCE OF TRUTH:
#   - config.sh (here)                       -> LE_EMAIL + BASE_DOMAIN (the shell side)
#   - argo_apps/charts/03_gateway/values.yaml -> everything ArgoCD renders
# This script writes the former into the latter (yq). No values are hardcoded in this script.
#
# Idempotent: re-run safely (it only rewrites the two values).
#
# Non-interactive: NO prompting — knobs come from config.sh / env only.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- knobs ------------------------------------------------------------------
CHART_DIR="${CHART_DIR:-${SCRIPT_DIR}/../argo_apps/charts/03_gateway}"   # the wrapper chart (Argo consumes it too)
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.sh}"                    # LE_EMAIL + BASE_DOMAIN knobs

# config.sh is the source of truth for the shell side; we write it into the chart's values.yaml below.
# Sourced before its own knobs so an inline `BASE_DOMAIN=... ./10_gateway.sh` env override still wins
# (the ${VAR:-default} form inside config.sh).
# shellcheck source=config.sh
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
VALUES="${CHART_DIR}/values.yaml"
# -----------------------------------------------------------------------------

say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
PASS=0; FAIL=0
ok()  { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# === 0. prereqs ==============================================================
say "prerequisites"
command -v yq >/dev/null || die "yq not found on PATH — install it (https://github.com/mikefarah/yq, brew install yq)"
[ -f "${CHART_DIR}/Chart.yaml" ] || die "no chart at ${CHART_DIR} (expected argo_apps/charts/03_gateway)"
[ -f "$VALUES" ] || die "missing ${VALUES}"
[ -n "${LE_EMAIL}" ]    || die "LE_EMAIL is empty (set it in ${CONFIG_FILE} or the environment)"
[ -n "${BASE_DOMAIN}" ] || die "BASE_DOMAIN is empty (set it in ${CONFIG_FILE} or the environment)"
ok "yq present, chart + values found, knobs set"

# === 1. write LE email + base domain from config.sh into values.yaml =========
# yq edits the chart's plain-YAML values; committing it is what keeps ArgoCD's render in sync with
# config.sh. strenv() forces both to stay quoted strings (an all-numeric subdomain etc. won't surprise us).
say "config.sh -> values.yaml  (email=${LE_EMAIL}, baseDomain=${BASE_DOMAIN})"
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
echo ""
echo "=============== summary: ${PASS} passed, ${FAIL} failed ==============="
if [ "$FAIL" -eq 0 ]; then
  test_host="$(yq -r '.gatewayTest.subdomain' "$VALUES" 2>/dev/null).${BASE_DOMAIN}"
  cat <<EOF
values.yaml now carries email=${LE_EMAIL}, baseDomain=${BASE_DOMAIN}.
Single source of truth: 10_gateway/config.sh -> argo_apps/charts/03_gateway/values.yaml (ArgoCD renders it).

Next:
  - git add -A && git commit && git push   # ArgoCD (wave 3) applies the Gateway + ClusterIssuers + gateway-test
  - point ${test_host} (public DNS) at home router, and forward :80 for it to the Gateway IP
    on the old Pi (see 10_gateway.md) so cert-manager's HTTP-01 challenge can reach the cluster
  - watch issuance:  kubectl -n gateway get certificate,gateway,httproute
                     curl -kv https://${test_host}/   # whoami echo == path works
EOF
else
  echo "Some checks failed — see above. Fix config.sh (or the env override) and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
