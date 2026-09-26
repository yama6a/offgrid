#!/usr/bin/env bash
# Resets the Longhorn disk record of a node that rejoined after a reflash. This is the second half of a node swap.
# Longhorn stores the disk UUID in the node CR and in longhorn-disk.cfg on the disk.
# A reflash writes a new cfg with a new UUID, the CR keeps the old one, and Longhorn refuses the disk:
#   Ready=False  DiskFilesystemChanged  record diskUUID doesn't match the one on the disk
# The node still reports Ready, so only the disk status shows the problem.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat << EOF
reconcile_storage_after_rejoin.sh <host> [--yes]     (or: make reconcile-storage NODE=<host>)
  <host>   the node to reconcile. Omit it to pick from the cluster.
  --yes    skip the confirmation prompt

Run it after your node tooling has rejoined the machine and the node reports Ready:
  make reconcile-storage NODE=<host>
Every step checks before it acts, so a re-run is always safe.
After a partial failure, or a step that needed more time, run it again.
EOF
}

# ---- knobs ----
SETTLE_WAIT=300 # seconds to wait for longhorn-manager on the node, and for the cluster to converge
DISK_RETRIES=12 # attempts per disk patch. The webhook refuses every patch while the manager resyncs.
DISK_RETRY_SLEEP=10
DISK_WAIT=180 # seconds for the re-added disk to report a UUID and Ready
POLL=10
LH_NS="longhorn-system"

# ---- state ----
NODE=""             # set by parse_args / resolve_node
ASSUME_YES="false"  # only --yes skips the prompt. An inherited ASSUME_YES must not.
SURVIVOR=""         # set by pick_survivor
LAST_ERR=""         # the last webhook rejection, kept by lh_retry for the report
DISK_UUID_BEFORE="" # set by reset_disk_record, compared by wait_for_disk_ready
DISK_UUID_AFTER=""
DISK_COND=""

# ---- functions ----

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --yes | --apply)
        ASSUME_YES="true"
        shift
        ;;
      -*) die "unknown flag: $1. See --help." ;;
      *)
        NODE="$1"
        shift
        ;;
    esac
  done
}

resolve_node() {
  [ -n "$NODE" ] || {
    kubectl get nodes -o name | sed 's|node/|  |'
    read -rp "Node to reconcile: " NODE
  }
  kubectl get node "$NODE" > /dev/null 2>&1 || die "no such node: ${NODE}"
}

# The survivor is a Ready peer. Its disk spec is the template for the re-added disk.
pick_survivor() {
  local n
  while read -r n; do
    [ "$n" = "$NODE" ] && continue
    if [ "$(kubectl get node "$n" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')" = "True" ]; then
      SURVIVOR="$n"
      break
    fi
  done <<< "$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
  [ -n "$SURVIVOR" ] || die "no other node is Ready. This script needs the rest of the cluster up."
  say "reconciling storage on ${NODE}, copying the disk spec from ${SURVIVOR}"
}

# A volume whose only replica is on this node has nothing to rebuild from, so stop before deleting anything.
# Any other degraded volume is expected here.
assert_no_last_replica_here() {
  local safe="yes" vol elsewhere
  say "1/3 preflight"
  while read -r vol; do
    [ -z "$vol" ] && continue
    elsewhere="$(kubectl -n "$LH_NS" get replicas.longhorn.io -o json 2> /dev/null | VOL="$vol" NODE="$NODE" python3 -c '
import json,os,sys
vol, node = os.environ["VOL"], os.environ["NODE"]
n = 0
for r in json.load(sys.stdin)["items"]:
    s = r.get("spec") or {}
    if s.get("volumeName") != vol or s.get("nodeID") == node: continue
    if s.get("failedAt"): continue
    # healthyAt, because every replica of a detached volume reads stopped. A pod that cannot reschedule
    # leaves its volume detached, and a running-only test would count its good copies as lost.
    if s.get("healthyAt") or (r.get("status") or {}).get("currentState") == "running": n += 1
print(n)')"
    if [ "${elsewhere:-0}" -eq 0 ]; then
      bad "${vol} has no healthy replica off ${NODE}"
      safe="no"
    fi
  done <<< "$(kubectl -n "$LH_NS" get volumes.longhorn.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2> /dev/null)"
  if [ "$safe" != "yes" ]; then
    warn "this would destroy those volumes, not rebuild them. Restore them first with make restore-longhorn."
    warn "Or wait if a rebuild still runs. Check with: kubectl -n ${LH_NS} get volumes.longhorn.io"
    summary
    exit 1
  fi
  ok "every volume has a healthy replica off ${NODE}"
}

confirm_reconcile() {
  [ "$ASSUME_YES" = "true" ] && return 0
  echo
  echo "    About to drop the stale replica records on ${NODE} and reset its Longhorn disk record."
  echo "    Its data is already gone. This deletes the API objects that still point at it."
  echo
  confirm "Proceed?" || {
    warn "nothing changed"
    exit 0
  }
}

# A Ready node can still be starting its DaemonSets. The disk step reads diskStatus from longhorn-manager.
# Read too early, a good disk looks broken.
wait_for_longhorn_manager() {
  local deadline lhm
  printf '    letting %s settle: longhorn-manager (up to %ss) ' "$NODE" "$SETTLE_WAIT"
  deadline=$(($(date +%s) + SETTLE_WAIT))
  while :; do
    lhm="$(kubectl -n "$LH_NS" get pods -l app=longhorn-manager \
      --field-selector="spec.nodeName=${NODE}" -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2> /dev/null)"
    [ "$lhm" = "true" ] && {
      echo "ready"
      break
    }
    [ "$(date +%s)" -ge "$deadline" ] && {
      echo "timed out"
      warn "longhorn-manager on ${NODE} is not Ready. Its disk state below can be stale."
      break
    }
    printf '.'
    sleep "$POLL"
  done
}

# The preflight proved that every volume has a healthy replica elsewhere.
# These records point at a filesystem that no longer exists, and they hold the 30-minute replenishment timer open.
drop_stale_replicas() {
  local stale
  say "2/3 disk record on ${NODE}"
  stale="$(kubectl -n "$LH_NS" get replicas.longhorn.io -o jsonpath="{range .items[?(@.spec.nodeID==\"${NODE}\")]}{.metadata.name}{\"\n\"}{end}" 2> /dev/null)"
  if [ -z "${stale// /}" ]; then
    ok "no replicas recorded on ${NODE}"
    return 0
  fi
  printf '%s\n' "$stale" | grep -c . | xargs -I{} echo "    {} stale replica(s) to drop"
  printf '%s\n' "$stale" | xargs -r kubectl -n "$LH_NS" delete replicas.longhorn.io > /dev/null 2>&1 \
    && ok "dropped the stale replicas on ${NODE}" || bad "could not drop the stale replicas on ${NODE}"
}

# The Longhorn webhook rejects every patch while the manager processes the replica deletions.
# Its errors read "are being syncing" or "remove all replicas first".
lh_retry() { # lh_retry <what> <kubectl patch args...>
  local what="$1"
  shift
  local i
  for i in $(seq 1 "$DISK_RETRIES"); do
    if LAST_ERR="$(kubectl -n "$LH_NS" patch nodes.longhorn.io "$NODE" "$@" 2>&1)"; then
      ok "${what} (attempt ${i})"
      return 0
    fi
    sleep "$DISK_RETRY_SLEEP"
  done
  bad "${what}: refused ${DISK_RETRIES} times"
  warn "  last error: ${LAST_ERR##*: }"
  return 1
}

reset_disk_record() {
  local dkey spec removed="yes"
  DISK_UUID_BEFORE="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" -o jsonpath='{range .status.diskStatus.*}{.diskUUID}{end}' 2> /dev/null)"
  DISK_COND="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" -o jsonpath='{range .status.diskStatus.*}{range .conditions[?(@.type=="Ready")]}{.status}{end}{end}' 2> /dev/null)"
  if [ "$DISK_COND" = "True" ]; then
    ok "the disk record already matches the disk. Nothing to reset."
    return 0
  fi
  dkey="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" -o go-template='{{range $k,$v := .spec.disks}}{{$k}}{{end}}' 2> /dev/null)"
  spec="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$SURVIVOR" -o jsonpath='{.spec.disks}' 2> /dev/null)"
  [ -n "$spec" ] || die "could not read ${SURVIVOR}'s disk spec to copy"
  if [ -n "$dkey" ]; then
    # The webhook refuses to remove a schedulable disk, so allowScheduling goes first.
    # The remove is a JSON patch, because a merge patch of {"disks":{}} changes nothing.
    lh_retry "disabled scheduling on ${dkey}" --type merge \
      -p "{\"spec\":{\"disks\":{\"${dkey}\":{\"allowScheduling\":false}}}}"
    lh_retry "removed the stale disk record ${dkey}" --type json \
      -p "[{\"op\":\"remove\",\"path\":\"/spec/disks/${dkey}\"}]" || removed="no"
  fi
  # A re-add before the remove would set allowScheduling true on the stale record and report success.
  if [ "$removed" = "yes" ]; then
    lh_retry "re-added the disk from ${SURVIVOR}'s spec" --type merge -p "{\"spec\":{\"disks\":${spec}}}"
  else
    warn "not re-adding while ${dkey} is still there. That would only re-enable the stale record."
  fi
}

# Only a UUID with Ready=True shows the manager accepted the disk. A patch that returned 0 does not.
# diskStatus takes a while to fill after a re-add, so this polls.
wait_for_disk_ready() {
  local deadline
  printf '    waiting for the disk to come Ready (up to %ss) ' "$DISK_WAIT"
  deadline=$(($(date +%s) + DISK_WAIT))
  while :; do
    DISK_UUID_AFTER="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" -o jsonpath='{range .status.diskStatus.*}{.diskUUID}{end}' 2> /dev/null)"
    DISK_COND="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" -o jsonpath='{range .status.diskStatus.*}{range .conditions[?(@.type=="Ready")]}{.status}{end}{end}' 2> /dev/null)"
    [ "$DISK_COND" = "True" ] && [ -n "$DISK_UUID_AFTER" ] && {
      echo "ready"
      break
    }
    [ "$(date +%s)" -ge "$deadline" ] && {
      echo "timed out"
      break
    }
    printf '.'
    sleep "$POLL"
  done
  if [ "$DISK_COND" != "True" ]; then
    bad "${NODE}'s disk is still not Ready (UUID ${DISK_UUID_AFTER:-none}, was ${DISK_UUID_BEFORE:-none})"
    warn "  Longhorn schedules no replicas here until it is. Run this again when the manager settles:"
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
  deadline=$(($(date +%s) + SETTLE_WAIT))
  while :; do
    deg="$(kubectl -n "$LH_NS" get volumes.longhorn.io -o jsonpath='{range .items[*]}{.status.robustness}{"\n"}{end}' 2> /dev/null | grep -vc '^healthy$')"
    printf '    volumes not healthy: %s\n' "${deg:-?}"
    [ "${deg:-1}" -eq 0 ] && break
    [ "$(date +%s)" -ge "$deadline" ] && {
      warn "not fully converged yet. A Longhorn rebuild or a CNPG clone can take longer than this wait."
      break
    }
    sleep "$POLL"
  done
}

print_next_steps() {
  cat << NEXT

Expect ${NODE} to stay empty for a while. replica-auto-balance is off, so Longhorn never moves a healthy replica.
Every volume rebuilt during the outage placed its replicas on the two survivors. See docs/05_storage.md.

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
