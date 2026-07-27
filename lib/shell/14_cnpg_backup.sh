#!/usr/bin/env bash
#
# 14_cnpg_backup.sh  (macOS)
#
# Turns ON CNPG S3 backups (after 13_s3_backup_bucket.sh has created the bucket + IAM writer). Two writes to the
# SHARED pg-cluster wrapper values (lib/helm/pg-cluster/values.yaml), both committable, no plaintext in git:
#   1. the .env scalars: backups.enabled=true, backups.s3.bucket, backups.s3.region, archive_timeout (RPO). Every
#      CNPG cluster in every workload inherits these (single source of truth), so backups go on fleet-wide.
#   2. the Terraform writer creds, sealed ONCE cluster-wide into backups.secret.sealed (keys ACCESS_KEY_ID +
#      ACCESS_SECRET_KEY). pg-cluster's backup-sealedsecret.yaml then stamps the cnpg-backup-s3 SealedSecret into
#      every CNPG namespace automatically (cluster-wide scope => one ciphertext works everywhere). Creds come from
#      `terraform output`, never .env.
#
# Empty AWS_DEPLOY_ACCESS_KEY_ID => backups OFF: this no-ops (leaves values as-is), matching 13 and the repo's
# "empty secret = feature off" contract. Adding a Postgres workload needs NO change here (the shared secret is
# auto-added). See docs/13_backups.md.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
TF_DIR="${REPO_ROOT}/terraform"
PG_VALUES="${REPO_ROOT}/lib/helm/pg-cluster/values.yaml"    # the SHARED wrapper values (single source)
# -----------------------------------------------------------------------------

# One cluster-wide raw ciphertext per value (controller flags mirror common.sh's seal_secret). Cluster-wide =>
# the same blob unseals into cnpg-backup-s3 in ANY namespace, so we seal ONCE into the shared pg-cluster values.
seal_raw() { # <plaintext> -> ciphertext on stdout
  printf %s "$1" | kubeseal --controller-namespace "$SS_CONTROLLER_NS" --controller-name "$SS_CONTROLLER_NAME" \
    --raw --scope cluster-wide 2>/dev/null
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
# Barman's ObjectStore retentionPolicy must be a non-empty duration (the CRD rejects null/empty); align it to the
# S3 lifecycle expiry so the two agree. Format: "<days>d" (e.g. 180d).
RETENTION="${S3_BACKUP_RETENTION_DAYS}d"
BUCKET="$S3_BACKUP_BUCKET" REGION="$AWS_REGION" RPO="$CNPG_BACKUP_RPO" RETENTION="$RETENTION" yq -i '
  .backups.enabled = true
  | .backups.s3.bucket = strenv(BUCKET)
  | .backups.s3.region = strenv(REGION)
  | .backups.retentionPolicy = strenv(RETENTION)
  | .postgresql.parameters.archive_timeout = strenv(RPO)
' "$PG_VALUES"
# verify the writes round-tripped
[ "$(yq -r '.backups.enabled' "$PG_VALUES")" = "true" ]         && ok "backups.enabled=true"          || bad "enabled not set"
[ "$(yq -r '.backups.s3.bucket' "$PG_VALUES")" = "$S3_BACKUP_BUCKET" ] && ok "s3.bucket=${S3_BACKUP_BUCKET}" || bad "bucket not set"
[ "$(yq -r '.backups.s3.region' "$PG_VALUES")" = "$AWS_REGION" ]       && ok "s3.region=${AWS_REGION}"       || bad "region not set"
[ "$(yq -r '.backups.retentionPolicy' "$PG_VALUES")" = "$RETENTION" ]  && ok "retentionPolicy=${RETENTION}"  || bad "retentionPolicy not set"
[ "$(yq -r '.postgresql.parameters.archive_timeout' "$PG_VALUES")" = "$CNPG_BACKUP_RPO" ] && ok "archive_timeout=${CNPG_BACKUP_RPO}" || bad "archive_timeout not set"

# === 3. seal the creds ONCE (cluster-wide) into the shared values ============
say "sealing S3 creds (cluster-wide) into ${PG_VALUES}"
use_kubeconfig
assert_api
kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" >/dev/null 2>&1 \
  || die "sealed-secrets controller not reachable in ns/${SS_CONTROLLER_NS}, is step 02 synced?"

SEALED_AKID="$(seal_raw "$AKID")"
SEALED_SAK="$(seal_raw "$SAK")"
[ -n "$SEALED_AKID" ] && [ -n "$SEALED_SAK" ] || die "kubeseal --raw produced no ciphertext (controller sealed-secrets/${SS_CONTROLLER_NS} up?)"
case "$SEALED_AKID" in Ag*) ok "ACCESS_KEY_ID sealed" ;; *) bad "ACCESS_KEY_ID ciphertext malformed (no Ag prefix)" ;; esac
case "$SEALED_SAK"  in Ag*) ok "ACCESS_SECRET_KEY sealed" ;; *) bad "ACCESS_SECRET_KEY ciphertext malformed (no Ag prefix)" ;; esac

CT_ID="$SEALED_AKID" CT_SAK="$SEALED_SAK" yq -i '
  .backups.secret.sealed.ACCESS_KEY_ID = strenv(CT_ID)
  | .backups.secret.sealed.ACCESS_SECRET_KEY = strenv(CT_SAK)
' "$PG_VALUES"
# verify the ciphertext landed, and NO plaintext creds leaked into the committed values
[ "$(yq -r '.backups.secret.sealed.ACCESS_KEY_ID' "$PG_VALUES")" = "$SEALED_AKID" ]     && ok "sealed ACCESS_KEY_ID written"     || bad "ACCESS_KEY_ID not written"
[ "$(yq -r '.backups.secret.sealed.ACCESS_SECRET_KEY' "$PG_VALUES")" = "$SEALED_SAK" ]  && ok "sealed ACCESS_SECRET_KEY written"  || bad "ACCESS_SECRET_KEY not written"
{ grep -qF "$AKID" "$PG_VALUES" || grep -qF "$SAK" "$PG_VALUES"; } && bad "PLAINTEXT creds in ${PG_VALUES}, DO NOT COMMIT" || ok "no plaintext creds in values"

# === 4. summary ==============================================================
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
