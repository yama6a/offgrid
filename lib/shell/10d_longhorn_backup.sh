#!/usr/bin/env bash
# Turns ON off-cluster Longhorn volume backups: backup target + credential secret into the 02_longhorn values.
# Native Longhorn (backup target + RecurringJobs), not a CronJob. Only volumes on the
# longhorn-r2-retained-with-backups class are backed up.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
LH_CHART_DIR="${PLATFORM_CHARTS}/02_longhorn"
LH_VALUES="${LH_CHART_DIR}/values.yaml"                     # the Longhorn wrapper values (single source)
LH_NAMESPACE="longhorn-system"                              # == the app destination
SEALED_OUT="${LH_CHART_DIR}/templates/backup-s3-sealedsecret.yaml"
SECRET_NAME="longhorn-backup-s3"                            # == values backupTargetCredentialSecret
SECRET_KEY_ID="AWS_ACCESS_KEY_ID"                           # == the names Longhorn's backup target reads
SECRET_KEY_SECRET="AWS_SECRET_ACCESS_KEY"

# ---- functions ----

check_prerequisites() {
  say "prerequisites"
  require yq kubeseal kubectl terraform
  [ -f "$LH_VALUES" ] || die "missing ${LH_VALUES}"
  if [ -z "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
    warn "AWS_DEPLOY_ACCESS_KEY_ID empty in .env -> S3 backups disabled; skipping (02_longhorn values left as-is)."
    exit 0
  fi
  [ -n "$AWS_REGION" ]       || die "AWS_REGION is empty in .env"
  [ -n "$S3_BACKUP_BUCKET" ] || die "S3_BACKUP_BUCKET is empty in .env"
  ok "tools present, values file found"
}

# Longhorn's S3 URL is s3://<bucket>@<region>/<prefix>/, region after the @ and a trailing slash. An EMPTY
# backupTarget means the two BACKUP RecurringJobs do not render, so setting it is what turns backups on; all
# three StorageClasses and the filesystem-trim job render either way.
# Retention is Longhorn's own RecurringJob `retain`, not an S3 lifecycle: the longhorn/ prefix is delete-free.
enable_in_chart_values() {
  local backup_target="s3://${S3_BACKUP_BUCKET}@${AWS_REGION}/longhorn/"
  say "enabling backups: injecting backupTarget + credential secret into ${LH_VALUES}"
  ys_set "$LH_VALUES" "\"${backup_target}\"" longhorn defaultBackupStore backupTarget
  ys_set "$LH_VALUES" "\"${SECRET_NAME}\""   longhorn defaultBackupStore backupTargetCredentialSecret
  [ "$(yq -r '.longhorn.defaultBackupStore.backupTarget' "$LH_VALUES")" = "$backup_target" ] \
    && ok "backupTarget=${backup_target}" || bad "backupTarget not set"
  [ "$(yq -r '.longhorn.defaultBackupStore.backupTargetCredentialSecret' "$LH_VALUES")" = "$SECRET_NAME" ] \
    && ok "backupTargetCredentialSecret=${SECRET_NAME}" || bad "backupTargetCredentialSecret not set"
}

seal_writer_creds() {
  say "sealing S3 creds into ns ${LH_NAMESPACE}"
  use_kubeconfig
  assert_api
  assert_sealed_secrets_ready
  seal_secret "$SECRET_NAME" "$LH_NAMESPACE" "$SEALED_OUT" \
    "${SECRET_KEY_ID}=${AKID}" "${SECRET_KEY_SECRET}=${SAK}"
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Something failed, see above. Fix and re-run (idempotent)."
    return 0
  fi
cat <<EOF
Longhorn S3 backups enabled (bucket ${S3_BACKUP_BUCKET}, prefix longhorn/, daily+weekly RecurringJobs). Only volumes
on the 'longhorn-r2-retained-with-backups' StorageClass are backed up (opt-in). Redis + the monitoring volumes stay unbacked.
Next:
  - git add -A && git commit && git push   # ArgoCD applies (02_longhorn): backupTarget + the sealed creds +
                                            # the daily/weekly RecurringJobs (the class is always present).
  - verify:  kubectl -n ${LH_NAMESPACE} get backuptargets.longhorn.io default -o jsonpath='{.status.available}{"\n"}'
             kubectl -n ${LH_NAMESPACE} get recurringjobs.longhorn.io
             kubectl get storageclass longhorn-r2-retained-with-backups
  - restore drill:  make restore-longhorn
EOF
}

# ---- main ----

check_prerequisites
read_backup_creds        # they live in Terraform state, not .env: 10a must have run
enable_in_chart_values
seal_writer_creds

summary
print_result
[ "$FAIL" -eq 0 ]
