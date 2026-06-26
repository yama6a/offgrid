#!/usr/bin/env bash
#
# 16_grafana_smtp.sh  (macOS)
#
# Seals the Gmail app-password Grafana uses to send unified-alerting email, so the project stays reusable
# with no personal credentials in git. Grafana's SMTP host/user/from live (non-secret) in the 07_grafana
# values.yaml [smtp] block; the PASSWORD is injected as GF_SMTP_PASSWORD from the sealed `grafana-smtp`
# Secret (envValueFrom, optional). Prompts for the app-password; if given, seals it into a committable
# SealedSecret; if blank, offers to DELETE it (disables outgoing email — the env is optional, so Grafana
# keeps running). Re-run any time to rotate the password or disable email.
#
# INTERACTIVE: prompts for the 16-char Google App Password (hidden; needs 2-Step Verification — see
# 16_grafana.md), never echoed, never committed in plaintext.
#
# Written by this script (committable, no secrets in the values file):
#   - argo_apps/charts/07_grafana/templates/grafana-smtp-sealedsecret.yaml   (the sealed app-password)
#
# Native kubeseal + kubectl (hard-fails if missing) — apply-to-cluster work is native, like 04/05/12/15.
# Talks to the cluster via the step-03 kubeconfig (kubeseal fetches the controller's cert).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.sh}"
# shellcheck source=config.sh
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# ---- knobs ------------------------------------------------------------------
REPO_ROOT="${REPO_ROOT:-${SCRIPT_DIR}/..}"
GRAFANA_CHART="${GRAFANA_CHART:-${REPO_ROOT}/argo_apps/charts/07_grafana}"                    # the wrapper chart
SEALED_OUT="${SEALED_OUT:-${GRAFANA_CHART}/templates/grafana-smtp-sealedsecret.yaml}"         # sealed app-password (committed)
OUTDIR="${OUTDIR:-${REPO_ROOT}/03_operating_system/talos-cluster}"                            # kubeconfig (from 03d); gitignored
export KUBECONFIG="${KUBECONFIG:-${OUTDIR}/kubeconfig}"
# -----------------------------------------------------------------------------

say()  { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; }
PASS=0; FAIL=0
ok()  { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# === 0. prereqs ==============================================================
say "prerequisites"
command -v kubeseal >/dev/null || die "kubeseal not found on PATH — install it (brew install kubeseal)"
command -v kubectl  >/dev/null || die "kubectl not found on PATH — install it (https://kubernetes.io/docs/tasks/tools/)"
[ -d "$GRAFANA_CHART" ] || die "missing ${GRAFANA_CHART} — the 07_grafana chart should ship it"
ok "kubeseal/kubectl present, grafana chart found"

# === 1. prompt for the app-password ==========================================
# Empty => the DISABLE path (delete the sealed file). Given => seal it.
say "Grafana SMTP app-password (Gmail) — leave blank to DISABLE outgoing email"
echo "  This is a 16-char Google App Password (needs 2-Step Verification), NOT your account password."
echo "  Generate one at https://myaccount.google.com/apppasswords. See 16_grafana.md."
read -rsp "  app-password (hidden): " SMTP_PASSWORD; echo

# === 2a. SEAL path ===========================================================
if [ -n "$SMTP_PASSWORD" ]; then
  say "app-password given -> sealing into ${SMTP_SECRET_NAME}"

  # controller must be reachable to seal against this cluster's key.
  kubectl get nodes >/dev/null 2>&1 || die "kubectl can't reach the API via ${KUBECONFIG} — run step 03 first"
  kubectl get pods -n "$SS_CONTROLLER_NS" -l app.kubernetes.io/name=sealed-secrets >/dev/null 2>&1 \
    || die "sealed-secrets controller not reachable in ns/${SS_CONTROLLER_NS} — is step 02 synced?"

  # seal the app-password (key ${SMTP_SECRET_KEY}) -> ${SMTP_SECRET_NAME} in ${MONITORING_NS}. --dry-run
  # builds the Secret locally; kubeseal encrypts it against the controller; strict scope binds it to
  # exactly that name+namespace. Overwrites any existing sealed file.
  say "sealing app-password -> ${SEALED_OUT}"
  mkdir -p "$(dirname "$SEALED_OUT")"
  if kubectl create secret generic "$SMTP_SECRET_NAME" -n "$MONITORING_NS" \
        --dry-run=client -o yaml \
        --from-literal="${SMTP_SECRET_KEY}=${SMTP_PASSWORD}" \
     | kubeseal --controller-namespace "$SS_CONTROLLER_NS" --controller-name "$SS_CONTROLLER_NAME" \
         --format yaml --scope strict > "${SEALED_OUT}.tmp" 2>/dev/null; then
    mv "${SEALED_OUT}.tmp" "$SEALED_OUT"
    ok "SealedSecret written (overwritten if it existed)"
  else
    rm -f "${SEALED_OUT}.tmp"
    bad "kubeseal failed — SealedSecret NOT written (controller sealed-secrets/${SS_CONTROLLER_NS} up?)"
  fi

  # never commit a plaintext secret.
  if [ -s "$SEALED_OUT" ]; then
    grep -q 'kind: SealedSecret' "$SEALED_OUT" && ok "output is a SealedSecret" || bad "not a SealedSecret manifest"
    grep -qF "$SMTP_PASSWORD" "$SEALED_OUT" && bad "PLAINTEXT password in output — DO NOT COMMIT" || ok "no plaintext password in output"
  fi

# === 2b. DISABLE path: delete the sealed file ================================
else
  say "no app-password -> DISABLE outgoing email (GF_SMTP_PASSWORD unset)"
  if [ -f "$SEALED_OUT" ]; then
    warn "this will DELETE the tracked SealedSecret ${SEALED_OUT}"
    read -r -p ">> remove it and disable Grafana email? type YES: " confirm
    if [ "$confirm" = "YES" ]; then
      rm -f "$SEALED_OUT" && ok "SealedSecret deleted" || bad "could not delete ${SEALED_OUT}"
    else
      die "aborted — left ${SEALED_OUT} in place (re-run with a password to rotate it)"
    fi
  else
    ok "no SealedSecret to remove"
  fi
  warn "Grafana keeps running (GF_SMTP_PASSWORD is optional) but cannot send email. Re-run with a password to enable it."
fi

# === 3. summary ==============================================================
echo ""
echo "=============== summary: ${PASS} passed, ${FAIL} failed ==============="
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
Grafana SMTP password sealed at ${SEALED_OUT}.

Next:
  - git add -A && git commit && git push   # ArgoCD (wave 7) applies it; the controller unseals the
                                            # app-password into Secret ${SMTP_SECRET_NAME} (ns ${MONITORING_NS})
  - restart Grafana so it picks up GF_SMTP_PASSWORD:  kubectl -n ${MONITORING_NS} rollout restart deploy/grafana
  - test: Grafana UI -> Alerting -> Contact points -> email -> "Test". See 16_grafana.md.
  - re-run this script to rotate the app-password or disable email.
EOF
else
  echo "Something failed — see above. Fix and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
