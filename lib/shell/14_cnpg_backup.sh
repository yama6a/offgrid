#!/usr/bin/env bash
# Turns ON CNPG S3 backups, after 13 created the bucket and IAM writer. Writes the .env scalars and the
# sealed Terraform writer creds into the SHARED pg-cluster overlay (lib/helm/pg-cluster/files/backup.yaml),
# which every CNPG cluster in every workload reads, so backups go on fleet-wide.
# A populated overlay IS the opt-in: pg-cluster gates on `bucket`. The creds are sealed cluster-wide ONCE,
# so pg-cluster can stamp each DB's own Secret from the same ciphertext and a new Postgres workload needs no
# change here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
TF_DIR="${REPO_ROOT}/terraform"
OVERLAY="${REPO_ROOT}/lib/helm/pg-cluster/files/backup.yaml"    # the SHARED backup overlay (single source)

# One cluster-wide raw ciphertext per value (controller flags mirror common.sh's seal_secret). Cluster-wide =>
# the same blob unseals into ANY name in ANY namespace, so we seal ONCE into the shared overlay.
seal_raw() { # <plaintext> -> ciphertext on stdout
  printf %s "$1" | kubeseal --controller-namespace "$SS_CONTROLLER_NS" --controller-name "$SS_CONTROLLER_NAME" \
    --raw --scope cluster-wide 2>/dev/null
}

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

# 13 must have run (bucket + IAM writer created). The creds live in Terraform state, NOT .env.
say "reading backup-writer creds from terraform output"
AKID="$(terraform -chdir="$TF_DIR" output -raw backup_access_key_id 2>/dev/null)" || true
SAK="$(terraform -chdir="$TF_DIR" output -raw backup_secret_access_key 2>/dev/null)" || true
[ -n "$AKID" ] && [ -n "$SAK" ] || die "no Terraform outputs: run 13_s3_backup_bucket.sh first (and it must have applied)"
ok "got writer access key id + secret from terraform"

say "injecting bucket/region/RPO into ${OVERLAY}"
# Barman's ObjectStore retentionPolicy must be a non-empty duration (the CRD rejects null/empty); align it to the
# S3 lifecycle expiry so the two agree. Format: "<days>d" (e.g. 180d).
RETENTION="${S3_BACKUP_RETENTION_DAYS}d"
ys_set "$OVERLAY" "\"${S3_BACKUP_BUCKET}\"" bucket
ys_set "$OVERLAY" "\"${AWS_REGION}\""       region
ys_set "$OVERLAY" "\"${RETENTION}\""        retentionPolicy
ys_set "$OVERLAY" "\"${CNPG_BACKUP_RPO}\""  archiveTimeout
# verify the writes round-tripped
[ "$(yq -r '.bucket' "$OVERLAY")" = "$S3_BACKUP_BUCKET" ] && ok "bucket=${S3_BACKUP_BUCKET}" || bad "bucket not set"
[ "$(yq -r '.region' "$OVERLAY")" = "$AWS_REGION" ]       && ok "region=${AWS_REGION}"       || bad "region not set"
[ "$(yq -r '.retentionPolicy' "$OVERLAY")" = "$RETENTION" ]  && ok "retentionPolicy=${RETENTION}"  || bad "retentionPolicy not set"
[ "$(yq -r '.archiveTimeout' "$OVERLAY")" = "$CNPG_BACKUP_RPO" ] && ok "archiveTimeout=${CNPG_BACKUP_RPO}" || bad "archiveTimeout not set"

say "sealing S3 creds (cluster-wide) into ${OVERLAY}"
use_kubeconfig
assert_api
kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" >/dev/null 2>&1 \
  || die "sealed-secrets controller not reachable in ns/${SS_CONTROLLER_NS}, is step 02 synced?"

SEALED_AKID="$(seal_raw "$AKID")"
SEALED_SAK="$(seal_raw "$SAK")"
[ -n "$SEALED_AKID" ] && [ -n "$SEALED_SAK" ] || die "kubeseal --raw produced no ciphertext (controller sealed-secrets/${SS_CONTROLLER_NS} up?)"
case "$SEALED_AKID" in Ag*) ok "ACCESS_KEY_ID sealed" ;; *) bad "ACCESS_KEY_ID ciphertext malformed (no Ag prefix)" ;; esac
case "$SEALED_SAK"  in Ag*) ok "ACCESS_SECRET_KEY sealed" ;; *) bad "ACCESS_SECRET_KEY ciphertext malformed (no Ag prefix)" ;; esac

ys_set "$OVERLAY" "\"${SEALED_AKID}\"" sealed ACCESS_KEY_ID
ys_set "$OVERLAY" "\"${SEALED_SAK}\"" sealed ACCESS_SECRET_KEY
# verify the ciphertext landed, and NO plaintext creds leaked into the committed overlay
[ "$(yq -r '.sealed.ACCESS_KEY_ID' "$OVERLAY")" = "$SEALED_AKID" ]     && ok "sealed ACCESS_KEY_ID written"     || bad "ACCESS_KEY_ID not written"
[ "$(yq -r '.sealed.ACCESS_SECRET_KEY' "$OVERLAY")" = "$SEALED_SAK" ]  && ok "sealed ACCESS_SECRET_KEY written"  || bad "ACCESS_SECRET_KEY not written"
{ grep -qF "$AKID" "$OVERLAY" || grep -qF "$SAK" "$OVERLAY"; } && bad "PLAINTEXT creds in ${OVERLAY}, DO NOT COMMIT" || ok "no plaintext creds in overlay"

summary
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
CNPG S3 backups enabled (bucket ${S3_BACKUP_BUCKET}, RPO ${CNPG_BACKUP_RPO}, daily base backup from standby).
Next:
  - git add -A && git commit && git push   # ArgoCD applies: the barman plugin (platform wave 3) + each
                                            # workload's ObjectStore/ScheduledBackup + the cluster-wide sealed
                                            # creds (auto-added to every CNPG ns by pg-cluster).
  - verify:  kubectl cnpg status <cluster> -n <ns>   # "Continuous Archiving: OK" + a recoverability point
  - restore drill:  make restore-cnpg
EOF
else
  echo "Something failed, see above. Fix and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
