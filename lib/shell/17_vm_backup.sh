#!/usr/bin/env bash
# Turns ON off-cluster VictoriaMetrics and VictoriaLogs backups, after 13 created the bucket and IAM writer.
# Same bucket and writer as the others, under the vm/ prefix. ONE central CronJob exports both stores over
# HTTP, so there is ONE secret in ONE namespace.
# Writes bucket + region into the 08_vm_backup chart values (empty bucket means nothing renders) and seals
# the writer creds as `vm-backup-s3`.
# Inlines the kubeseal pipeline because seal_secret cannot do a 2-key Secret.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
TF_DIR="${REPO_ROOT}/terraform"
VB_CHART_DIR="${REPO_ROOT}/argo_apps/platform/charts/08_vm_backup"
VB_VALUES="${VB_CHART_DIR}/values.yaml"                     # the central chart values (single source)
VB_NAMESPACE="monitoring"                                  # the central app's namespace (== app destination, == where the stores live)
SEALED_OUT="${VB_CHART_DIR}/templates/vm-backup-s3-sealedsecret.yaml"
SECRET_NAME="vm-backup-s3"                                 # == values secretName; the CronJob mounts it
SECRET_KEY_ID="AWS_ACCESS_KEY_ID"                          # == the env names the CronJob's aws-cli reads
SECRET_KEY_SECRET="AWS_SECRET_ACCESS_KEY"

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

say "prerequisites"
require yq kubeseal kubectl terraform
[ -f "$VB_VALUES" ] || die "missing ${VB_VALUES}"

if [ -z "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
  warn "AWS_DEPLOY_ACCESS_KEY_ID empty in .env -> S3 backups disabled; skipping (vm-backup values left as-is)."
  exit 0
fi
[ -n "$AWS_REGION" ]       || die "AWS_REGION is empty in .env"
[ -n "$S3_BACKUP_BUCKET" ] || die "S3_BACKUP_BUCKET is empty in .env"
ok "tools present, values file found"

# 13 must have run (bucket + IAM writer created). The creds live in Terraform state, NOT .env. Same writer as CNPG.
say "reading backup-writer creds from terraform output"
AKID="$(terraform -chdir="$TF_DIR" output -raw backup_access_key_id 2>/dev/null)" || true
SAK="$(terraform -chdir="$TF_DIR" output -raw backup_secret_access_key 2>/dev/null)" || true
[ -n "$AKID" ] && [ -n "$SAK" ] || die "no Terraform outputs: run 13_s3_backup_bucket.sh first (and it must have applied)"
ok "got writer access key id + secret from terraform"

say "enabling backups: injecting bucket/region into ${VB_VALUES} (the CronJob renders once bucket is set)"
ys_set "$VB_VALUES" "\"${S3_BACKUP_BUCKET}\"" bucket
ys_set "$VB_VALUES" "\"${AWS_REGION}\""       region
# verify the writes round-tripped
[ "$(yq -r '.bucket' "$VB_VALUES")" = "$S3_BACKUP_BUCKET" ] && ok "bucket=${S3_BACKUP_BUCKET}" || bad "bucket not set"
[ "$(yq -r '.region' "$VB_VALUES")" = "$AWS_REGION" ]       && ok "region=${AWS_REGION}"       || bad "region not set"

say "sealing S3 creds into ns ${VB_NAMESPACE}"
use_kubeconfig
assert_api
kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" >/dev/null 2>&1 \
  || die "sealed-secrets controller not reachable in ns/${SS_CONTROLLER_NS}, is step 02 synced?"
seal_s3_creds "$VB_NAMESPACE" "$SEALED_OUT"

summary
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
VictoriaMetrics + VictoriaLogs S3 backups enabled (bucket ${S3_BACKUP_BUCKET}, prefix vm/, schedule from the chart
values). ONE central CronJob (ns ${VB_NAMESPACE}) exports both stores automatically.
Next:
  - git add -A && git commit && git push   # ArgoCD applies the 08_vm_backup app (wave 8) + the sealed creds.
  - verify:  kubectl -n ${VB_NAMESPACE} create job --from=cronjob/vm-backup vm-backup-manual
             kubectl -n ${VB_NAMESPACE} logs job/vm-backup-manual -f
             aws s3 ls s3://${S3_BACKUP_BUCKET}/vm/ --recursive
  - restore drill:  make restore-vm
EOF
else
  echo "Something failed, see above. Fix and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
