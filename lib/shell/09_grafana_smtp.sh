#!/usr/bin/env bash
#
# 09_grafana_smtp.sh  (macOS)
#
# Seals the Gmail app-password Grafana uses to send unified-alerting email, so the project stays reusable
# with no personal credentials in git. Grafana's SMTP host/user/from live (non-secret) in the 05_grafana
# values.yaml [smtp] block; the PASSWORD is injected as GF_SMTP_PASSWORD from the sealed `grafana-smtp`
# Secret (envValueFrom, optional). Reads the app-password from .env (SMTP_GOOGLE_APP_PASSWORD_SECRET); if set,
# seals it into a committable SealedSecret; if blank, offers to DELETE it (disables outgoing email, the
# env is optional, so Grafana keeps running). Re-run any time to rotate the password or disable email.
#
# The 16-char Google App Password (needs 2-Step Verification, see 09_monitoring.md) lives in the
# gitignored .env, never echoed, never committed in plaintext.
#
# Written by this script (committable, no secrets in the values file):
#   - argo_apps/platform/charts/05_grafana/templates/grafana-smtp-sealedsecret.yaml   (the sealed app-password)
#
# Native kubeseal + kubectl (hard-fails if missing), apply-to-cluster work is native, like 04/05/12/15.
# Talks to the cluster via the step-03 kubeconfig (kubeseal fetches the controller's cert).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
GRAFANA_CHART="${REPO_ROOT}/argo_apps/platform/charts/05_grafana"                    # the wrapper chart
SEALED_OUT="${GRAFANA_CHART}/templates/grafana-smtp-sealedsecret.yaml"               # sealed app-password (committed)
SMTP_SECRET_NAME="grafana-smtp"                                                      # Secret Grafana reads GF_SMTP_PASSWORD from
SMTP_SECRET_KEY="password"                                                           # data key in the sealed secret; fixed contract with 05_grafana values (key: password)
# -----------------------------------------------------------------------------

# === 0. prereqs ==============================================================
say "prerequisites"
require kubeseal kubectl
[ -d "$GRAFANA_CHART" ] || die "missing ${GRAFANA_CHART}, the 05_grafana chart should ship it"
ok "kubeseal/kubectl present, grafana chart found"

# === 1. read the app-password from .env ======================================
# SMTP_GOOGLE_APP_PASSWORD_SECRET (16-char Gmail app password, needs 2-Step Verification, see 09_monitoring.md)
# comes from the gitignored .env; nothing is prompted. Empty => the DISABLE path (delete the sealed
# file). Given => seal it.
say "Grafana SMTP app-password from .env (SMTP_GOOGLE_APP_PASSWORD_SECRET); empty => DISABLE outgoing email"

# === 2a. SEAL path ===========================================================
if [ -n "$SMTP_GOOGLE_APP_PASSWORD_SECRET" ]; then
  say "app-password given -> sealing into ${SMTP_SECRET_NAME}"

  # controller must be reachable to seal against this cluster's key.
  use_kubeconfig
  assert_api
  kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" >/dev/null 2>&1 \
    || die "sealed-secrets controller not reachable in ns/${SS_CONTROLLER_NS}, is step 02 synced?"

  # seal the app-password (key ${SMTP_SECRET_KEY}) -> ${SMTP_SECRET_NAME} in ${MONITORING_NS}.
  say "sealing app-password -> ${SEALED_OUT}"
  seal_secret "$SMTP_SECRET_NAME" "$MONITORING_NS" "$SMTP_SECRET_KEY" "$SMTP_GOOGLE_APP_PASSWORD_SECRET" "$SEALED_OUT"

# === 2b. DISABLE path: delete the sealed file ================================
else
  say "no app-password -> DISABLE outgoing email (GF_SMTP_PASSWORD unset)"
  if [ -f "$SEALED_OUT" ]; then
    warn "this will DELETE the tracked SealedSecret ${SEALED_OUT}"
    read -r -p ">> remove it and disable Grafana email? type YES: " confirm
    if [ "$confirm" = "YES" ]; then
      rm -f "$SEALED_OUT" && ok "SealedSecret deleted" || bad "could not delete ${SEALED_OUT}"
    else
      die "aborted, left ${SEALED_OUT} in place (re-run with a password to rotate it)"
    fi
  else
    ok "no SealedSecret to remove"
  fi
  warn "Grafana keeps running (GF_SMTP_PASSWORD is optional) but cannot send email. Re-run with a password to enable it."
fi

# === 3. summary ==============================================================
summary
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
Grafana SMTP password sealed at ${SEALED_OUT}.

Next:
  - git add -A && git commit && git push   # ArgoCD (wave 5) applies it; the controller unseals the
                                            # app-password into Secret ${SMTP_SECRET_NAME} (ns ${MONITORING_NS})
  - restart Grafana so it picks up GF_SMTP_PASSWORD:  kubectl -n ${MONITORING_NS} rollout restart deploy/grafana
  - test: Grafana UI -> Alerting -> Contact points -> email -> "Test". See 09_monitoring.md.
  - re-run this script to rotate the app-password or disable email.
EOF
else
  echo "Something failed, see above. Fix and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
