#!/usr/bin/env bash
#
# 14_cnpg_backup.sh  (macOS)
#
# Turns ON CNPG S3 backups (after 13_s3_backup_bucket.sh has created the bucket + IAM writer). Two writes,
# both committable, no plaintext secret in git:
#   1. yq the .env scalars into the SHARED pg-cluster wrapper values (lib/helm/pg-cluster/values.yaml):
#        backups.enabled=true, backups.s3.bucket, backups.s3.region, and archive_timeout (RPO). Every CNPG
#        cluster in every workload inherits these (single source of truth), so this enables backups fleet-wide.
#   2. seal the Terraform-generated writer creds into a SealedSecret `cnpg-backup-s3` (data keys ACCESS_KEY_ID
#        + ACCESS_SECRET_KEY, the two keys the cnpg/cluster ObjectStore references) in EACH CNPG namespace,
#        committed into that workload chart's templates/. The creds come from `terraform output`, never .env.
#
# Empty AWS_DEPLOY_ACCESS_KEY_ID => backups OFF: this no-ops (leaves values as-is), matching 13 and the repo's
# "empty secret = feature off" contract. To ADD a CNPG workload to backups, add it to CNPG_BACKUP_TARGETS below.
# The single-key seal_secret helper can't do a 2-key secret, so we inline the same kubeseal pipeline here.
# See docs/13_backups.md.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
TF_DIR="${REPO_ROOT}/terraform"
PG_VALUES="${REPO_ROOT}/lib/helm/pg-cluster/values.yaml"    # the SHARED wrapper values (single source)
SECRET_NAME="cnpg-backup-s3"                                # == pg-cluster values cluster.backups.secret.name
SECRET_KEY_ID="ACCESS_KEY_ID"                               # == the keys the cnpg/cluster ObjectStore expects
SECRET_KEY_SECRET="ACCESS_SECRET_KEY"
# Each CNPG-consuming workload gets the sealed creds in ITS namespace, committed into ITS chart templates/.
# Format "namespace:relative/path/to/sealedsecret.yaml". Add a line per new Postgres-backed workload.
CNPG_BACKUP_TARGETS=(
  "sample-user-manager:argo_apps/workloads/charts/sample_user_manager/templates/cnpg-backup-s3-sealedsecret.yaml"
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
[ -f "$PG_VALUES" ] || die "missing ${PG_VALUES}"

if [ -z "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
  warn "AWS_DEPLOY_ACCESS_KEY_ID empty in .env -> S3 backups disabled; skipping (pg-cluster values left as-is)."
  exit 0
fi
[ -n "$AWS_REGION" ]       || die "AWS_REGION is empty in .env"
[ -n "$S3_BACKUP_BUCKET" ] || die "S3_BACKUP_BUCKET is empty in .env"
ok "tools present, values file found"

# === 1. read the writer creds from Terraform output ==========================
# 13 must have run (bucket + IAM writer created). The creds live in Terraform state, NOT .env.
say "reading backup-writer creds from terraform output"
AKID="$(terraform -chdir="$TF_DIR" output -raw backup_access_key_id 2>/dev/null)" || true
SAK="$(terraform -chdir="$TF_DIR" output -raw backup_secret_access_key 2>/dev/null)" || true
[ -n "$AKID" ] && [ -n "$SAK" ] || die "no Terraform outputs — run 13_s3_backup_bucket.sh first (and it must have applied)"
ok "got writer access key id + secret from terraform"

# === 2. inject the scalars into the shared pg-cluster values =================
say "enabling backups + injecting bucket/region/RPO into ${PG_VALUES}"
BUCKET="$S3_BACKUP_BUCKET" REGION="$AWS_REGION" RPO="$CNPG_BACKUP_RPO" yq -i '
  .cluster.backups.enabled = true
  | .cluster.backups.s3.bucket = strenv(BUCKET)
  | .cluster.backups.s3.region = strenv(REGION)
  | .cluster.cluster.postgresql.parameters.archive_timeout = strenv(RPO)
' "$PG_VALUES"
# verify the writes round-tripped
[ "$(yq -r '.cluster.backups.enabled' "$PG_VALUES")" = "true" ]         && ok "backups.enabled=true"          || bad "enabled not set"
[ "$(yq -r '.cluster.backups.s3.bucket' "$PG_VALUES")" = "$S3_BACKUP_BUCKET" ] && ok "s3.bucket=${S3_BACKUP_BUCKET}" || bad "bucket not set"
[ "$(yq -r '.cluster.backups.s3.region' "$PG_VALUES")" = "$AWS_REGION" ]       && ok "s3.region=${AWS_REGION}"       || bad "region not set"
[ "$(yq -r '.cluster.cluster.postgresql.parameters.archive_timeout' "$PG_VALUES")" = "$CNPG_BACKUP_RPO" ] && ok "archive_timeout=${CNPG_BACKUP_RPO}" || bad "archive_timeout not set"

# === 3. seal the creds into each CNPG namespace ==============================
say "sealing S3 creds into each CNPG namespace"
use_kubeconfig
assert_api
kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" >/dev/null 2>&1 \
  || die "sealed-secrets controller not reachable in ns/${SS_CONTROLLER_NS}, is step 02 synced?"
for t in "${CNPG_BACKUP_TARGETS[@]}"; do
  ns="${t%%:*}"; rel="${t#*:}"
  seal_s3_creds "$ns" "${REPO_ROOT}/${rel}"
done

# === 4. summary ==============================================================
summary
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
CNPG S3 backups enabled (bucket ${S3_BACKUP_BUCKET}, RPO ${CNPG_BACKUP_RPO}, daily base backup from standby).
Next:
  - git add -A && git commit && git push   # ArgoCD applies: the barman plugin (platform wave 3) + each
                                            # workload's ObjectStore/ScheduledBackup + the sealed creds.
  - verify:  kubectl cnpg status <cluster> -n <ns>   # "Continuous Archiving: OK" + a recoverability point
  - restore drill:  make restore-cnpg
EOF
else
  echo "Something failed, see above. Fix and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
