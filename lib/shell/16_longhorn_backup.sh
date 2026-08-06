#!/usr/bin/env bash
# Turns ON off-cluster Longhorn volume backups, after 13 created the bucket and IAM writer. Same bucket and
# writer as CNPG and Redis, under the longhorn/ prefix.
# NATIVE Longhorn, not a CronJob: the built-in backup target plus RecurringJobs plus the
# longhorn-r2-retained-with-backups class, all inside the existing 02_longhorn app. Only volumes on that
# class are backed up.
# An EMPTY backupTarget means the two BACKUP RecurringJobs do not render; all three StorageClasses and the
# unconditional filesystem-trim job always do. Retention is Longhorn's own RecurringJob `retain`, not an S3
# lifecycle: the longhorn/ prefix is delete-free.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
LH_CHART_DIR="${PLATFORM_CHARTS}/02_longhorn"
LH_VALUES="${LH_CHART_DIR}/values.yaml"                     # the Longhorn wrapper values (single source)
LH_NAMESPACE="longhorn-system"                             # Longhorn's namespace (== the app destination)
SEALED_OUT="${LH_CHART_DIR}/templates/backup-s3-sealedsecret.yaml"
SECRET_NAME="longhorn-backup-s3"                            # == values backupTargetCredentialSecret
SECRET_KEY_ID="AWS_ACCESS_KEY_ID"                          # == the names Longhorn's backup target reads
SECRET_KEY_SECRET="AWS_SECRET_ACCESS_KEY"

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

# The creds live in Terraform state, NOT .env: 13 must have run.
read_backup_creds

# Longhorn's S3 URL is s3://<bucket>@<region>/<prefix>/ (region after @, trailing slash). Setting backupTarget also
# flips the backup StorageClass + RecurringJobs on (they render `{{- if backupTarget }}`). See docs/13_backups.md.
say "enabling backups: injecting backupTarget + credential secret into ${LH_VALUES}"
BACKUP_TARGET="s3://${S3_BACKUP_BUCKET}@${AWS_REGION}/longhorn/"
ys_set "$LH_VALUES" "\"${BACKUP_TARGET}\"" longhorn defaultBackupStore backupTarget
ys_set "$LH_VALUES" "\"${SECRET_NAME}\""   longhorn defaultBackupStore backupTargetCredentialSecret
# verify the writes round-tripped
[ "$(yq -r '.longhorn.defaultBackupStore.backupTarget' "$LH_VALUES")" = "$BACKUP_TARGET" ] \
  && ok "backupTarget=${BACKUP_TARGET}" || bad "backupTarget not set"
[ "$(yq -r '.longhorn.defaultBackupStore.backupTargetCredentialSecret' "$LH_VALUES")" = "$SECRET_NAME" ] \
  && ok "backupTargetCredentialSecret=${SECRET_NAME}" || bad "backupTargetCredentialSecret not set"

say "sealing S3 creds into ns ${LH_NAMESPACE}"
use_kubeconfig
assert_api
assert_sealed_secrets_ready
seal_secret "$SECRET_NAME" "$LH_NAMESPACE" "$SEALED_OUT" \
  "${SECRET_KEY_ID}=${AKID}" "${SECRET_KEY_SECRET}=${SAK}"

summary
if [ "$FAIL" -eq 0 ]; then
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
else
  echo "Something failed, see above. Fix and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
