#!/usr/bin/env bash
#
# 13_s3_backup_bucket.sh  (macOS)
#
# Manages the shared S3 backup bucket via Terraform (terraform/): the bucket + a bucket-wide lifecycle (land
# in Standard -> Glacier Instant Retrieval at S3_BACKUP_TRANSITION_DAYS -> delete at S3_BACKUP_RETENTION_DAYS),
# SSE, public access blocked, and a scoped IAM writer whose access key is a Terraform output (14_cnpg_backup.sh
# seals it into the cluster). General-purpose: CNPG backups land under cnpg/; longhorn/ + redis/ are reserved.
# See docs/13_backups.md.
#
# Config comes ENTIRELY from the gitignored .env (nothing prompted): the DEPLOYER creds
# (AWS_DEPLOY_ACCESS_KEY_ID / AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET, need s3:* + iam:* to build the bucket/user)
# are exported for the AWS provider + the aws CLI, and AWS_REGION / S3_BACKUP_BUCKET / *_DAYS as TF_VAR_*.
# Empty AWS_DEPLOY_ACCESS_KEY_ID => backups are OFF: every action no-ops (like every secret-gated feature).
#
# Terraform state is LOCAL (terraform/) and holds the IAM secret key, so it is gitignored (repo is public).
# Needs NO cluster (pure AWS).
#
# Actions:
#   apply    (default) : terraform apply — idempotent create/update of the bucket + lifecycle + IAM writer.
#   wipe               : delete ALL objects in the bucket, KEEPING the bucket + IAM (used by a rebuild — a
#                        fresh cluster starts a clean backup history). Does NOT touch Terraform.
#   destroy            : empty the bucket THEN terraform destroy (bucket + IAM gone). Full teardown (reset).
#
# wipe/destroy prompt for a typed confirmation unless ASSUME_YES=1 (set by the DANGEROUS_* orchestrators,
# which already took one up-front confirmation). Standalone `make s3-backup-wipe|destroy` prompt normally.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
TF_DIR="${REPO_ROOT}/terraform"     # the Terraform root (versions/variables/main/outputs.tf)
ACTION="${1:-apply}"                # apply (default) | wipe | destroy
# -----------------------------------------------------------------------------

confirm_or_die() { # <WORD> <warning message>
  [ "${ASSUME_YES:-0}" = 1 ] && return 0
  warn "$2"
  read -r -p ">> type $1 to proceed: " c
  [ "$c" = "$1" ] || die "aborted"
}

empty_bucket() { # delete every object; tolerant of an already-gone bucket (versioning is Disabled)
  if aws s3api head-bucket --bucket "$S3_BACKUP_BUCKET" >/dev/null 2>&1; then
    say "emptying s3://${S3_BACKUP_BUCKET} (deleting ALL backup objects)"
    if aws s3 rm "s3://${S3_BACKUP_BUCKET}" --recursive >/dev/null; then ok "bucket emptied"; else bad "failed to empty bucket"; return 1; fi
  else
    ok "bucket ${S3_BACKUP_BUCKET} does not exist (nothing to empty)"
  fi
}

# === 0. prereqs + gate =======================================================
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

# Provider + CLI auth via the standard AWS_* env (never a committed tfvars).
export AWS_ACCESS_KEY_ID="$AWS_DEPLOY_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET"
export AWS_DEFAULT_REGION="$AWS_REGION"

# === 1. dispatch =============================================================
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
    confirm_or_die WIPE "This DELETES ALL backups in s3://${S3_BACKUP_BUCKET} (the bucket + IAM stay; Terraform untouched)."
    empty_bucket
    ;;
  destroy)
    require aws terraform
    export TF_VAR_region="$AWS_REGION" TF_VAR_bucket="$S3_BACKUP_BUCKET" \
           TF_VAR_transition_days="$S3_BACKUP_TRANSITION_DAYS" TF_VAR_retention_days="$S3_BACKUP_RETENTION_DAYS"
    confirm_or_die DESTROY "This EMPTIES s3://${S3_BACKUP_BUCKET} AND terraform-destroys the bucket + IAM writer (all backups gone)."
    empty_bucket   # force_destroy=false, so we must empty before destroy can remove the bucket
    say "terraform destroy"
    if terraform -chdir="$TF_DIR" init -input=false >/dev/null && terraform -chdir="$TF_DIR" destroy -auto-approve -input=false; then ok "destroyed"; else bad "terraform destroy failed"; fi
    ;;
  *)
    die "unknown action '${ACTION}' (expected: apply | wipe | destroy)"
    ;;
esac

# === 2. summary ==============================================================
summary
if [ "$FAIL" -eq 0 ] && [ "$ACTION" = apply ]; then
  cat <<EOF
S3 backup bucket '${S3_BACKUP_BUCKET}' ready (region ${AWS_REGION}; ->Glacier IR @${S3_BACKUP_TRANSITION_DAYS}d, expire @${S3_BACKUP_RETENTION_DAYS}d).
Next:  bash lib/shell/14_cnpg_backup.sh   # seal the writer creds into the cluster + enable CNPG backups
EOF
fi
[ "$FAIL" -eq 0 ]
