#!/usr/bin/env bash
#
# 07_restore_sealed_secrets_key.sh  (macOS)
#
# Restores the Sealed Secrets controller's master key from the backup made by
# 07_backup_sealed_secrets_key.sh — the inverse, for disaster recovery (a cluster rebuild). Re-applies
# the backed-up key Secret(s) into the sealed-secrets namespace and restarts the controller so it loads
# them; once loaded, every SealedSecret committed to this repo (sealed against that key) decrypts again.
# Without this, a rebuilt cluster's controller mints a BRAND-NEW key and every committed SealedSecret is
# orphaned (google-oauth, grafana-smtp, …). See 07_sealed_secrets.md.
#
# On a fresh rebuild the controller is delivered by ArgoCD (wave 2), so it may not be up yet — this WAITS
# for it (up to WAIT secs) before applying. The fresh controller mints its OWN key on first start; we
# apply the backup key, then DELETE that freshly-minted key. This matters: sealed-secrets seals NEW
# secrets with the key whose cert has the latest NotBefore, and the minted key's NotBefore (rebuild time)
# outranks the restored backup key's — so if we left it, every secret sealed AFTER the rebuild would be
# bound to an ephemeral key that the next wipe destroys (the recurring "grafana won't unseal" bug).
# Removing it leaves the backup key as the only — hence active — sealing key.
#
# Uses NATIVE kubectl (errors out if missing). Talks to the cluster via the step-03 kubeconfig.
# Idempotent: re-run safely (kubectl apply + a restart).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# ---- knobs ------------------------------------------------------------------
NS="$SS_CONTROLLER_NS"                                                        # controller namespace
CONTROLLER_LABEL="$SS_POD_SELECTOR"                                          # the controller pods
KEY_LABEL="$SS_KEY_LABEL"                                                     # label the controller stamps on its key Secrets
BACKUP_FILE="${CLUSTER_DIR}/sealed-secrets-master.key"                       # the backup 07_backup wrote
WAIT=900                                                                     # secs to wait for the controller (ArgoCD wave 2)
# -----------------------------------------------------------------------------

# === 0. prereqs ==============================================================
say "prerequisites"
require kubectl
use_kubeconfig
[ -f "$BACKUP_FILE" ] || die "no backup at ${BACKUP_FILE} — run 07_backup_sealed_secrets_key.sh first (while a cluster holding the key is up), or re-seal instead (12_google_sso, 16_grafana_smtp)"
[ -s "$BACKUP_FILE" ] || die "backup ${BACKUP_FILE} is empty — do not trust it"
grep -q 'kind: Secret' "$BACKUP_FILE" 2>/dev/null || die "backup ${BACKUP_FILE} has no 'kind: Secret' — wrong/corrupt file"
assert_api
ok "kubectl present, API reachable, backup looks valid"

# === 1. wait for the sealed-secrets controller (ArgoCD wave 2) ===============
say "waiting for the sealed-secrets controller in ns/${NS} (up to ${WAIT}s)"
deadline=$(( $(date +%s) + WAIT ))
until kubectl get pods -n "$NS" -l "$CONTROLLER_LABEL" 2>/dev/null | grep -q ' Running'; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    bad "controller not Running after ${WAIT}s — is ArgoCD past wave 2? (kubectl -n ${NS} get pods)"
    summary; exit 1
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

# === 2b. delete the fresh controller's own key (anything NOT in the backup) ===
# The fresh controller minted a key on first start; left in place it OUTRANKS the restored backup key as
# the active sealing key (newer cert NotBefore), so post-rebuild seals bind to an ephemeral key the next
# wipe destroys. Delete every labelled key whose name isn't in the backup, leaving the backup key(s) as
# the only — hence active — sealing key. (kubectl reads the names straight from the backup file.)
say "removing any key the fresh controller minted (not in the backup)"
backup_keys="$(kubectl create --dry-run=client -f "$BACKUP_FILE" -o name 2>/dev/null | sed 's#^.*/##')"
if [ -z "$backup_keys" ]; then
  bad "could not read key names from ${BACKUP_FILE} — left foreign keys in place (active sealing key may be ephemeral)"
else
  removed=0
  for s in $(kubectl get secret -n "$NS" -l "$KEY_LABEL" -o name 2>/dev/null); do
    name="${s#secret/}"
    grep -qx "$name" <<<"$backup_keys" && continue           # a backup key — keep it
    if kubectl delete -n "$NS" "$s" >/dev/null 2>&1; then
      printf '  removed foreign key %s\n' "$name"; removed=$((removed+1))
    else
      bad "could not delete foreign key ${name} — it may still win as the active sealing key"
    fi
  done
  ok "foreign keys removed (${removed}); the backup key is now the active sealing key"
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
summary
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
Sealed Secrets master key restored from:
  ${BACKUP_FILE}
The controller is back up with the old key loaded; the committed SealedSecrets decrypt into their Secrets
as ArgoCD (re)applies them. Verify:
  kubectl get sealedsecret -A
  kubectl get secret -A | grep -E 'google-oauth|grafana-smtp'
EOF
else
  echo "Restore did NOT complete cleanly. If the controller wasn't up, wait for ArgoCD (wave 2) and re-run,"
  echo "or re-seal instead (12_google_sso, 16_grafana_smtp) + commit/push."
fi
[ "$FAIL" -eq 0 ]
