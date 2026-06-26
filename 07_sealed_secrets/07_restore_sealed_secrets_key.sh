#!/usr/bin/env bash
#
# 07_restore_sealed_secrets_key.sh  (macOS)
#
# Restores the Sealed Secrets controller's master key from the backup made by
# 07_backup_sealed_secrets_key.sh — the inverse, for disaster recovery (a cluster rebuild). Re-applies
# the backed-up key Secret(s) into the sealed-secrets namespace and restarts the controller so it loads
# them; once loaded, every SealedSecret committed to this repo (sealed against that key) decrypts again.
# Without this, a rebuilt cluster's controller mints a BRAND-NEW key and every committed SealedSecret is
# orphaned (google-oauth, alertmanager-smtp, …). See 07_sealed_secrets.md.
#
# On a fresh rebuild the controller is delivered by ArgoCD (wave 2), so it may not be up yet — this WAITS
# for it (up to WAIT secs) before applying. Applying the old key after the controller already minted a
# new one is fine: on restart the controller loads ALL labelled keys, so old + new are both available.
#
# Uses NATIVE kubectl (errors out if missing). Talks to the cluster via the step-03 kubeconfig.
# Idempotent: re-run safely (kubectl apply + a restart).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- knobs ------------------------------------------------------------------
OUTDIR="${OUTDIR:-${SCRIPT_DIR}/../03_operating_system/talos-cluster}"        # talosconfig + kubeconfig (from 03d); gitignored
NS="${NS:-sealed-secrets}"                                                    # controller namespace
CONTROLLER_LABEL="${CONTROLLER_LABEL:-app.kubernetes.io/name=sealed-secrets}" # the controller pods
BACKUP_FILE="${BACKUP_FILE:-${OUTDIR}/sealed-secrets-master.key}"             # the backup 07_backup wrote
WAIT="${WAIT:-900}"                                                           # secs to wait for the controller (ArgoCD wave 2)
export KUBECONFIG="${KUBECONFIG:-${OUTDIR}/kubeconfig}"                       # the 03d kubeconfig (points at the VIP)
# -----------------------------------------------------------------------------

say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
PASS=0; FAIL=0
ok()  { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# === 0. prereqs ==============================================================
say "prerequisites"
command -v kubectl >/dev/null || die "kubectl not found on PATH — install it (https://kubernetes.io/docs/tasks/tools/)"
[ -f "$KUBECONFIG" ]  || die "missing ${KUBECONFIG} — run step 03 (03d) first"
[ -f "$BACKUP_FILE" ] || die "no backup at ${BACKUP_FILE} — run 07_backup_sealed_secrets_key.sh first (while a cluster holding the key is up), or re-seal instead (12_google_sso, 15_monitoring)"
[ -s "$BACKUP_FILE" ] || die "backup ${BACKUP_FILE} is empty — do not trust it"
grep -q 'kind: Secret' "$BACKUP_FILE" 2>/dev/null || die "backup ${BACKUP_FILE} has no 'kind: Secret' — wrong/corrupt file"
kubectl get nodes >/dev/null 2>&1 || die "kubectl can't reach the API via ${KUBECONFIG}"
ok "kubectl present, API reachable, backup looks valid"

# === 1. wait for the sealed-secrets controller (ArgoCD wave 2) ===============
say "waiting for the sealed-secrets controller in ns/${NS} (up to ${WAIT}s)"
deadline=$(( $(date +%s) + WAIT ))
until kubectl get pods -n "$NS" -l "$CONTROLLER_LABEL" 2>/dev/null | grep -q ' Running'; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    bad "controller not Running after ${WAIT}s — is ArgoCD past wave 2? (kubectl -n ${NS} get pods)"
    echo ""; echo "=============== summary: ${PASS} passed, ${FAIL} failed ==============="; exit 1
  fi
  printf '.'; sleep 5
done
echo
ok "controller is Running"

# === 2. apply the backed-up key(s) ===========================================
# `kubectl apply` of the labelled key Secret(s) is the official restore form (matches what 07_backup dumped).
say "applying ${BACKUP_FILE} into ns/${NS}"
if kubectl apply -f "$BACKUP_FILE" >/dev/null 2>&1; then
  ok "key Secret(s) applied"
else
  bad "kubectl apply failed — key NOT restored"
fi

# === 3. restart the controller so it loads the restored key ==================
say "restarting the controller to load the key"
if kubectl delete pod -n "$NS" -l "$CONTROLLER_LABEL" >/dev/null 2>&1; then
  ok "controller pod(s) deleted (will restart)"
else
  bad "could not restart the controller — restart by hand: kubectl delete pod -n ${NS} -l ${CONTROLLER_LABEL}"
fi
kubectl wait --for=condition=Ready pod -n "$NS" -l "$CONTROLLER_LABEL" --timeout=120s >/dev/null 2>&1 || true

# === 4. summary ==============================================================
echo ""
echo "=============== summary: ${PASS} passed, ${FAIL} failed ==============="
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
Sealed Secrets master key restored from:
  ${BACKUP_FILE}
The controller is back up with the old key loaded; the committed SealedSecrets decrypt into their Secrets
as ArgoCD (re)applies them. Verify:
  kubectl get sealedsecret -A
  kubectl get secret -A | grep -E 'google-oauth|alertmanager-smtp'
EOF
else
  echo "Restore did NOT complete cleanly. If the controller wasn't up, wait for ArgoCD (wave 2) and re-run,"
  echo "or re-seal instead (12_google_sso, 15_monitoring) + commit/push."
fi
[ "$FAIL" -eq 0 ]
