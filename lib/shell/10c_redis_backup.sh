#!/usr/bin/env bash
# Turns ON off-cluster Redis RDB backups: bucket + region into the 07_redis_backup values, writer creds sealed.
# One central CronJob discovers every durable instance cluster-wide, so there is one secret in one namespace.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
RB_CHART_DIR="${PLATFORM_CHARTS}/07_redis_backup"
RB_VALUES="${RB_CHART_DIR}/values.yaml"                     # the central chart values (single source)
RB_NAMESPACE="redis-backup"                                 # == the app destination
SEALED_OUT="${RB_CHART_DIR}/templates/redis-backup-s3-sealedsecret.yaml"
SECRET_NAME="redis-backup-s3"                               # == values secretName; the CronJob mounts it
SECRET_KEY_ID="AWS_ACCESS_KEY_ID"                           # == the env names the CronJob's aws-cli reads
SECRET_KEY_SECRET="AWS_SECRET_ACCESS_KEY"

# ---- functions ----

check_prerequisites() {
  say "prerequisites"
  require yq kubeseal kubectl terraform
  [ -f "$RB_VALUES" ] || die "missing ${RB_VALUES}"
  if [ -z "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
    warn "AWS_DEPLOY_ACCESS_KEY_ID empty in .env -> S3 backups disabled; skipping (redis-backup values left as-is)."
    exit 0
  fi
  [ -n "$AWS_REGION" ]       || die "AWS_REGION is empty in .env"
  [ -n "$S3_BACKUP_BUCKET" ] || die "S3_BACKUP_BUCKET is empty in .env"
  ok "tools present, values file found"
}

# An empty bucket means the CronJob does not render, so writing it is what turns backups on.
enable_in_chart_values() {
  say "enabling backups: injecting bucket/region into ${RB_VALUES} (the CronJob renders once bucket is set)"
  ys_set "$RB_VALUES" "\"${S3_BACKUP_BUCKET}\"" bucket
  ys_set "$RB_VALUES" "\"${AWS_REGION}\""       region
  [ "$(yq -r '.bucket' "$RB_VALUES")" = "$S3_BACKUP_BUCKET" ] && ok "bucket=${S3_BACKUP_BUCKET}" || bad "bucket not set"
  [ "$(yq -r '.region' "$RB_VALUES")" = "$AWS_REGION" ]       && ok "region=${AWS_REGION}"       || bad "region not set"
}

seal_writer_creds() {
  say "sealing S3 creds into ns ${RB_NAMESPACE}"
  use_kubeconfig
  assert_api
  assert_sealed_secrets_ready
  seal_secret "$SECRET_NAME" "$RB_NAMESPACE" "$SEALED_OUT" \
    "${SECRET_KEY_ID}=${AKID}" "${SECRET_KEY_SECRET}=${SAK}"
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Something failed, see above. Fix and re-run (idempotent)."
    return 0
  fi
cat <<EOF
Redis S3 backups enabled (bucket ${S3_BACKUP_BUCKET}, prefix redis/, schedule from the chart values). ONE central
CronJob (ns ${RB_NAMESPACE}) backs up every durable (persistence:true) Redis instance automatically.
Next:
  - git add -A && git commit && git push   # ArgoCD applies the 07_redis_backup app (wave 7) + the sealed creds.
  - verify:  kubectl -n ${RB_NAMESPACE} create job --from=cronjob/redis-backup redis-backup-manual
             kubectl -n ${RB_NAMESPACE} logs job/redis-backup-manual -c list -f
             aws s3 ls s3://${S3_BACKUP_BUCKET}/redis/ --recursive
  - restore drill:  make restore-redis
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
