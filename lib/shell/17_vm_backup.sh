#!/usr/bin/env bash
# Turns ON off-cluster VictoriaMetrics and VictoriaLogs backups, after 13 created the bucket and IAM writer.
# Same bucket and writer as the others, under the vm/ prefix. ONE central CronJob exports both stores over
# HTTP, so there is ONE secret in ONE namespace.
# Writes bucket + region into the 08_vm_backup chart values (empty bucket means nothing renders) and seals
# the writer creds as `vm-backup-s3`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
VB_CHART_DIR="${PLATFORM_CHARTS}/08_vm_backup"
VB_VALUES="${VB_CHART_DIR}/values.yaml"                     # the central chart values (single source)
VB_NAMESPACE="monitoring"                                  # the central app's namespace (== app destination, == where the stores live)
SEALED_OUT="${VB_CHART_DIR}/templates/vm-backup-s3-sealedsecret.yaml"
SECRET_NAME="vm-backup-s3"                                 # == values secretName; the CronJob mounts it
SECRET_KEY_ID="AWS_ACCESS_KEY_ID"                          # == the env names the CronJob's aws-cli reads
SECRET_KEY_SECRET="AWS_SECRET_ACCESS_KEY"

say "prerequisites"
require yq kubeseal kubectl terraform
[ -f "$VB_VALUES" ] || die "missing ${VB_VALUES}"

if [ -z "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
  warn "AWS_DEPLOY_ACCESS_KEY_ID empty in .env -> S3 backups disabled; skipping (vm-backup values left as-is)."
  exit 0
fi
[ -n "$AWS_REGION" ]       || die "AWS_REGION is empty in .env"
[ -n "$S3_BACKUP_BUCKET" ] || die "S3_BACKUP_BUCKET is empty in .env"
ok "tools present, values file found"

# The creds live in Terraform state, NOT .env: 13 must have run.
read_backup_creds

say "enabling backups: injecting bucket/region into ${VB_VALUES} (the CronJob renders once bucket is set)"
ys_set "$VB_VALUES" "\"${S3_BACKUP_BUCKET}\"" bucket
ys_set "$VB_VALUES" "\"${AWS_REGION}\""       region
# verify the writes round-tripped
[ "$(yq -r '.bucket' "$VB_VALUES")" = "$S3_BACKUP_BUCKET" ] && ok "bucket=${S3_BACKUP_BUCKET}" || bad "bucket not set"
[ "$(yq -r '.region' "$VB_VALUES")" = "$AWS_REGION" ]       && ok "region=${AWS_REGION}"       || bad "region not set"

say "sealing S3 creds into ns ${VB_NAMESPACE}"
use_kubeconfig
assert_api
assert_sealed_secrets_ready
seal_secret "$SECRET_NAME" "$VB_NAMESPACE" "$SEALED_OUT" \
  "${SECRET_KEY_ID}=${AKID}" "${SECRET_KEY_SECRET}=${SAK}"

summary
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
VictoriaMetrics + VictoriaLogs S3 backups enabled (bucket ${S3_BACKUP_BUCKET}, prefix vm/, schedule from the chart
values). ONE central CronJob (ns ${VB_NAMESPACE}) exports both stores automatically.
Next:
  - git add -A && git commit && git push   # ArgoCD applies the 08_vm_backup app (wave 8) + the sealed creds.
  - verify:  kubectl -n ${VB_NAMESPACE} create job --from=cronjob/vm-backup vm-backup-manual
             kubectl -n ${VB_NAMESPACE} logs job/vm-backup-manual -f
             aws s3 ls s3://${S3_BACKUP_BUCKET}/vm/ --recursive
  - restore drill:  make restore-vm
EOF
else
  echo "Something failed, see above. Fix and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
