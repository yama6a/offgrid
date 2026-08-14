#!/usr/bin/env bash
# Turns ON CNPG S3 backups by populating the SHARED pg-cluster overlay, which every CNPG cluster in every
# workload reads, so backups go on fleet-wide. A populated overlay IS the opt-in: pg-cluster gates on `bucket`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
OVERLAY="${REPO_ROOT}/lib/helm/pg-cluster/files/backup.yaml"    # the SHARED backup overlay (single source)

# ---- functions ----

check_prerequisites() {
  say "prerequisites"
  require yq kubeseal kubectl terraform
  [ -f "$OVERLAY" ] || die "missing ${OVERLAY}"
  if [ -z "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
    warn "AWS_DEPLOY_ACCESS_KEY_ID empty in .env -> S3 backups disabled; skipping (overlay left as-is)."
    exit 0
  fi
  [ -n "$AWS_REGION" ]       || die "AWS_REGION is empty in .env"
  [ -n "$S3_BACKUP_BUCKET" ] || die "S3_BACKUP_BUCKET is empty in .env"
  ok "tools present, values file found"
}

# Barman's ObjectStore retentionPolicy must be a non-empty duration (the CRD rejects null/empty), so align it
# to the S3 lifecycle expiry and the two agree. Format: "<days>d".
write_backup_settings() {
  local retention="${S3_BACKUP_RETENTION_DAYS}d"
  say "injecting bucket/region/RPO into ${OVERLAY}"
  ys_set "$OVERLAY" "\"${S3_BACKUP_BUCKET}\"" bucket
  ys_set "$OVERLAY" "\"${AWS_REGION}\""       region
  ys_set "$OVERLAY" "\"${retention}\""        retentionPolicy
  ys_set "$OVERLAY" "\"${CNPG_BACKUP_RPO}\""  archiveTimeout
  [ "$(yq -r '.bucket' "$OVERLAY")" = "$S3_BACKUP_BUCKET" ] && ok "bucket=${S3_BACKUP_BUCKET}" || bad "bucket not set"
  [ "$(yq -r '.region' "$OVERLAY")" = "$AWS_REGION" ]       && ok "region=${AWS_REGION}"       || bad "region not set"
  [ "$(yq -r '.retentionPolicy' "$OVERLAY")" = "$retention" ]  && ok "retentionPolicy=${retention}"  || bad "retentionPolicy not set"
  [ "$(yq -r '.archiveTimeout' "$OVERLAY")" = "$CNPG_BACKUP_RPO" ] && ok "archiveTimeout=${CNPG_BACKUP_RPO}" || bad "archiveTimeout not set"
}

# Cluster-wide, so the same blob unseals into ANY name in ANY namespace: pg-cluster stamps each DB's own
# Secret from this one ciphertext and a new Postgres workload needs no change here.
# Goes through kubeseal_to for its retry, hence the temp file: that helper writes to a path, and here we want
# the ciphertext on stdout.
seal_raw() {
  local f; f="$(mktemp)"
  kubeseal_to "$f" --raw --scope cluster-wide < <(printf %s "$1")
  cat "$f"; rm -f "$f"
}

seal_writer_creds() {
  local sealed_akid sealed_sak
  say "sealing S3 creds (cluster-wide) into ${OVERLAY}"
  use_kubeconfig
  assert_api
  assert_sealed_secrets_ready

  sealed_akid="$(seal_raw "$AKID")"
  sealed_sak="$(seal_raw "$SAK")"
  [ -n "$sealed_akid" ] && [ -n "$sealed_sak" ] || die "kubeseal --raw produced no ciphertext (controller sealed-secrets/${SS_CONTROLLER_NS} up?)"
  case "$sealed_akid" in Ag*) ok "ACCESS_KEY_ID sealed" ;; *) bad "ACCESS_KEY_ID ciphertext malformed (no Ag prefix)" ;; esac
  case "$sealed_sak"  in Ag*) ok "ACCESS_SECRET_KEY sealed" ;; *) bad "ACCESS_SECRET_KEY ciphertext malformed (no Ag prefix)" ;; esac

  ys_set "$OVERLAY" "\"${sealed_akid}\"" sealed ACCESS_KEY_ID
  ys_set "$OVERLAY" "\"${sealed_sak}\"" sealed ACCESS_SECRET_KEY
  [ "$(yq -r '.sealed.ACCESS_KEY_ID' "$OVERLAY")" = "$sealed_akid" ]     && ok "sealed ACCESS_KEY_ID written"     || bad "ACCESS_KEY_ID not written"
  [ "$(yq -r '.sealed.ACCESS_SECRET_KEY' "$OVERLAY")" = "$sealed_sak" ]  && ok "sealed ACCESS_SECRET_KEY written"  || bad "ACCESS_SECRET_KEY not written"
  { grep -qF "$AKID" "$OVERLAY" || grep -qF "$SAK" "$OVERLAY"; } && bad "PLAINTEXT creds in ${OVERLAY}, DO NOT COMMIT" || ok "no plaintext creds in overlay"
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Something failed, see above. Fix and re-run (idempotent)."
    return 0
  fi
cat <<EOF
CNPG S3 backups enabled (bucket ${S3_BACKUP_BUCKET}, RPO ${CNPG_BACKUP_RPO}, daily base backup from standby).
Next:
  - git add -A && git commit && git push   # ArgoCD applies: the barman plugin (platform wave 3) + each
                                            # workload's ObjectStore/ScheduledBackup + the cluster-wide sealed
                                            # creds (auto-added to every CNPG ns by pg-cluster).
  - verify:  kubectl cnpg status <cluster> -n <ns>   # "Continuous Archiving: OK" + a recoverability point
  - restore drill:  make restore-cnpg
EOF
}

# ---- main ----

check_prerequisites
read_backup_creds        # they live in Terraform state, not .env: 10a must have run
write_backup_settings
seal_writer_creds

summary
print_result
[ "$FAIL" -eq 0 ]
