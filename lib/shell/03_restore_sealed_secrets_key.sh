#!/usr/bin/env bash
# Restores the Sealed Secrets master key from the 03_backup dump and restarts the controller so it loads it.
# Without this, a rebuilt cluster's controller mints a brand-new key and every committed SealedSecret is
# orphaned. Idempotent: re-run safely.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
NS="$SS_CONTROLLER_NS"
CONTROLLER_LABEL="$SS_POD_SELECTOR"
KEY_LABEL="$SS_KEY_LABEL"                                # label the controller stamps on its key Secrets
BACKUP_FILE="${CLUSTER_DIR}/sealed-secrets-master.key"   # what 03_backup_sealed_secrets_key.sh wrote
WAIT=900                                                 # secs to wait for the controller (ArgoCD wave 2)

# ---- functions ----

check_prerequisites() {
  say "prerequisites"
  require kubectl
  ensure_cluster_dir
  use_kubeconfig
  [ -f "$BACKUP_FILE" ] || die "no backup at ${BACKUP_FILE}, run 03_backup_sealed_secrets_key.sh first (while a cluster holding the key is up), or re-seal instead (04_google_sso, 06_ntfy_auth)"
  [ -s "$BACKUP_FILE" ] || die "backup ${BACKUP_FILE} is empty, do not trust it"
  grep -q 'kind: Secret' "$BACKUP_FILE" 2>/dev/null || die "backup ${BACKUP_FILE} has no 'kind: Secret', wrong/corrupt file"
  assert_api
  ok "kubectl present, API reachable, backup looks valid"
}

# On a fresh rebuild the controller may not be up yet, so wait rather than fail.
wait_for_controller() {
  local deadline
  say "waiting for the sealed-secrets controller in ns/${NS} (up to ${WAIT}s)"
  deadline=$(( $(date +%s) + WAIT ))
  until kubectl get pods -n "$NS" -l "$CONTROLLER_LABEL" 2>/dev/null | grep -q ' Running'; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      bad "controller not Running after ${WAIT}s, is ArgoCD past wave 2? (kubectl -n ${NS} get pods)"
      summary; exit 1
    fi
    printf '.'; sleep 5
  done
  echo
  ok "controller is Running"
}

# `kubectl apply` of the labelled key Secret(s) is the official restore form, matching what 03_backup dumped.
apply_backup_key() {
  say "applying ${BACKUP_FILE} into ns/${NS}"
  if kubectl apply -f "$BACKUP_FILE" >/dev/null 2>&1; then
    ok "key Secret(s) applied"
  else
    bad "kubectl apply failed, key NOT restored"
  fi
}

# The fresh controller minted its OWN key on first start, and sealed-secrets seals NEW secrets with whichever
# key has the latest cert NotBefore. Left in place, that minted key outranks the restored one, so every
# post-rebuild seal would bind to an ephemeral key the next wipe destroys. Delete every labelled key whose
# name is not in the backup, leaving the backup key(s) as the only, hence active, sealing key.
remove_foreign_keys() {
  local backup_keys removed=0 s name
  say "removing any key the fresh controller minted (not in the backup)"
  backup_keys="$(kubectl create --dry-run=client -f "$BACKUP_FILE" -o name 2>/dev/null | sed 's#^.*/##')"
  if [ -z "$backup_keys" ]; then
    bad "could not read key names from ${BACKUP_FILE}, left foreign keys in place (active sealing key may be ephemeral)"
    return 0
  fi
  for s in $(kubectl get secret -n "$NS" -l "$KEY_LABEL" -o name 2>/dev/null); do
    name="${s#secret/}"
    grep -qx "$name" <<<"$backup_keys" && continue           # a backup key, keep it
    if kubectl delete -n "$NS" "$s" >/dev/null 2>&1; then
      printf '  removed foreign key %s\n' "$name"; removed=$((removed+1))
    else
      bad "could not delete foreign key ${name}, it may still win as the active sealing key"
    fi
  done
  ok "foreign keys removed (${removed}); the backup key is now the active sealing key"
}

restart_controller() {
  say "restarting the controller to load the key"
  if kubectl delete pod -n "$NS" -l "$CONTROLLER_LABEL" >/dev/null 2>&1; then
    ok "controller pod(s) deleted (will restart)"
  else
    bad "could not restart the controller, restart by hand: kubectl delete pod -n ${NS} -l ${CONTROLLER_LABEL}"
  fi
  kubectl wait --for=condition=Ready pod -n "$NS" -l "$CONTROLLER_LABEL" --timeout=120s >/dev/null 2>&1 || true
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Restore did NOT complete cleanly. If the controller wasn't up, wait for ArgoCD (wave 2) and re-run,"
    echo "or re-seal instead (04_google_sso, 06_ntfy_auth) + commit/push."
    return 0
  fi
cat <<EOF
Sealed Secrets master key restored from:
  ${BACKUP_FILE}
The controller is back up with the old key loaded; the committed SealedSecrets decrypt into their Secrets
as ArgoCD (re)applies them. Verify:
  kubectl get sealedsecret -A
  kubectl get secret -A | grep -E 'google-oauth|grafana-ntfy'
EOF
}

# ---- main ----

check_prerequisites
wait_for_controller
apply_backup_key
remove_foreign_keys
restart_controller

summary
print_result
[ "$FAIL" -eq 0 ]
