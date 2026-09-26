#!/usr/bin/env bash
# Turns on off-cluster Redis RDB backups. Writes bucket and region into the 07_redis_backup values and seals the
# writer creds. One CronJob finds every durable instance in the cluster, so one Secret in one namespace is enough.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
RB_CHART_DIR="${PLATFORM_CHARTS}/07_redis_backup"
RB_VALUES="${RB_CHART_DIR}/values.yaml"
RB_NAMESPACE="redis-backup" # must match the app destination
SEALED_OUT="${RB_CHART_DIR}/templates/redis-backup-s3-sealedsecret.yaml"
SECRET_NAME="redis-backup-s3"     # must match secretName in the values. The CronJob mounts it.
SECRET_KEY_ID="AWS_ACCESS_KEY_ID" # env names that aws-cli in the CronJob reads
SECRET_KEY_SECRET="AWS_SECRET_ACCESS_KEY"

# ---- functions ----

check_prerequisites() {
  say "prerequisites"
  require yq kubeseal kubectl terraform
  [ -f "$RB_VALUES" ] || die "missing ${RB_VALUES}"
  if [ -z "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
    warn "AWS_DEPLOY_ACCESS_KEY_ID is empty in .env, so S3 backups are off. Skipping. The redis-backup values stay as is."
    exit 0
  fi
  [ -n "$AWS_REGION" ] || die "AWS_REGION is empty in .env"
  [ -n "$S3_BACKUP_BUCKET" ] || die "S3_BACKUP_BUCKET is empty in .env"
  ok "tools present, values file found"
}

# The CronJob renders only when bucket is set.
enable_in_chart_values() {
  say "turning on backups: writing bucket and region into ${RB_VALUES}"
  ys_set "$RB_VALUES" "\"${S3_BACKUP_BUCKET}\"" bucket
  ys_set "$RB_VALUES" "\"${AWS_REGION}\"" region
  [ "$(yq -r '.bucket' "$RB_VALUES")" = "$S3_BACKUP_BUCKET" ] && ok "bucket=${S3_BACKUP_BUCKET}" || bad "bucket not set"
  [ "$(yq -r '.region' "$RB_VALUES")" = "$AWS_REGION" ] && ok "region=${AWS_REGION}" || bad "region not set"
}

seal_writer_creds() {
  say "sealing the S3 creds into ns/${RB_NAMESPACE}"
  use_kubeconfig
  assert_api
  assert_sealed_secrets_ready
  seal_secret "$SECRET_NAME" "$RB_NAMESPACE" "$SEALED_OUT" \
    "${SECRET_KEY_ID}=${AKID}" "${SECRET_KEY_SECRET}=${SAK}"
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Something failed. See above. Fix it and run this script again."
    return 0
  fi
  cat << EOF
Redis S3 backups on: bucket ${S3_BACKUP_BUCKET}, prefix redis/, schedule from the chart values.
One CronJob in ns/${RB_NAMESPACE} backs up every Redis instance with persistence: true.
Next:
  - git add -A && git commit && git push   # ArgoCD applies the wave-7 07_redis_backup app and the sealed creds
  - verify:  kubectl -n ${RB_NAMESPACE} create job --from=cronjob/redis-backup redis-backup-manual
             kubectl -n ${RB_NAMESPACE} logs job/redis-backup-manual -c list -f
             aws s3 ls s3://${S3_BACKUP_BUCKET}/redis/ --recursive
  - restore drill:  make restore-redis
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
