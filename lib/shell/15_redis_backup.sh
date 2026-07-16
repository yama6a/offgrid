#!/usr/bin/env bash
#
# 15_redis_backup.sh  (macOS)
#
# Turns ON off-cluster Redis RDB backups to S3 (after 13_s3_backup_bucket.sh created the bucket + IAM writer).
# Reuses the SAME bucket + writer as CNPG — Redis dumps land under the redis/ prefix. Backups are done by ONE
# central CronJob (the platform app 07_redis_backup, ns redis-backup) that discovers every durable Redis instance
# cluster-wide, so there is ONE secret in ONE namespace — no per-namespace list. Two writes, both committable, no
# plaintext secret in git:
#   1. yq the .env scalars into the central chart values (argo_apps/platform/charts/07_redis_backup/values.yaml):
#        bucket + region. An empty bucket means the CronJob doesn't render (feature off); setting it turns the
#        feature ON. Retention is the bucket's S3 lifecycle (not set here).
#   2. seal the Terraform-generated writer creds into a SealedSecret `redis-backup-s3` (data keys
#        AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY — the env names the CronJob's aws-cli reads) in the single
#        `redis-backup` namespace, committed into the central chart's templates/. The creds come from
#        `terraform output`, never .env.
#
# Empty AWS_DEPLOY_ACCESS_KEY_ID => backups OFF: this no-ops (leaves values as-is), matching 13/14 and the repo's
# "empty secret = feature off" contract. The single-key seal_secret helper can't do a 2-key secret, so we inline
# the same kubeseal pipeline here. See docs/12_redis.md and docs/13_backups.md.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
TF_DIR="${REPO_ROOT}/terraform"
RB_CHART_DIR="${REPO_ROOT}/argo_apps/platform/charts/07_redis_backup"
RB_VALUES="${RB_CHART_DIR}/values.yaml"                     # the central chart values (single source)
RB_NAMESPACE="redis-backup"                                 # the central app's namespace (== app destination)
SEALED_OUT="${RB_CHART_DIR}/templates/redis-backup-s3-sealedsecret.yaml"
SECRET_NAME="redis-backup-s3"                               # == values secretName; the CronJob mounts it
SECRET_KEY_ID="AWS_ACCESS_KEY_ID"                          # == the env names the CronJob's aws-cli reads
SECRET_KEY_SECRET="AWS_SECRET_ACCESS_KEY"
# -----------------------------------------------------------------------------

# 2-key SealedSecret (seal_secret in common.sh is single-key). Mirrors its controller/scope flags + checks.
seal_s3_creds() { # <namespace> <out-file>
  local ns="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  if kubectl create secret generic "$SECRET_NAME" -n "$ns" --dry-run=client -o yaml \
        --from-literal="${SECRET_KEY_ID}=${AKID}" \
        --from-literal="${SECRET_KEY_SECRET}=${SAK}" \
     | kubeseal --controller-namespace "$SS_CONTROLLER_NS" --controller-name "$SS_CONTROLLER_NAME" \
         --format yaml --scope strict > "${out}.tmp" 2>/dev/null; then
    mv "${out}.tmp" "$out"; ok "sealed ${SECRET_NAME} -> ${out} (ns ${ns})"
  else
    rm -f "${out}.tmp"; bad "kubeseal failed for ns ${ns} (controller sealed-secrets/${SS_CONTROLLER_NS} up?)"; return 1
  fi
  grep -q 'kind: SealedSecret' "$out" && ok "output is a SealedSecret" || bad "not a SealedSecret manifest"
  grep -q "$SECRET_KEY_ID" "$out" && grep -q "$SECRET_KEY_SECRET" "$out" && ok "both keys present" || bad "a data key is missing"
  { grep -qF "$AKID" "$out" || grep -qF "$SAK" "$out"; } && bad "PLAINTEXT creds in output, DO NOT COMMIT" || ok "no plaintext creds in output"
}

# === 0. prereqs ==============================================================
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

# === 1. read the writer creds from Terraform output ==========================
# 13 must have run (bucket + IAM writer created). The creds live in Terraform state, NOT .env. Same writer as CNPG.
say "reading backup-writer creds from terraform output"
AKID="$(terraform -chdir="$TF_DIR" output -raw backup_access_key_id 2>/dev/null)" || true
SAK="$(terraform -chdir="$TF_DIR" output -raw backup_secret_access_key 2>/dev/null)" || true
[ -n "$AKID" ] && [ -n "$SAK" ] || die "no Terraform outputs — run 13_s3_backup_bucket.sh first (and it must have applied)"
ok "got writer access key id + secret from terraform"

# === 2. inject the scalars into the central chart values =====================
say "enabling backups: injecting bucket/region into ${RB_VALUES} (the CronJob renders once bucket is set)"
BUCKET="$S3_BACKUP_BUCKET" REGION="$AWS_REGION" yq -i '
  .bucket = strenv(BUCKET)
  | .region = strenv(REGION)
' "$RB_VALUES"
# verify the writes round-tripped
[ "$(yq -r '.bucket' "$RB_VALUES")" = "$S3_BACKUP_BUCKET" ] && ok "bucket=${S3_BACKUP_BUCKET}" || bad "bucket not set"
[ "$(yq -r '.region' "$RB_VALUES")" = "$AWS_REGION" ]       && ok "region=${AWS_REGION}"       || bad "region not set"

# === 3. seal the creds into the single redis-backup namespace ================
say "sealing S3 creds into ns ${RB_NAMESPACE}"
use_kubeconfig
assert_api
kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" >/dev/null 2>&1 \
  || die "sealed-secrets controller not reachable in ns/${SS_CONTROLLER_NS}, is step 02 synced?"
seal_s3_creds "$RB_NAMESPACE" "$SEALED_OUT"

# === 4. summary ==============================================================
summary
if [ "$FAIL" -eq 0 ]; then
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
else
  echo "Something failed, see above. Fix and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
