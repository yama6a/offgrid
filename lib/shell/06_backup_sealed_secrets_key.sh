#!/usr/bin/env bash
#
# 06_backup_sealed_secrets_key.sh  (macOS)
#
# Backs up the Sealed Secrets controller's master key, the RSA private key(s) it uses to decrypt
# every SealedSecret committed to this repo. LOSE THIS KEY AND EVERY SEALED SECRET IS UNRECOVERABLE,
# so this dumps it to the gitignored secrets/ dir (alongside the kubeconfig
# / talosconfig), where it is NEVER committed. The controller is delivered by ArgoCD as a wave-2 app
# (argo_apps/platform/charts/02_sealed_secrets/); this is the out-of-band custody step. See 06_secrets.md.
#
# The controller generates the key on first start and ROTATES it ~monthly, KEEPING old keys (so older
# SealedSecrets still decrypt). We therefore back up ALL secrets carrying the sealed-secrets-key label,
# not just the active one. Re-run after each rotation (or on a schedule) to capture new keys.
#
# Uses NATIVE kubectl (errors out if missing), apply-to-cluster work is native, like 04/05, unlike
# the dockerized talos-phase scripts (03a-03e). Talks to the cluster via the step-03 kubeconfig.
#
# Idempotent: re-run safely (overwrites the backup with the current full key set).
#
# RESTORE (disaster recovery, e.g. after a cluster rebuild):
#   kubectl apply -f secrets/sealed-secrets-master.key
#   kubectl delete pod -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets   # restart to load it
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
NS="$SS_CONTROLLER_NS"                                          # controller namespace (Application destination)
KEY_LABEL="$SS_KEY_LABEL"                                       # label the controller stamps on its key Secrets
BACKUP_FILE="${CLUSTER_DIR}/sealed-secrets-master.key"          # where the backup lands (gitignored dir)
# -----------------------------------------------------------------------------

# === 0. prereqs ==============================================================
say "prerequisites"
require kubectl
use_kubeconfig
assert_api
ok "kubectl present, API reachable"

# === 1. find the controller's key Secret(s) ==================================
# Don't filter to the active key, back up the whole labelled set so rotated/retired keys (which still
# decrypt older SealedSecrets) survive too.
say "looking for key Secrets in ns/${NS} (label ${KEY_LABEL})"
KEYS="$(kubectl get secret -n "$NS" -l "$KEY_LABEL" -o name 2>/dev/null)"
if [ -z "$KEYS" ]; then
  bad "no Secrets with label ${KEY_LABEL} in ns/${NS}, is the controller running? (kubectl -n ${NS} get pods)"
  summary; exit 1
fi
KEY_COUNT="$(printf '%s\n' "$KEYS" | grep -c .)"
ok "found ${KEY_COUNT} key Secret(s)"

# === 2. dump to the gitignored backup file ===================================
# `-o yaml` of the labelled Secrets is the official restore-able form (re-applied with kubectl apply).
say "writing backup -> ${BACKUP_FILE}"
mkdir -p "$CLUSTER_DIR"
if kubectl get secret -n "$NS" -l "$KEY_LABEL" -o yaml > "$BACKUP_FILE" 2>/dev/null; then
  chmod 600 "$BACKUP_FILE"
  ok "key(s) written and chmod 600"
else
  bad "kubectl get/dump failed, backup NOT written"
fi

# === 3. sanity-check the backup ==============================================
say "verifying the backup"
[ -s "$BACKUP_FILE" ] && ok "backup file is non-empty" || bad "backup file is empty"
grep -q 'kind: Secret' "$BACKUP_FILE" 2>/dev/null \
  && ok "backup contains Secret manifests" || bad "backup does not contain 'kind: Secret'"

# === 4. summary ==============================================================
summary
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
Sealed Secrets master key backed up to:
  ${BACKUP_FILE}
This file lives in the gitignored secrets/ dir, it is NEVER committed. Store a copy somewhere
safe off-cluster (the whole point is to survive a cluster loss). Re-run after each key rotation.

RESTORE (after a rebuild):
  kubectl apply -f ${BACKUP_FILE}
  kubectl delete pod -n ${NS} -l app.kubernetes.io/name=sealed-secrets   # restart to load the key
EOF
else
  echo "Backup did NOT complete cleanly, do not rely on ${BACKUP_FILE}. Check the controller is up:"
  echo "  kubectl -n ${NS} get pods"
fi
[ "$FAIL" -eq 0 ]
