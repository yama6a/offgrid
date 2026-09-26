#!/usr/bin/env bash
# Manages the shared S3 backup bucket with Terraform: bucket, lifecycle, encryption at rest, blocked public
# access, and a scoped IAM writer. The 10b to 10e scripts seal the writer's access key from a Terraform output.
# The Terraform state is local and holds the IAM secret key, so it is gitignored. Needs no cluster.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat << EOF
10a_s3_backup_bucket.sh [apply|wipe|destroy]
  apply     the default. Create or update the bucket, lifecycle and IAM writer.
  wipe      delete all objects and keep the bucket and IAM writer. A rebuild uses this, so a fresh
            cluster starts a clean backup history. Does not touch Terraform.
  destroy   empty the bucket, then run terraform destroy.

wipe and destroy prompt for a typed confirmation unless ASSUME_YES=1.
EOF
}

# ---- knobs ----
ACTION="${1:-apply}"

# ---- functions ----

# Empty deployer creds turn backups off, so the orchestrators can call this step without backups set up.
check_prerequisites() {
  say "prerequisites"
  [ -f "${TF_DIR}/main.tf" ] || die "no Terraform at ${TF_DIR}"
  if [ -z "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
    warn "AWS_DEPLOY_ACCESS_KEY_ID is empty in .env, so S3 backups are off. Nothing to ${ACTION}."
    exit 0
  fi
  [ -n "$AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET" ] || die "AWS_DEPLOY_ACCESS_KEY_ID is set but AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET is empty in .env"
  [ -n "$AWS_REGION" ] || die "AWS_REGION is empty in .env"
  [ -n "$S3_BACKUP_BUCKET" ] || die "S3_BACKUP_BUCKET is empty in .env"
  export_deploy_aws_creds # the provider and CLI read the standard AWS_* env, never a committed tfvars
}

export_tf_vars() {
  export TF_VAR_region="$AWS_REGION" TF_VAR_bucket="$S3_BACKUP_BUCKET" \
    TF_VAR_transition_days="$S3_BACKUP_TRANSITION_DAYS" TF_VAR_retention_days="$S3_BACKUP_RETENTION_DAYS"
}

# Versioning is off, so a recursive rm is enough.
empty_bucket() {
  if aws s3api head-bucket --bucket "$S3_BACKUP_BUCKET" > /dev/null 2>&1; then
    say "emptying s3://${S3_BACKUP_BUCKET}: deleting all backup objects"
    if aws s3 rm "s3://${S3_BACKUP_BUCKET}" --recursive > /dev/null; then ok "bucket emptied"; else
      bad "failed to empty bucket"
      return 1
    fi
  else
    ok "bucket ${S3_BACKUP_BUCKET} does not exist. Nothing to empty."
  fi
}

do_apply() {
  require terraform
  export_tf_vars
  say "terraform init and apply: bucket, lifecycle and IAM writer"
  if terraform -chdir="$TF_DIR" init -input=false > /dev/null; then ok "init ok"; else
    bad "terraform init failed"
    summary
    exit 1
  fi
  if terraform -chdir="$TF_DIR" apply -auto-approve -input=false; then ok "apply ok"; else bad "terraform apply failed"; fi
}

do_wipe() {
  require aws
  warn "This deletes all backups in s3://${S3_BACKUP_BUCKET}. The bucket, IAM writer and Terraform state stay."
  confirm_word WIPE || die "aborted"
  empty_bucket
}

do_destroy() {
  require aws terraform
  export_tf_vars
  warn "This empties s3://${S3_BACKUP_BUCKET} and destroys the bucket and IAM writer. All backups are lost."
  confirm_word DESTROY || die "aborted"
  empty_bucket # force_destroy is false, so destroy removes only an empty bucket
  say "terraform destroy"
  if terraform -chdir="$TF_DIR" init -input=false > /dev/null && terraform -chdir="$TF_DIR" destroy -auto-approve -input=false; then ok "destroyed"; else bad "terraform destroy failed"; fi
}

print_result() {
  [ "$FAIL" -eq 0 ] && [ "$ACTION" = apply ] || return 0
  cat << EOF
S3 backup bucket '${S3_BACKUP_BUCKET}' ready in ${AWS_REGION}.
Objects move to Glacier IR after ${S3_BACKUP_TRANSITION_DAYS} days and expire after ${S3_BACKUP_RETENTION_DAYS} days.
Next:  bash lib/shell/10b_cnpg_backup.sh   # seals the writer creds into the cluster and turns on CNPG backups
EOF
}

# ---- main ----

case "$ACTION" in -h | --help)
  usage
  exit 0
  ;;
esac

check_prerequisites

case "$ACTION" in
  apply) do_apply ;;
  wipe) do_wipe ;;
  destroy) do_destroy ;;
  *) die "unknown action '${ACTION}'. Expected apply, wipe or destroy." ;;
esac

summary
print_result
[ "$FAIL" -eq 0 ]
