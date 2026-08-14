#!/usr/bin/env bash
# Second half of replacing a node: resets the Longhorn disk record the OS repo's `make recover-node` leaves
# stale. Longhorn keeps the disk's UUID in BOTH the node CR and a longhorn-disk.cfg on the disk itself, so a
# reflash makes a fresh filesystem, the manager writes a new cfg with a new UUID while the CR still holds the
# old one, and Longhorn refuses the disk rather than risk using the wrong one:
#   Ready=False  DiskFilesystemChanged  record diskUUID doesn't match the one on the disk
# The node itself reports Ready, so this hides unless you look at the disk.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<EOF
reconcile_storage_after_rejoin.sh <host> [--yes]     (or: make reconcile-storage NODE=<host>)
  <host>   the node to reconcile; omit it to pick from the cluster
  --yes    skip the confirmation prompt

Run it after the OS repo has rejoined the machine:
  there:  make recover-node NODE=talos-cp3
  here:   make reconcile-storage NODE=talos-cp3
Re-run it as often as you like: every step re-checks before acting, so a partial failure is recovered by
running it again, which is the normal way past a step that needed more time.
EOF
}

# ---- knobs ----
SETTLE_WAIT=300     # secs to wait for longhorn-manager on the node, and for the cluster to converge
DISK_RETRIES=12     # attempts per disk patch; the webhook refuses every one while the manager resyncs
DISK_RETRY_SLEEP=10
DISK_WAIT=180       # secs for the re-added disk to report a UUID and Ready; slower than the patch itself
POLL=10
LH_NS="longhorn-system"

# ---- state ----
NODE=""             # set by parse_args / resolve_node
ASSUME_YES="false"  # only --yes skips the prompt here; an inherited ASSUME_YES must not
SURVIVOR=""         # set by pick_survivor
LAST_ERR=""         # lh_retry keeps the final webhook rejection; a bare exit code says nothing useful
DISK_UUID_BEFORE="" # set by reset_disk_record, compared by wait_for_disk_ready
DISK_UUID_AFTER=""
DISK_COND=""

# ---- functions ----

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)     usage; exit 0 ;;
      --yes|--apply) ASSUME_YES="true"; shift ;;
      -*)            die "unknown flag: $1 (see --help)" ;;
      *)             NODE="$1"; shift ;;
    esac
  done
}

resolve_node() {
  [ -n "$NODE" ] || { kubectl get nodes -o name | sed 's|node/|  |'; read -rp "Node to reconcile: " NODE; }
  kubectl get node "$NODE" >/dev/null 2>&1 || die "no such node: ${NODE}"
}

# A healthy peer to copy the disk spec from, and to prove the cluster can carry the rebuild.
pick_survivor() {
  local n
  while read -r n; do
    [ "$n" = "$NODE" ] && continue
    if [ "$(kubectl get node "$n" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')" = "True" ]; then
      SURVIVOR="$n"; break
    fi
  done <<< "$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
  [ -n "$SURVIVOR" ] || die "no other node is Ready; this reconciles one node against a cluster that is still up"
  say "reconciling storage on ${NODE}, copying the disk spec from ${SURVIVOR}"
}

# A volume whose only remaining replica sits ON this node has nothing to rebuild from, so stop before deleting
# anything. Every other kind of degraded is expected here and fine.
assert_no_last_replica_here() {
  local safe="yes" vol elsewhere
  say "1/3 preflight"
  while read -r vol; do
    [ -z "$vol" ] && continue
    elsewhere="$(kubectl -n "$LH_NS" get replicas.longhorn.io -o json 2>/dev/null | VOL="$vol" NODE="$NODE" python3 -c '
import json,os,sys
vol, node = os.environ["VOL"], os.environ["NODE"]
n = 0
for r in json.load(sys.stdin)["items"]:
    s = r.get("spec") or {}
    if s.get("volumeName") != vol or s.get("nodeID") == node: continue
    if s.get("failedAt"): continue
    # NOT currentState == running: a workload whose pod cannot reschedule leaves its volume DETACHED, and
    # every replica of a detached volume reads `stopped`, so that test throws away good copies and refuses
    # the recovery that would give them a node to run on again. healthyAt is the durable signal.
    if s.get("healthyAt") or (r.get("status") or {}).get("currentState") == "running": n += 1
print(n)')"
    if [ "${elsewhere:-0}" -eq 0 ]; then bad "${vol} has no healthy replica off ${NODE}"; safe="no"; fi
  done <<< "$(kubectl -n "$LH_NS" get volumes.longhorn.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
  if [ "$safe" != "yes" ]; then
    warn "those volumes would be destroyed, not rebuilt. Restore them first (make restore-longhorn), or wait if a"
    warn "rebuild is still running: kubectl -n ${LH_NS} get volumes.longhorn.io"
    summary; exit 1
  fi
  ok "every volume has a healthy replica off ${NODE}"
}

confirm_reconcile() {
  [ "$ASSUME_YES" = "true" ] && return 0
  echo
  echo "    About to, on ${NODE}: drop its stale replica records and reset its Longhorn disk record."
  echo "    Its data is already gone; this deletes the API objects that still point at it."
  echo
  confirm "Proceed?" || { warn "nothing changed"; exit 0; }
}

# A node that reports Ready is still bringing its DaemonSets up, and the disk step below reads what one of them
# publishes: the longhorn-manager that writes diskStatus. Judge that too early and a perfectly good disk looks
# broken. Waiting here is what makes a re-run safe.
wait_for_longhorn_manager() {
  local deadline lhm
  printf '    letting %s settle: longhorn-manager (up to %ss) ' "$NODE" "$SETTLE_WAIT"
  deadline=$(( $(date +%s) + SETTLE_WAIT ))
  while :; do
    lhm="$(kubectl -n "$LH_NS" get pods -l app=longhorn-manager \
           --field-selector="spec.nodeName=${NODE}" -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)"
    [ "$lhm" = "true" ] && { echo "ready"; break; }
    [ "$(date +%s)" -ge "$deadline" ] && { echo "TIMEOUT"; warn "longhorn-manager on ${NODE} is not Ready; its disk state may read stale below"; break; }
    printf '.'; sleep "$POLL"
  done
}

# The preflight already proved every volume has a healthy replica elsewhere, so these describe data on a
# filesystem that no longer exists. They also hold the 30-min replenishment timer open.
drop_stale_replicas() {
  local stale
  say "2/3 disk record on ${NODE}"
  stale="$(kubectl -n "$LH_NS" get replicas.longhorn.io -o jsonpath="{range .items[?(@.spec.nodeID==\"${NODE}\")]}{.metadata.name}{\"\n\"}{end}" 2>/dev/null)"
  if [ -z "${stale// }" ]; then
    ok "no replicas recorded on ${NODE}"
    return 0
  fi
  printf '%s\n' "$stale" | grep -c . | xargs -I{} echo "    {} stale replica(s) to drop"
  printf '%s\n' "$stale" | xargs -r kubectl -n "$LH_NS" delete replicas.longhorn.io >/dev/null 2>&1 \
    && ok "dropped the stale replicas on ${NODE}" || bad "could not drop the stale replicas on ${NODE}"
}

# Longhorn's validating webhook rejects EVERY patch here while the manager is still catching up with the
# replica deletions ("are being syncing", "remove all replicas first"), so each one is retried.
lh_retry() {   # lh_retry <what> <kubectl patch args...>
  local what="$1"; shift
  local i
  for i in $(seq 1 "$DISK_RETRIES"); do
    if LAST_ERR="$(kubectl -n "$LH_NS" patch nodes.longhorn.io "$NODE" "$@" 2>&1)"; then
      ok "${what} (attempt ${i})"; return 0
    fi
    sleep "$DISK_RETRY_SLEEP"
  done
  bad "${what}: refused ${DISK_RETRIES} times"
  warn "  last error: ${LAST_ERR##*: }"
  return 1
}

reset_disk_record() {
  local dkey spec removed="yes"
  DISK_UUID_BEFORE="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" -o jsonpath='{range .status.diskStatus.*}{.diskUUID}{end}' 2>/dev/null)"
  DISK_COND="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" -o jsonpath='{range .status.diskStatus.*}{range .conditions[?(@.type=="Ready")]}{.status}{end}{end}' 2>/dev/null)"
  if [ "$DISK_COND" = "True" ]; then
    ok "the disk record already matches the disk; nothing to reset"
    return 0
  fi
  dkey="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" -o go-template='{{range $k,$v := .spec.disks}}{{$k}}{{end}}' 2>/dev/null)"
  spec="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$SURVIVOR" -o jsonpath='{.spec.disks}' 2>/dev/null)"
  [ -n "$spec" ] || die "could not read ${SURVIVOR}'s disk spec to copy"
  if [ -n "$dkey" ]; then
    # allowScheduling has to land first, the webhook will not remove a schedulable disk. And a merge patch of
    # {"disks":{}} is a no-op, because JSON merge patch only deletes a key set to null.
    lh_retry "disabled scheduling on ${dkey}" --type merge \
      -p "{\"spec\":{\"disks\":{\"${dkey}\":{\"allowScheduling\":false}}}}"
    lh_retry "removed the stale disk record ${dkey}" --type json \
      -p "[{\"op\":\"remove\",\"path\":\"/spec/disks/${dkey}\"}]" || removed="no"
  fi
  # Re-adding before the remove landed is worse than doing nothing: the survivor's spec carries
  # allowScheduling true, so it would re-enable the STALE record and read as success.
  if [ "$removed" = "yes" ]; then
    lh_retry "re-added the disk from ${SURVIVOR}'s spec" --type merge -p "{\"spec\":{\"disks\":${spec}}}"
  else
    warn "not re-adding while ${dkey} is still there; it would just re-enable the stale record"
  fi
}

# Judged on the disk, not on whether the patches returned 0: a new UUID with Ready=True is the only thing that
# means the manager accepted it. Polled, because populating diskStatus after a re-add takes it well past a
# single check.
wait_for_disk_ready() {
  local deadline
  printf '    waiting for the disk to come Ready (up to %ss) ' "$DISK_WAIT"
  deadline=$(( $(date +%s) + DISK_WAIT ))
  while :; do
    DISK_UUID_AFTER="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" -o jsonpath='{range .status.diskStatus.*}{.diskUUID}{end}' 2>/dev/null)"
    DISK_COND="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" -o jsonpath='{range .status.diskStatus.*}{range .conditions[?(@.type=="Ready")]}{.status}{end}{end}' 2>/dev/null)"
    [ "$DISK_COND" = "True" ] && [ -n "$DISK_UUID_AFTER" ] && { echo "ready"; break; }
    [ "$(date +%s)" -ge "$deadline" ] && { echo "TIMEOUT"; break; }
    printf '.'; sleep "$POLL"
  done
  if [ "$DISK_COND" != "True" ]; then
    bad "${NODE}'s disk is still not Ready (UUID ${DISK_UUID_AFTER:-none}, was ${DISK_UUID_BEFORE:-none})"
    warn "  Longhorn will not schedule replicas here until it is. Re-run once the manager settles:"
    warn "    make reconcile-storage NODE=${NODE}"
  elif [ "$DISK_UUID_AFTER" = "$DISK_UUID_BEFORE" ]; then
    ok "disk Ready on ${NODE}, UUID ${DISK_UUID_AFTER} (unchanged, so it was never stale)"
  else
    ok "disk Ready on ${NODE}, UUID ${DISK_UUID_AFTER} (was ${DISK_UUID_BEFORE:-none})"
  fi
}

wait_for_volumes_healthy() {
  local deadline deg
  say "3/3 waiting for volumes to come back (up to ${SETTLE_WAIT}s)"
  deadline=$(( $(date +%s) + SETTLE_WAIT ))
  while :; do
    deg="$(kubectl -n "$LH_NS" get volumes.longhorn.io -o jsonpath='{range .items[*]}{.status.robustness}{"\n"}{end}' 2>/dev/null | grep -vc '^healthy$')"
    printf '    volumes not healthy: %s\n' "${deg:-?}"
    [ "${deg:-1}" -eq 0 ] && break
    [ "$(date +%s)" -ge "$deadline" ] && { warn "not fully converged yet; a Longhorn rebuild or a CNPG clone can outlast this"; break; }
    sleep "$POLL"
  done
}

print_next_steps() {
cat <<NEXT

Expect ${NODE} to stay EMPTY for a while. replica-auto-balance is disabled, so Longhorn never moves a healthy
replica, and every volume rebuilt during the outage picked the two survivors. See docs/05_storage.md.

NEXT
}

# ---- main ----

parse_args "$@"
require kubectl python3
use_kubeconfig
assert_api

resolve_node
pick_survivor
assert_no_last_replica_here
confirm_reconcile
wait_for_longhorn_manager
drop_stale_replicas
reset_disk_record
wait_for_disk_ready
wait_for_volumes_healthy
print_next_steps

summary || exit 1
