#!/usr/bin/env bash
# Turns on off-cluster VictoriaMetrics and VictoriaLogs backups. Writes bucket and region into the 08_vm_backup
# values and seals the writer creds. One CronJob exports both stores over HTTP, so one Secret is enough.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
VB_CHART_DIR="${PLATFORM_CHARTS}/08_vm_backup"
VB_VALUES="${VB_CHART_DIR}/values.yaml"
VB_NAMESPACE="monitoring" # must match the app destination. The stores run here too.
SEALED_OUT="${VB_CHART_DIR}/templates/vm-backup-s3-sealedsecret.yaml"
SECRET_NAME="vm-backup-s3"        # must match secretName in the values. The CronJob mounts it.
SECRET_KEY_ID="AWS_ACCESS_KEY_ID" # env names that aws-cli in the CronJob reads
SECRET_KEY_SECRET="AWS_SECRET_ACCESS_KEY"

# ---- functions ----

check_prerequisites() {
  say "prerequisites"
  require yq kubeseal kubectl terraform
  [ -f "$VB_VALUES" ] || die "missing ${VB_VALUES}"
  if [ -z "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
    warn "AWS_DEPLOY_ACCESS_KEY_ID is empty in .env, so S3 backups are off. Skipping. The vm-backup values stay as is."
    exit 0
  fi
  [ -n "$AWS_REGION" ] || die "AWS_REGION is empty in .env"
  [ -n "$S3_BACKUP_BUCKET" ] || die "S3_BACKUP_BUCKET is empty in .env"
  ok "tools present, values file found"
}

# The chart renders nothing until bucket is set.
enable_in_chart_values() {
  say "turning on backups: writing bucket and region into ${VB_VALUES}"
  ys_set "$VB_VALUES" "\"${S3_BACKUP_BUCKET}\"" bucket
  ys_set "$VB_VALUES" "\"${AWS_REGION}\"" region
  [ "$(yq -r '.bucket' "$VB_VALUES")" = "$S3_BACKUP_BUCKET" ] && ok "bucket=${S3_BACKUP_BUCKET}" || bad "bucket not set"
  [ "$(yq -r '.region' "$VB_VALUES")" = "$AWS_REGION" ] && ok "region=${AWS_REGION}" || bad "region not set"
}

seal_writer_creds() {
  say "sealing the S3 creds into ns/${VB_NAMESPACE}"
  use_kubeconfig
  assert_api
  assert_sealed_secrets_ready
  seal_secret "$SECRET_NAME" "$VB_NAMESPACE" "$SEALED_OUT" \
    "${SECRET_KEY_ID}=${AKID}" "${SECRET_KEY_SECRET}=${SAK}"
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Something failed. See above. Fix it and run this script again."
    return 0
  fi
  cat << EOF
VictoriaMetrics and VictoriaLogs S3 backups on: bucket ${S3_BACKUP_BUCKET}, prefix vm/, schedule from the chart values.
One CronJob in ns/${VB_NAMESPACE} exports both stores.
Next:
  - git add -A && git commit && git push   # ArgoCD applies the wave-8 08_vm_backup app and the sealed creds
  - verify:  kubectl -n ${VB_NAMESPACE} create job --from=cronjob/vm-backup vm-backup-manual
             kubectl -n ${VB_NAMESPACE} logs job/vm-backup-manual -f
             aws s3 ls s3://${S3_BACKUP_BUCKET}/vm/ --recursive
  - restore drill:  make restore-vm
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
