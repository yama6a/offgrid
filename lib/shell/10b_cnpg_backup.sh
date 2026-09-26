#!/usr/bin/env bash
# Turns on CNPG S3 backups for every CNPG cluster, through the shared pg-cluster backup overlay.
# pg-cluster renders backups only when the overlay sets `bucket`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
OVERLAY="${REPO_ROOT}/lib/helm/pg-cluster/files/backup.yaml" # the shared backup overlay

# ---- functions ----

check_prerequisites() {
  say "prerequisites"
  require yq kubeseal kubectl terraform
  [ -f "$OVERLAY" ] || die "missing ${OVERLAY}"
  if [ -z "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
    warn "AWS_DEPLOY_ACCESS_KEY_ID is empty in .env, so S3 backups are off. Skipping. The overlay stays as is."
    exit 0
  fi
  [ -n "$AWS_REGION" ] || die "AWS_REGION is empty in .env"
  [ -n "$S3_BACKUP_BUCKET" ] || die "S3_BACKUP_BUCKET is empty in .env"
  ok "tools present, values file found"
}

# The Barman ObjectStore CRD rejects an empty retentionPolicy, so it matches the S3 lifecycle expiry.
write_backup_settings() {
  local retention="${S3_BACKUP_RETENTION_DAYS}d"
  say "writing bucket, region, retention and RPO into ${OVERLAY}"
  ys_set "$OVERLAY" "\"${S3_BACKUP_BUCKET}\"" bucket
  ys_set "$OVERLAY" "\"${AWS_REGION}\"" region
  ys_set "$OVERLAY" "\"${retention}\"" retentionPolicy
  ys_set "$OVERLAY" "\"${CNPG_BACKUP_RPO}\"" archiveTimeout
  [ "$(yq -r '.bucket' "$OVERLAY")" = "$S3_BACKUP_BUCKET" ] && ok "bucket=${S3_BACKUP_BUCKET}" || bad "bucket not set"
  [ "$(yq -r '.region' "$OVERLAY")" = "$AWS_REGION" ] && ok "region=${AWS_REGION}" || bad "region not set"
  [ "$(yq -r '.retentionPolicy' "$OVERLAY")" = "$retention" ] && ok "retentionPolicy=${retention}" || bad "retentionPolicy not set"
  [ "$(yq -r '.archiveTimeout' "$OVERLAY")" = "$CNPG_BACKUP_RPO" ] && ok "archiveTimeout=${CNPG_BACKUP_RPO}" || bad "archiveTimeout not set"
}

# Cluster-wide scope lets pg-cluster build each database's Secret from this one ciphertext, in any namespace.
# kubeseal_to retries but writes only to a path, so a temp file carries the ciphertext to stdout.
seal_raw() {
  local f
  f="$(mktemp)"
  kubeseal_to "$f" --raw --scope cluster-wide < <(printf %s "$1")
  cat "$f"
  rm -f "$f"
}

seal_writer_creds() {
  local sealed_akid sealed_sak
  say "sealing the S3 creds with cluster-wide scope into ${OVERLAY}"
  use_kubeconfig
  assert_api
  assert_sealed_secrets_ready

  sealed_akid="$(seal_raw "$AKID")"
  sealed_sak="$(seal_raw "$SAK")"
  [ -n "$sealed_akid" ] && [ -n "$sealed_sak" ] || die "kubeseal --raw produced no ciphertext. Is the sealed-secrets controller in ns/${SS_CONTROLLER_NS} up?"
  case "$sealed_akid" in Ag*) ok "ACCESS_KEY_ID sealed" ;; *) bad "ACCESS_KEY_ID ciphertext malformed: no Ag prefix" ;; esac
  case "$sealed_sak" in Ag*) ok "ACCESS_SECRET_KEY sealed" ;; *) bad "ACCESS_SECRET_KEY ciphertext malformed: no Ag prefix" ;; esac

  ys_set "$OVERLAY" "\"${sealed_akid}\"" sealed ACCESS_KEY_ID
  ys_set "$OVERLAY" "\"${sealed_sak}\"" sealed ACCESS_SECRET_KEY
  [ "$(yq -r '.sealed.ACCESS_KEY_ID' "$OVERLAY")" = "$sealed_akid" ] && ok "sealed ACCESS_KEY_ID written" || bad "ACCESS_KEY_ID not written"
  [ "$(yq -r '.sealed.ACCESS_SECRET_KEY' "$OVERLAY")" = "$sealed_sak" ] && ok "sealed ACCESS_SECRET_KEY written" || bad "ACCESS_SECRET_KEY not written"
  { grep -qF "$AKID" "$OVERLAY" || grep -qF "$SAK" "$OVERLAY"; } && bad "plaintext creds in ${OVERLAY}. Do not commit it." || ok "no plaintext creds in overlay"
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Something failed. See above. Fix it and run this script again."
    return 0
  fi
  cat << EOF
CNPG S3 backups on: bucket ${S3_BACKUP_BUCKET}, RPO ${CNPG_BACKUP_RPO}, daily base backup from a standby.
Next:
  - git add -A && git commit && git push   # ArgoCD applies the wave-3 barman plugin, each workload's
                                            # ObjectStore and ScheduledBackup, and the sealed creds, which
                                            # pg-cluster adds to every CNPG namespace
  - verify:  kubectl cnpg status <cluster> -n <ns>   # expect "Continuous Archiving: OK" and a recoverability point
  - restore drill:  make restore-cnpg
EOF
}

# ---- main ----

check_prerequisites
read_backup_creds # from the Terraform state that 10a wrote, not from .env
write_backup_settings
seal_writer_creds

summary
print_result
[ "$FAIL" -eq 0 ]
