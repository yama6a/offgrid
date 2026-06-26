#!/usr/bin/env bash
#
# 15_alertmanager_secret.sh  (macOS)
#
# Makes the Alertmanager destination a RUNTIME choice so the project stays reusable with no personal
# credentials in git. Prompts for Gmail SMTP creds; if given, seals them into a committable SealedSecret
# AND writes the EMAIL receiver into the stack values; if not, tears down to a NULL receiver (no
# destination). Re-run any time to rotate creds, change the recipient, or disable alerting.
#
# INTERACTIVE: prompts for SMTP username (Gmail address), app-password (hidden), and recipient. The
# app-password is a 16-char Google App Password (needs 2-Step Verification — see 15_monitoring.md), never
# echoed, never committed in plaintext.
#
# Written by this script (both committable, no secrets in the values file):
#   - argo_apps/charts/07_kube_prometheus_stack/values.yaml
#       (kube-prometheus-stack.alertmanager.config + .alertmanagerSpec.secrets — email OR null variant)
#   - argo_apps/charts/07_kube_prometheus_stack/templates/alertmanager-smtp-sealedsecret.yaml
#       (the sealed app-password — only when creds are given; DELETED in the null path)
#
# Native kubeseal + kubectl + yq (hard-fails if missing) — apply-to-cluster work is native, like 04/05/12.
# Talks to the cluster via the step-03 kubeconfig (kubeseal fetches the controller's cert).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.sh}"
# shellcheck source=config.sh
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# ---- knobs ------------------------------------------------------------------
REPO_ROOT="${REPO_ROOT:-${SCRIPT_DIR}/..}"
STACK_CHART="${STACK_CHART:-${REPO_ROOT}/argo_apps/charts/07_kube_prometheus_stack}"   # the wrapper chart
STACK_VALUES="${STACK_VALUES:-${STACK_CHART}/values.yaml}"                             # config block written here
SEALED_OUT="${SEALED_OUT:-${STACK_CHART}/templates/alertmanager-smtp-sealedsecret.yaml}"  # sealed app-password (committed)
VALUES_KEY="${VALUES_KEY:-kube-prometheus-stack}"                                     # top-level subchart key
# where the Secret is mounted inside the Alertmanager pod (alertmanagerSpec.secrets -> this dir):
SECRET_MOUNT="/etc/alertmanager/secrets/${SMTP_SECRET_NAME}/${SMTP_SECRET_KEY}"
OUTDIR="${OUTDIR:-${REPO_ROOT}/03_operating_system/talos-cluster}"                     # kubeconfig (from 03d); gitignored
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
command -v yq       >/dev/null || die "yq not found on PATH — install it (brew install yq)"
[ -f "$STACK_VALUES" ] || die "missing ${STACK_VALUES} — the 07_kube_prometheus_stack chart should ship it"
yq -e ".[\"${VALUES_KEY}\"]" "$STACK_VALUES" >/dev/null 2>&1 \
  || die "no .${VALUES_KEY} key in ${STACK_VALUES} — wrong file?"
ok "kubeseal/kubectl/yq present, stack values found"

# === 1. prompt for the SMTP credentials ======================================
# Empty username OR password => the NULL path (no destination). Both given => the EMAIL path.
say "Alertmanager email destination (Gmail SMTP) — leave blank to DISABLE alerting (null receiver)"
echo "  The password is a 16-char Google App Password (needs 2-Step Verification), NOT your account"
echo "  password. Generate one at https://myaccount.google.com/apppasswords. See 15_monitoring.md."
read -rp  "  SMTP username (Gmail address) [blank = disable]: " SMTP_USERNAME
SMTP_PASSWORD=""
if [ -n "$SMTP_USERNAME" ]; then
  read -rsp "  SMTP app-password (hidden): " SMTP_PASSWORD; echo
fi
ALERT_TO=""
if [ -n "$SMTP_USERNAME" ] && [ -n "$SMTP_PASSWORD" ]; then
  read -rp  "  Send alerts to [${SMTP_USERNAME}]: " ALERT_TO
  ALERT_TO="${ALERT_TO:-$SMTP_USERNAME}"
fi

# === 2a. EMAIL path: seal creds + write the email receiver ===================
if [ -n "$SMTP_USERNAME" ] && [ -n "$SMTP_PASSWORD" ]; then
  say "credentials given -> EMAIL receiver"

  # controller must be reachable to seal against this cluster's key.
  kubectl get nodes >/dev/null 2>&1 || die "kubectl can't reach the API via ${KUBECONFIG} — run step 03 first"
  kubectl get pods -n "$SS_CONTROLLER_NS" -l app.kubernetes.io/name=sealed-secrets >/dev/null 2>&1 \
    || die "sealed-secrets controller not reachable in ns/${SS_CONTROLLER_NS} — is step 07 synced?"

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

  # write the EMAIL variant into the stack values. Mount the secret + an email receiver that reads the
  # password from the mounted file (never inlined). 4h repeat_interval = sane re-notify cadence.
  say "writing the email receiver into ${STACK_VALUES}"
  if K="$VALUES_KEY" SH="$SMTP_SMARTHOST" U="$SMTP_USERNAME" TO="$ALERT_TO" SECNAME="$SMTP_SECRET_NAME" PWFILE="$SECRET_MOUNT" \
     yq -i '
       .[strenv(K)].alertmanager.alertmanagerSpec.secrets = [strenv(SECNAME)] |
       .[strenv(K)].alertmanager.config = {
         "global": {
           "smtp_smarthost": strenv(SH),
           "smtp_from": strenv(U),
           "smtp_auth_username": strenv(U),
           "smtp_auth_password_file": strenv(PWFILE),
           "smtp_require_tls": true
         },
         "route": {
           "receiver": "email",
           "group_by": ["alertname", "namespace"],
           "group_wait": "30s",
           "group_interval": "5m",
           "repeat_interval": "4h"
         },
         "receivers": [
           {"name": "email", "email_configs": [{"to": strenv(TO), "send_resolved": true}]},
           {"name": "null"}
         ]
       }' "$STACK_VALUES"; then
    [ "$(K="$VALUES_KEY" yq -r '.[strenv(K)].alertmanager.config.route.receiver' "$STACK_VALUES")" = "email" ] \
      && ok "alertmanager.config = email receiver, recipient ${ALERT_TO}" || bad "email config not written"
  else
    bad "yq failed to write the email config"
  fi

  # never commit a plaintext secret.
  if [ -s "$SEALED_OUT" ]; then
    grep -q 'kind: SealedSecret' "$SEALED_OUT" && ok "output is a SealedSecret" || bad "not a SealedSecret manifest"
    grep -qF "$SMTP_PASSWORD" "$SEALED_OUT" && bad "PLAINTEXT password in output — DO NOT COMMIT" || ok "no plaintext password in output"
  fi
  grep -qF "$SMTP_PASSWORD" "$STACK_VALUES" && bad "PLAINTEXT password in values.yaml — DO NOT COMMIT" || ok "no plaintext password in values.yaml"

# === 2b. NULL path: delete the sealed file + write the null receiver =========
else
  say "no credentials -> NULL receiver (alerting has NO destination)"
  if [ -f "$SEALED_OUT" ]; then
    warn "this will DELETE the tracked SealedSecret ${SEALED_OUT}"
    read -r -p ">> remove it and disable email alerting? type YES: " confirm
    if [ "$confirm" = "YES" ]; then
      rm -f "$SEALED_OUT" && ok "SealedSecret deleted" || bad "could not delete ${SEALED_OUT}"
    else
      die "aborted — left ${SEALED_OUT} in place (re-run with creds to keep email alerting)"
    fi
  else
    ok "no SealedSecret to remove"
  fi

  say "writing the null receiver into ${STACK_VALUES}"
  if K="$VALUES_KEY" yq -i '
       del(.[strenv(K)].alertmanager.alertmanagerSpec.secrets) |
       .[strenv(K)].alertmanager.config = {
         "route": {"receiver": "null", "group_by": ["alertname", "namespace"]},
         "receivers": [{"name": "null"}]
       }' "$STACK_VALUES"; then
    [ "$(K="$VALUES_KEY" yq -r '.[strenv(K)].alertmanager.config.route.receiver' "$STACK_VALUES")" = "null" ] \
      && ok "alertmanager.config = null receiver" || bad "null config not written"
  else
    bad "yq failed to write the null config"
  fi
  warn "Alertmanager will run healthy but DROP all alerts (no destination). Re-run with creds to enable email."
fi

# === 3. summary ==============================================================
echo ""
echo "=============== summary: ${PASS} passed, ${FAIL} failed ==============="
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
Alertmanager wiring updated in ${STACK_VALUES}.

Next:
  - git add -A && git commit && git push   # ArgoCD (wave 7) applies the config; the controller unseals
                                            # the app-password into Secret ${SMTP_SECRET_NAME} (ns ${MONITORING_NS})
  - watch it converge:  kubectl -n ${MONITORING_NS} get alertmanager,secret ${SMTP_SECRET_NAME}
  - test an alert end-to-end: see 15_monitoring.md (Alertmanager bootstrap).
  - re-run this script to rotate the app-password, change the recipient, or disable alerting.
EOF
else
  echo "Something failed — see above. Fix and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
