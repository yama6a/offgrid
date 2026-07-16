#!/usr/bin/env bash
#
# 15_redis_backup.sh  (macOS)
#
# Turns ON off-cluster Redis RDB backups to S3 (after 13_s3_backup_bucket.sh created the bucket + IAM writer).
# Reuses the SAME bucket + writer as CNPG — Redis dumps just land under the reserved redis/ prefix. Two writes,
# both committable, no plaintext secret in git:
#   1. yq the .env scalars into the SHARED redis-instance wrapper values (lib/helm/redis-instance/values.yaml):
#        backups.bucket + backups.region. Every DURABLE (persistence:true) Redis instance inherits these, so a
#        CronJob renders for each (auto-on); ephemeral instances never back up. Retention is the bucket's S3
#        lifecycle (not set here), unlike CNPG's Barman retentionPolicy.
#   2. seal the Terraform-generated writer creds into a SealedSecret `redis-backup-s3` (data keys
#        AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY — the env names aws-cli reads directly, note this DIFFERS from
#        CNPG's ACCESS_KEY_ID/ACCESS_SECRET_KEY) in EACH namespace that has a durable Redis instance, committed
#        into that workload chart's templates/. The creds come from `terraform output`, never .env.
#
# Empty AWS_DEPLOY_ACCESS_KEY_ID => backups OFF: this no-ops (leaves values as-is), matching 13/14 and the repo's
# "empty secret = feature off" contract. To ADD a namespace to backups, add it to REDIS_BACKUP_TARGETS below.
# The single-key seal_secret helper can't do a 2-key secret, so we inline the same kubeseal pipeline here.
# See docs/12_redis.md and docs/13_backups.md.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
TF_DIR="${REPO_ROOT}/terraform"
REDIS_VALUES="${REPO_ROOT}/lib/helm/redis-instance/values.yaml"   # the SHARED wrapper values (single source)
SECRET_NAME="redis-backup-s3"                                     # == redis-instance values backups.secretName
SECRET_KEY_ID="AWS_ACCESS_KEY_ID"                                 # == the env names the CronJob's aws-cli reads
SECRET_KEY_SECRET="AWS_SECRET_ACCESS_KEY"
# Each namespace with a DURABLE Redis instance gets the sealed creds, committed into ITS chart templates/.
# Format "namespace:relative/path/to/sealedsecret.yaml". Add a line per new namespace that gains one.
REDIS_BACKUP_TARGETS=(
  "sample-user-manager:argo_apps/workloads/charts/sample_user_manager/templates/redis-backup-s3-sealedsecret.yaml"
)
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
[ -f "$REDIS_VALUES" ] || die "missing ${REDIS_VALUES}"

if [ -z "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
  warn "AWS_DEPLOY_ACCESS_KEY_ID empty in .env -> S3 backups disabled; skipping (redis-instance values left as-is)."
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

# === 2. inject the scalars into the shared redis-instance values =============
say "injecting bucket/region into ${REDIS_VALUES} (durable instances auto-render a backup CronJob)"
BUCKET="$S3_BACKUP_BUCKET" REGION="$AWS_REGION" yq -i '
  .backups.bucket = strenv(BUCKET)
  | .backups.region = strenv(REGION)
' "$REDIS_VALUES"
# verify the writes round-tripped
[ "$(yq -r '.backups.bucket' "$REDIS_VALUES")" = "$S3_BACKUP_BUCKET" ] && ok "backups.bucket=${S3_BACKUP_BUCKET}" || bad "bucket not set"
[ "$(yq -r '.backups.region' "$REDIS_VALUES")" = "$AWS_REGION" ]       && ok "backups.region=${AWS_REGION}"       || bad "region not set"

# === 3. seal the creds into each namespace with a durable Redis ==============
say "sealing S3 creds into each Redis namespace"
use_kubeconfig
assert_api
kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" >/dev/null 2>&1 \
  || die "sealed-secrets controller not reachable in ns/${SS_CONTROLLER_NS}, is step 02 synced?"
for t in "${REDIS_BACKUP_TARGETS[@]}"; do
  ns="${t%%:*}"; rel="${t#*:}"
  seal_s3_creds "$ns" "${REPO_ROOT}/${rel}"
done

# === 4. summary ==============================================================
summary
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
Redis S3 backups enabled (bucket ${S3_BACKUP_BUCKET}, prefix redis/, daily by default; per-instance schedule via
backups.schedule). Every durable (persistence:true) instance now renders a <name>-redis-backup CronJob.
Next:
  - refresh consumer locks:  helm dependency update argo_apps/workloads/charts/sample_user_manager   # commit Chart.lock
  - git add -A && git commit && git push   # ArgoCD applies the CronJob + backup netpol + the sealed creds.
  - verify:  kubectl -n <ns> create job --from=cronjob/<name>-redis-backup <name>-redis-backup-manual
             aws s3 ls s3://${S3_BACKUP_BUCKET}/redis/ --recursive
  - restore drill:  make restore-redis
EOF
else
  echo "Something failed, see above. Fix and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
