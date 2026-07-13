#!/usr/bin/env bash
#
# recover_cnpg_from_pv.sh  (macOS)
#
# Reattach a CloudNativePG database to its RETAINED node-local volume after the Cluster CR was
# (accidentally) deleted. This is the FAST LOCAL recovery path, one of two DR tiers (see docs/13_backups.md):
#   - THIS (PV-reattach): the bytes still exist on-node (only the Cluster CR was lost) — reattach in seconds,
#     no S3 round-trip, no data transfer. Use it whenever the local PV survived.
#   - recover_cnpg_from_s3.sh: the data is genuinely gone (node/disk loss, corruption, PITR, full rebuild) —
#     restore from the off-cluster S3 backups (continuous WAL + daily base) into a fresh cluster.
# Durability rests on Postgres replication + `local-path` reclaimPolicy: Retain (a lost Cluster CR leaves the
# data as an orphaned PersistentVolume under /var/mnt/localpath), WITH S3 as the backstop when even that's gone.
#
# Why a script and not just `kubectl apply`: two repo-specific facts make the naive "re-add the manifest"
# flow destroy data instead of recovering it —
#   1. The Cluster is delivered by the AUTOMATED (prune + selfHeal) ArgoCD app `sample-user-manager`. Delete
#      the CR and ArgoCD recreates it within a reconcile; CNPG then runs `initdb` on a BRAND-NEW empty PVC
#      (initdb only runs on first bootstrap). So we must PAUSE auto-sync before touching anything.
#   2. The operator adopts existing data instead of bootstrapping ONLY if it finds a `ready` PVC with the
#      expected name/labels BEFORE it reconciles. So we recreate that PVC, bound to the retained PV, first.
#
# What it does: pause the ArgoCD app -> list Released CNPG PVs -> you pick the one holding the primary's
# data -> clear its claimRef and recreate `<cluster>-1` pinned to it (with the adoption metadata) -> print
# the steps to re-enable sync so the operator adopts it, then scale + clean up.
#
# Recovers a SINGLE instance on purpose (see docs/08_storage.md / 10_sample_workload.md): bring the primary
# up from real data, verify, then scale back to 2 so the replica is re-cloned via streaming replication.
# NEVER reattach an old replica PV as well — divergent timelines risk corruption. Node-local storage means
# the PV carries nodeAffinity, so the recovered primary is pinned back to the node that holds its bytes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"             # common.sh is a sibling in lib/shell/

# ---- knobs ----
# The single AUTOMATED ArgoCD app that delivers both CNPG Clusters (maindb + analyticsdb). Pausing it stops
# selfHeal from recreating an empty cluster while we reattach. Not in .env: this is recovery-tool-local.
ARGOCD_NS="argocd"
ARGOCD_APP="sample-user-manager"
STORAGE_CLASS="local-path"                   # pg-cluster hardcodes this class; filter PVs to it so we can't
                                             # accidentally list a Longhorn/other PV that happens to end in -N.
APP_MANIFEST="argo_apps/workloads/apps/sample_user_manager.yaml"   # git source of the app (restores automated)

require kubectl
use_kubeconfig
assert_api

say "CNPG volume recovery — reattach a deleted Cluster to its retained local-path PV"
warn "Fast local path (the PV still holds the data). If the data is truly gone, use recover_cnpg_from_s3.sh instead."

# ---- 1. pause ArgoCD auto-sync (else selfHeal recreates an EMPTY cluster over the top) ----------------
if ! kubectl -n "$ARGOCD_NS" get application "$ARGOCD_APP" >/dev/null 2>&1; then
  die "ArgoCD app ${ARGOCD_NS}/${ARGOCD_APP} not found — is this the right cluster / is ArgoCD up?"
fi
AUTOMATED="$(kubectl -n "$ARGOCD_NS" get application "$ARGOCD_APP" \
  -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null || true)"
if [ -n "$AUTOMATED" ]; then
  warn "ArgoCD app ${ARGOCD_APP} is AUTOMATED (selfHeal). It must be paused before we reattach."
  read -rp "Pause auto-sync on ${ARGOCD_APP} now? [y/N]: " OK
  [[ "$OK" =~ ^[Yy]$ ]] || die "Aborted — pause it by hand and re-run: kubectl -n ${ARGOCD_NS} patch application ${ARGOCD_APP} --type merge -p '{\"spec\":{\"syncPolicy\":{\"automated\":null}}}'"
  kubectl -n "$ARGOCD_NS" patch application "$ARGOCD_APP" --type merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}'
  ok "auto-sync paused (selfHeal + prune off until you restore it)"
else
  ok "auto-sync already paused on ${ARGOCD_APP}"
fi

# ---- 2. list Released CNPG PVs ------------------------------------------------------------------------
# CNPG PVC names are `<cluster>-<serial>` (plus `<cluster>-<serial>-wal` if separate WAL storage, which we
# don't use). A Released PV keeps its old claimRef, so it tells us cluster + serial + namespace + node.
say "Released ${STORAGE_CLASS} PVs previously claimed by a CNPG cluster:"
mapfile -t ROWS < <(
  kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.spec.claimRef.namespace}{"\t"}{.spec.claimRef.name}{"\t"}{.spec.capacity.storage}{"\t"}{.spec.storageClassName}{"\t"}{.spec.persistentVolumeReclaimPolicy}{"\t"}{.metadata.creationTimestamp}{"\t"}{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}{"\n"}{end}' \
  | awk -F'\t' -v sc="$STORAGE_CLASS" '
      $2=="Released" && $6==sc && $4 ~ /-[0-9]+$/ && $4 !~ /-wal$/ { print }' \
  | sort -t$'\t' -k8   # oldest first: the pre-accident data volume sorts above any empty re-bootstrap PV
)

[[ ${#ROWS[@]} -gt 0 ]] || die "No Released ${STORAGE_CLASS} CNPG PVs found. Nothing to recover (or the class isn't Retain)."

printf '\n  %-3s %-38s %-26s %-6s %-9s %-20s %s\n' "#" "PV" "OLD PVC (cluster-serial)" "SIZE" "NODE" "CREATED" "RECLAIM"
i=0
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r pv _ ns claim size _ reclaim created node <<<"$row"
  printf '  %-3s %-38s %-26s %-6s %-9s %-20s %s\n' "$i" "$pv" "${ns}/${claim}" "$size" "${node:-?}" "$created" "$reclaim"
  i=$((i+1))
done
echo
warn "Pick the volume that held the PRIMARY at deletion time (most current data). If ArgoCD already"
warn "re-bootstrapped an empty cluster, its fresh PVs also show here — those are the NEWER rows; choose an"
warn "OLDER one that predates the accident. If unsure which was primary, the '-1' serial is the usual seed."

# ---- 3. select + derive target ------------------------------------------------------------------------
read -rp "Select PV to recover as the new primary [#]: " SEL
[[ "$SEL" =~ ^[0-9]+$ ]] && [[ "$SEL" -lt ${#ROWS[@]} ]] || die "Invalid selection."
IFS=$'\t' read -r PV _ NS CLAIM SIZE _ RECLAIM _ NODE <<<"${ROWS[$SEL]}"
CLUSTER="${CLAIM%-*}"          # strip trailing -<serial> -> cluster name (fullnameOverride)
NEW_PVC="${CLUSTER}-1"         # recover as serial 1 (single-instance recovery; scale up re-clones the rest)

[[ "$RECLAIM" == "Retain" ]] || warn "PV reclaimPolicy is '${RECLAIM}', not 'Retain' — proceeding, but this disk was at risk."

# Refuse to clobber a live cluster/PVC: those are the EMPTY re-bootstrapped ones. They must be removed first
# (data-safe: Retain means their deletion only orphans more PVs, it never wipes /var/mnt/localpath).
if kubectl -n "$NS" get cluster.postgresql.cnpg.io "$CLUSTER" >/dev/null 2>&1; then
  die "Cluster ${NS}/${CLUSTER} still LIVE (likely re-bootstrapped empty). Delete it first, then re-run:
       kubectl -n ${NS} delete cluster.postgresql.cnpg.io ${CLUSTER}
       kubectl -n ${NS} delete pvc -l cnpg.io/cluster=${CLUSTER}   # removes the EMPTY pvcs it just made"
fi
if kubectl -n "$NS" get pvc "$NEW_PVC" >/dev/null 2>&1; then
  die "PVC ${NS}/${NEW_PVC} already exists (empty re-bootstrap?). Delete it first, then re-run:
       kubectl -n ${NS} delete pvc ${NEW_PVC}"
fi

echo
say "Plan"
echo "    ArgoCD app     : ${ARGOCD_APP} (paused)"
echo "    Reuse PV       : ${PV}  (${SIZE}, node=${NODE:-?})"
echo "    Recreate PVC   : ${NS}/${NEW_PVC}  (adopted as serial 1)"
echo "    Cluster        : ${CLUSTER}"
read -rp "Proceed with reattach? [y/N]: " OK
[[ "$OK" =~ ^[Yy]$ ]] || die "Aborted."

# ---- 4. make the PV bindable + recreate the adoption PVC ---------------------------------------------
# A Released PV won't rebind while it still points at the (gone) old PVC. Clearing claimRef -> Available.
# Guarded so a re-run over an already-Available PV is a no-op (idempotent, per repo house rule).
if [ -n "$(kubectl get pv "$PV" -o jsonpath='{.spec.claimRef}' 2>/dev/null || true)" ]; then
  say "Clearing claimRef on ${PV} (Released -> Available)"
  kubectl patch pv "$PV" --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'
else
  ok "PV ${PV} already has no claimRef"
fi

say "Recreating PVC ${NEW_PVC} pinned to ${PV} with CNPG adoption metadata"
# volumeName pins the bind to this exact PV (and, via its nodeAffinity, back to the node holding the data).
# The label + the two annotations are what make the operator ADOPT the PVC instead of running initdb.
kubectl apply -f - <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${NEW_PVC}
  namespace: ${NS}
  labels:
    cnpg.io/cluster: ${CLUSTER}
    cnpg.io/instanceName: ${NEW_PVC}
  annotations:
    cnpg.io/nodeSerial: "1"
    cnpg.io/pvcStatus: "ready"
spec:
  volumeName: ${PV}
  storageClassName: ${STORAGE_CLASS}
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: ${SIZE}
YAML

say "Waiting for ${NEW_PVC} to bind"
kubectl wait --for=jsonpath='{.status.phase}'=Bound "pvc/${NEW_PVC}" -n "$NS" --timeout=60s \
  || warn "not Bound yet — check: kubectl -n ${NS} get pvc ${NEW_PVC}; kubectl get pv ${PV}"

# ---- 5. next steps (re-enable sync so the operator adopts the PVC) ------------------------------------
cat <<INSTRUCTIONS

$(say "PVC ready. Re-add the cluster so the operator adopts it:")

  1. (Recommended) Temporarily pin the cluster to a single instance so only the recovered primary comes up
     first. Edit the workload values and commit:

         argo_apps/workloads/charts/sample_user_manager/values.yaml
         -> the block whose cluster.fullnameOverride is '${CLUSTER}':  set  cluster.cluster.instances: 1

     (Skip this only if you're confident; leaving it at 2 makes CNPG immediately try to clone a replica.)

  2. Restore ArgoCD auto-sync — re-applying the app manifest from git puts selfHeal/prune back:

         kubectl apply -f ${APP_MANIFEST}
         kubectl -n ${ARGOCD_NS} annotate application ${ARGOCD_APP} argocd.argoproj.io/refresh=hard --overwrite

     ArgoCD recreates the Cluster CR; the operator finds the ready PVC '${NEW_PVC}' and adopts it (no initdb).

  3. Watch it come up on the recovered data:

         kubectl -n ${NS} get pods -l cnpg.io/cluster=${CLUSTER} -w
         kubectl cnpg status ${CLUSTER} -n ${NS}          # if the kubectl-cnpg plugin is installed

  4. Once the primary is Healthy and the data checks out, restore instances: 2 in values.yaml and commit.
     CNPG re-clones the replica onto a FRESH local-path PV on the other node via streaming replication.

  5. Clean up the orphaned volumes you did NOT recover (empty re-bootstrap PVs + the stale host dirs):

         kubectl get pv | grep ${CLUSTER}                 # delete the leftover Released ones you don't want
         # then on the owning node, remove its dir under /var/mnt/localpath to reclaim disk (see 02_local_path_provisioner)

Reminder: this path relies on the local PV surviving. If it didn't (disk/node loss, corruption), recover from
S3 instead:  make restore-cnpg  (see recover_cnpg_from_s3.sh / docs/13_backups.md). Recording the PV names of
your live databases somewhere safe NOW still makes THIS path far easier when the volume did survive.
INSTRUCTIONS

ok "reattach complete"
