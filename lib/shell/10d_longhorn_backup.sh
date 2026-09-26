#!/usr/bin/env bash
# Turns on off-cluster Longhorn volume backups. Writes the backup target and credential Secret into the
# 02_longhorn values. Only volumes on the longhorn-r2-retained-with-backups class are backed up.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
LH_CHART_DIR="${PLATFORM_CHARTS}/02_longhorn"
LH_VALUES="${LH_CHART_DIR}/values.yaml"
LH_NAMESPACE="longhorn-system" # must match the app destination
SEALED_OUT="${LH_CHART_DIR}/templates/backup-s3-sealedsecret.yaml"
SECRET_NAME="longhorn-backup-s3"  # becomes backupTargetCredentialSecret in the values
SECRET_KEY_ID="AWS_ACCESS_KEY_ID" # key names that the Longhorn backup target reads
SECRET_KEY_SECRET="AWS_SECRET_ACCESS_KEY"

# ---- functions ----

check_prerequisites() {
  say "prerequisites"
  require yq kubeseal kubectl terraform
  [ -f "$LH_VALUES" ] || die "missing ${LH_VALUES}"
  if [ -z "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
    warn "AWS_DEPLOY_ACCESS_KEY_ID is empty in .env, so S3 backups are off. Skipping. The 02_longhorn values stay as is."
    exit 0
  fi
  [ -n "$AWS_REGION" ] || die "AWS_REGION is empty in .env"
  [ -n "$S3_BACKUP_BUCKET" ] || die "S3_BACKUP_BUCKET is empty in .env"
  ok "tools present, values file found"
}

# The two backup RecurringJobs render only when backupTarget is set.
# Retention is the RecurringJob `retain` field. The S3 lifecycle deletes nothing under longhorn/.
enable_in_chart_values() {
  local backup_target="s3://${S3_BACKUP_BUCKET}@${AWS_REGION}/longhorn/"
  say "turning on backups: writing backupTarget and the credential Secret into ${LH_VALUES}"
  ys_set "$LH_VALUES" "\"${backup_target}\"" longhorn defaultBackupStore backupTarget
  ys_set "$LH_VALUES" "\"${SECRET_NAME}\"" longhorn defaultBackupStore backupTargetCredentialSecret
  [ "$(yq -r '.longhorn.defaultBackupStore.backupTarget' "$LH_VALUES")" = "$backup_target" ] \
    && ok "backupTarget=${backup_target}" || bad "backupTarget not set"
  [ "$(yq -r '.longhorn.defaultBackupStore.backupTargetCredentialSecret' "$LH_VALUES")" = "$SECRET_NAME" ] \
    && ok "backupTargetCredentialSecret=${SECRET_NAME}" || bad "backupTargetCredentialSecret not set"
}

seal_writer_creds() {
  say "sealing the S3 creds into ns/${LH_NAMESPACE}"
  use_kubeconfig
  assert_api
  assert_sealed_secrets_ready
  seal_secret "$SECRET_NAME" "$LH_NAMESPACE" "$SEALED_OUT" \
    "${SECRET_KEY_ID}=${AKID}" "${SECRET_KEY_SECRET}=${SAK}"
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Something failed. See above. Fix it and run this script again."
    return 0
  fi
  cat << EOF
Longhorn S3 backups on: bucket ${S3_BACKUP_BUCKET}, prefix longhorn/, daily and weekly RecurringJobs.
Only volumes on the 'longhorn-r2-retained-with-backups' StorageClass are backed up.
Redis and the monitoring volumes have no Longhorn backup.
Next:
  - git add -A && git commit && git push   # 02_longhorn applies backupTarget, the sealed creds and the
                                            # daily and weekly RecurringJobs
  - verify:  kubectl -n ${LH_NAMESPACE} get backuptargets.longhorn.io default -o jsonpath='{.status.available}{"\n"}'
             kubectl -n ${LH_NAMESPACE} get recurringjobs.longhorn.io
             kubectl get storageclass longhorn-r2-retained-with-backups
  - restore drill:  make restore-longhorn
EOF
}

# ---- main ----

check_prerequisites
read_backup_creds # from the Terraform state that 10a wrote, not from .env
enable_in_chart_values
seal_writer_creds

summary
print_result
[ "$FAIL" -eq 0 ]
