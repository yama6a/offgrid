#!/usr/bin/env bash
# Manages the shared S3 backup bucket via Terraform: the bucket, a bucket-wide lifecycle, encryption at rest,
# public access blocked, and a scoped IAM writer whose access key is a Terraform output the 14-17 scripts seal.
# Terraform state is LOCAL and holds the IAM secret key, so it is gitignored. Needs no cluster.
#
# Actions:
#   apply   (default) idempotent create/update of the bucket, lifecycle and IAM writer.
#   wipe              delete ALL objects, KEEPING the bucket + IAM. Used by a rebuild, so a fresh cluster
#                     starts a clean backup history. Does not touch Terraform.
#   destroy           empty the bucket then terraform destroy. Full teardown.
#
# wipe and destroy prompt for a typed confirmation unless ASSUME_YES=1.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
ACTION="${1:-apply}"                # apply (default) | wipe | destroy

empty_bucket() { # delete every object; tolerant of an already-gone bucket (versioning is Disabled)
  if aws s3api head-bucket --bucket "$S3_BACKUP_BUCKET" >/dev/null 2>&1; then
    say "emptying s3://${S3_BACKUP_BUCKET} (deleting ALL backup objects)"
    if aws s3 rm "s3://${S3_BACKUP_BUCKET}" --recursive >/dev/null; then ok "bucket emptied"; else bad "failed to empty bucket"; return 1; fi
  else
    ok "bucket ${S3_BACKUP_BUCKET} does not exist (nothing to empty)"
  fi
}

say "prerequisites"
[ -f "${TF_DIR}/main.tf" ] || die "no Terraform at ${TF_DIR}"
# Gated on the deployer creds being present (same "empty secret = feature off" contract). No creds => no-op,
# so the orchestrators' best-effort steps are clean no-ops when backups aren't configured.
if [ -z "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
  warn "AWS_DEPLOY_ACCESS_KEY_ID empty in .env -> S3 backups disabled; nothing to ${ACTION}."
  exit 0
fi
[ -n "$AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET" ] || die "AWS_DEPLOY_ACCESS_KEY_ID is set but AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET is empty in .env"
[ -n "$AWS_REGION" ]       || die "AWS_REGION is empty in .env"
[ -n "$S3_BACKUP_BUCKET" ] || die "S3_BACKUP_BUCKET is empty in .env"

# Terraform provider + CLI auth via the standard AWS_* env (never a committed tfvars).
export_deploy_aws_creds

case "$ACTION" in
  apply)
    require terraform
    export TF_VAR_region="$AWS_REGION" TF_VAR_bucket="$S3_BACKUP_BUCKET" \
           TF_VAR_transition_days="$S3_BACKUP_TRANSITION_DAYS" TF_VAR_retention_days="$S3_BACKUP_RETENTION_DAYS"
    say "terraform init + apply (create/update bucket + lifecycle + IAM writer)"
    if terraform -chdir="$TF_DIR" init -input=false >/dev/null; then ok "init ok"; else bad "terraform init failed"; summary; exit 1; fi
    if terraform -chdir="$TF_DIR" apply -auto-approve -input=false; then ok "apply ok"; else bad "terraform apply failed"; fi
    ;;
  wipe)
    require aws
    warn "This DELETES ALL backups in s3://${S3_BACKUP_BUCKET} (the bucket + IAM stay; Terraform untouched)."
    confirm_word WIPE || die "aborted"
    empty_bucket
    ;;
  destroy)
    require aws terraform
    export TF_VAR_region="$AWS_REGION" TF_VAR_bucket="$S3_BACKUP_BUCKET" \
           TF_VAR_transition_days="$S3_BACKUP_TRANSITION_DAYS" TF_VAR_retention_days="$S3_BACKUP_RETENTION_DAYS"
    warn "This EMPTIES s3://${S3_BACKUP_BUCKET} AND terraform-destroys the bucket + IAM writer (all backups gone)."
    confirm_word DESTROY || die "aborted"
    empty_bucket   # force_destroy=false, so we must empty before destroy can remove the bucket
    say "terraform destroy"
    if terraform -chdir="$TF_DIR" init -input=false >/dev/null && terraform -chdir="$TF_DIR" destroy -auto-approve -input=false; then ok "destroyed"; else bad "terraform destroy failed"; fi
    ;;
  *)
    die "unknown action '${ACTION}' (expected: apply | wipe | destroy)"
    ;;
esac

summary
if [ "$FAIL" -eq 0 ] && [ "$ACTION" = apply ]; then
  cat <<EOF
S3 backup bucket '${S3_BACKUP_BUCKET}' ready (region ${AWS_REGION}; ->Glacier IR @${S3_BACKUP_TRANSITION_DAYS}d, expire @${S3_BACKUP_RETENTION_DAYS}d).
Next:  bash lib/shell/10b_cnpg_backup.sh   # seal the writer creds into the cluster + enable CNPG backups
EOF
fi
[ "$FAIL" -eq 0 ]
