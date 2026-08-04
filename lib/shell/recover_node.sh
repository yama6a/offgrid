#!/usr/bin/env bash
# Puts ONE replaced or wiped node back into a running cluster, and fixes the state that does not fix itself.
# The executable half of docs/15_node_recovery.md. The workloads need nothing: their volumes are Longhorn's,
# not the node's, so they moved to a survivor on their own long before this runs.
#
# Re-run it as often as you like. Every step re-checks before acting, so a partial failure is recovered by
# running it again, which is the normal way to get past a step that needed more time.
#
# Usage:
#   bash recover_node.sh <hostname> [--yes]
#   make recover-node NODE=pi-cp3
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
MAINT_WAIT=600      # secs to wait for the node to answer in maintenance mode before giving up
READY_WAIT=900      # secs to wait for the kubelet to register and report Ready after the config apply
SETTLE_WAIT=300     # secs to wait for the node's DaemonSets to settle, and for the cluster to converge
DISK_RETRIES=12     # attempts per Longhorn disk patch; its webhook refuses every one while the manager resyncs
DISK_RETRY_SLEEP=10
DISK_WAIT=180       # secs for the re-added disk to report a UUID and Ready; it is slower than the patch
POLL=10
LH_NS="longhorn-system"

NODE=""; ASSUME_YES="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|--apply) ASSUME_YES="true"; shift ;;
    -*)            die "unknown flag: $1 (see the usage header)" ;;
    *)             NODE="$1"; shift ;;
  esac
done

require kubectl docker python3
use_kubeconfig
assert_api

[ -n "$NODE" ] || { for e in "${CLUSTER_NODES[@]}"; do echo "  ${e%%:*}"; done; read -rp "Node to recover: " NODE; }

IP=""
for e in "${CLUSTER_NODES[@]}"; do [ "${e%%:*}" = "$NODE" ] && IP="${e##*:}"; done
[ -n "$IP" ] || die "unknown node '${NODE}': .env CLUSTER_NODES has $(for e in "${CLUSTER_NODES[@]}"; do printf '%s ' "${e%%:*}"; done)"

PEERS=(); PEER_IPS=()
for e in "${CLUSTER_NODES[@]}"; do
  [ "${e%%:*}" = "$NODE" ] && continue
  PEERS+=("${e%%:*}"); PEER_IPS+=("${e##*:}")
done
[ "${#PEERS[@]}" -ge 1 ] || die "no surviving node to talk to; this script rejoins a node to a cluster that is still up"

say "recovering ${NODE} (${IP});  survivors: ${PEERS[*]}"

# --- 1. preflight: the survivors have to be able to carry the cluster and rebuild from ------------------
say "1/6 preflight"

SURVIVOR=""   # the healthy node every etcd and Longhorn call below is aimed at
for i in "${!PEERS[@]}"; do
  if [ "$(kubectl get node "${PEERS[$i]}" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null)" = "True" ]; then
    SURVIVOR="${PEERS[$i]}"; SURVIVOR_IP="${PEER_IPS[$i]}"; break
  fi
done
[ -n "$SURVIVOR" ] || die "no surviving node is Ready; recovering one node needs the rest of the cluster up"
ok "talking to ${SURVIVOR} (${SURVIVOR_IP})"

# A volume whose only remaining replica sits ON the node we are about to work on has nothing to rebuild from,
# so stop before deleting anything. Every other kind of degraded is expected here and fine.
SAFE="yes"
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
  if [ "${elsewhere:-0}" -eq 0 ]; then bad "${vol} has no healthy replica off ${NODE}"; SAFE="no"; fi
done <<< "$(kubectl -n "$LH_NS" get volumes.longhorn.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
if [ "$SAFE" != "yes" ]; then
  warn "those volumes would be destroyed, not rebuilt. Restore them first (make restore-longhorn), or wait if a"
  warn "rebuild is still running: kubectl -n ${LH_NS} get volumes.longhorn.io"
  summary; exit 1
fi
ok "every Longhorn volume has a healthy replica off ${NODE}"

echo
echo "    About to, on ${NODE}: drop its stale etcd member, apply its machine config, and reset its"
echo "    Longhorn disk record."
echo "    Its data is already gone; this deletes the API objects that still point at it."
echo
confirm "Proceed?" || { warn "nothing changed"; exit 0; }

# Probed ONCE, before anything acts on it. A maintenance node answers --insecure and rejects a secure call; a
# configured one is the reverse. Every step below branches on this rather than re-probing, so a re-run against
# a node that has already come back cannot mistake it for one that is still down.
ADOPTED="no"
talosctl -n "$IP" -e "$IP" version >/dev/null 2>&1 && ADOPTED="yes"

# --- 2. etcd: drop the member whose peer URL is this node -----------------------------------------------
# A wiped node comes back with a NEW etcd identity, and the old entry at the same peer URL blocks the join.
say "2/6 etcd membership"
MEMBER="$(talosctl -n "$SURVIVOR_IP" -e "$SURVIVOR_IP" etcd members 2>/dev/null | awk -v ip="$IP" '$0 ~ ip {print $2}' | head -1)"
if [ -z "$MEMBER" ]; then
  ok "no etcd member at ${IP} (already removed, or the node never joined)"
elif [ "$ADOPTED" = "yes" ]; then
  # The member belongs to a node that is UP and holding our config, so it is the real one, not a leftover.
  # Removing it would evict a working control-plane node and leave its etcd restarting forever.
  ok "${NODE} is already back and holds etcd member ${MEMBER}; leaving it alone"
else
  if talosctl -n "$SURVIVOR_IP" -e "$SURVIVOR_IP" etcd remove-member "$MEMBER" >/dev/null 2>&1; then
    ok "removed stale etcd member ${MEMBER}"
  else
    bad "could not remove etcd member ${MEMBER}; check quorum on ${SURVIVOR}"
  fi
fi

# --- 3. machine config ---------------------------------------------------------------------------------
say "3/6 machine config"
if [ "$ADOPTED" = "yes" ]; then
  ok "${IP} already answers securely, so it holds our config; not re-applying"
else
  printf '    waiting for %s in maintenance mode (up to %ss) ' "$IP" "$MAINT_WAIT"
  deadline=$(( $(date +%s) + MAINT_WAIT ))
  until talosctl -n "$IP" -e "$IP" version --insecure >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo " TIMEOUT"
      bad "${IP} is neither configured nor in maintenance"
      warn "is it powered on and on the network?  arp -n ${IP}  &&  nc -vz ${IP} ${API_PORT}"
      warn "if it has not been wiped yet, do that first: make flash-talos-nvme, or talosctl reset"
      summary; exit 1
    fi
    printf '.'; sleep 5
  done
  echo "ready"
  # 03c with a hostname applies to that node alone and skips the bootstrap, while still building certSANs and
  # the talosconfig endpoints from the full list.
  if bash "${SCRIPT_DIR}/03c_talos_cluster_config.sh" "$NODE"; then
    ok "applied ${NODE}'s machine config"
  else
    bad "03c failed for ${NODE}"; summary; exit 1
  fi
fi

# --- 4. kubelet ----------------------------------------------------------------------------------------
say "4/6 kubernetes node"
printf '    waiting for %s Ready (up to %ss) ' "$NODE" "$READY_WAIT"
deadline=$(( $(date +%s) + READY_WAIT ))
until [ "$(kubectl get node "$NODE" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null)" = "True" ]; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo " TIMEOUT"
    bad "${NODE} did not reach Ready"
    warn "if the node object is stuck on a stale identity: kubectl delete node ${NODE}, the kubelet re-registers"
    summary; exit 1
  fi
  printf '.'; sleep "$POLL"
done
echo "ready"
ok "${NODE} is Ready"
if [ "$(kubectl get node "$NODE" -o jsonpath='{.spec.unschedulable}')" = "true" ]; then
  kubectl uncordon "$NODE" >/dev/null 2>&1 && ok "uncordoned ${NODE}" || bad "could not uncordon ${NODE}"
fi

# A node that reports Ready is still bringing its DaemonSets up, and the disk step below reads what one of them
# publishes: the longhorn-manager that writes diskStatus. Judge that too early and a perfectly good disk looks
# broken. Waiting here is what makes a re-run safe.
printf '    letting %s settle: longhorn-manager (up to %ss) ' "$NODE" "$SETTLE_WAIT"
deadline=$(( $(date +%s) + SETTLE_WAIT ))
while :; do
  LHM="$(kubectl -n "$LH_NS" get pods -l app=longhorn-manager \
         --field-selector="spec.nodeName=${NODE}" -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)"
  [ "$LHM" = "true" ] && { echo "ready"; break; }
  [ "$(date +%s)" -ge "$deadline" ] && { echo "TIMEOUT"; warn "longhorn-manager on ${NODE} is not Ready; its disk state may read stale below"; break; }
  printf '.'; sleep "$POLL"
done

# --- 5. Longhorn: stale replicas, then the disk record -------------------------------------------------
# Longhorn keeps the disk UUID in both the node CR and a longhorn-disk.cfg on the disk. The wipe made a new
# filesystem, so the manager wrote a new cfg while the CR kept the old UUID, and it refuses the disk rather
# than risk the wrong one. The node itself still reports Ready, so this hides unless you look at the disk.
say "5/6 Longhorn disk record on ${NODE}"
STALE="$(kubectl -n "$LH_NS" get replicas.longhorn.io -o jsonpath="{range .items[?(@.spec.nodeID==\"${NODE}\")]}{.metadata.name}{\"\n\"}{end}" 2>/dev/null)"
if [ -n "${STALE// }" ]; then
  # Preflight already proved every volume has a running replica elsewhere, so these describe data on a
  # filesystem that no longer exists. They also hold the 30-min replenishment timer open.
  printf '%s\n' "$STALE" | grep -c . | xargs -I{} echo "    {} stale replica(s) to drop"
  printf '%s\n' "$STALE" | xargs -r kubectl -n "$LH_NS" delete replicas.longhorn.io >/dev/null 2>&1 \
    && ok "dropped the stale replicas on ${NODE}" || bad "could not drop the stale replicas on ${NODE}"
else
  ok "no replicas recorded on ${NODE}"
fi

# Longhorn's validating webhook rejects EVERY step here while the manager is still catching up with the
# replica deletions above ("are being syncing", "remove all replicas first"), so each one is retried rather
# than attempted once. LAST_ERR keeps the final rejection, because a bare exit code says nothing useful.
LAST_ERR=""
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

DISK_UUID_BEFORE="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" -o jsonpath='{range .status.diskStatus.*}{.diskUUID}{end}' 2>/dev/null)"
DISK_COND="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" -o jsonpath='{range .status.diskStatus.*}{range .conditions[?(@.type=="Ready")]}{.status}{end}{end}' 2>/dev/null)"
if [ "$DISK_COND" = "True" ]; then
  ok "the disk record already matches the disk; nothing to reset"
else
  DKEY="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" -o go-template='{{range $k,$v := .spec.disks}}{{$k}}{{end}}' 2>/dev/null)"
  SPEC="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$SURVIVOR" -o jsonpath='{.spec.disks}' 2>/dev/null)"
  [ -n "$SPEC" ] || die "could not read ${SURVIVOR}'s disk spec to copy"
  REMOVED="yes"
  if [ -n "$DKEY" ]; then
    # allowScheduling has to land first, the webhook will not remove a schedulable disk. And a merge patch of
    # {"disks":{}} is a no-op, because JSON merge patch only deletes a key set to null.
    lh_retry "disabled scheduling on ${DKEY}" --type merge \
      -p "{\"spec\":{\"disks\":{\"${DKEY}\":{\"allowScheduling\":false}}}}"
    lh_retry "removed the stale disk record ${DKEY}" --type json \
      -p "[{\"op\":\"remove\",\"path\":\"/spec/disks/${DKEY}\"}]" || REMOVED="no"
  fi
  # Re-adding before the remove landed is worse than doing nothing: the survivor's spec carries
  # allowScheduling true, so it would re-enable the STALE record and read as success.
  if [ "$REMOVED" = "yes" ]; then
    lh_retry "re-added the disk from ${SURVIVOR}'s spec" --type merge -p "{\"spec\":{\"disks\":${SPEC}}}"
  else
    warn "not re-adding while ${DKEY} is still there; it would just re-enable the stale record"
  fi
fi

# Judge the outcome on the disk, not on whether the patches returned 0: a new UUID with Ready=True is the only
# thing that means the manager accepted it. Polled, because populating diskStatus after a re-add takes it well
# past a single check.
printf '    waiting for the disk to come Ready (up to %ss) ' "$DISK_WAIT"
deadline=$(( $(date +%s) + DISK_WAIT ))
while :; do
  DISK_UUID_AFTER="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" -o jsonpath='{range .status.diskStatus.*}{.diskUUID}{end}' 2>/dev/null)"
  DISK_COND="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" -o jsonpath='{range .status.diskStatus.*}{range .conditions[?(@.type=="Ready")]}{.status}{end}{end}' 2>/dev/null)"
  [ "$DISK_COND" = "True" ] && [ -n "$DISK_UUID_AFTER" ] && { echo "ready"; break; }
  [ "$(date +%s)" -ge "$deadline" ] && { echo "TIMEOUT"; break; }
  printf '.'; sleep "$POLL"
done
if [ "$DISK_COND" = "True" ]; then
  if [ "$DISK_UUID_AFTER" = "$DISK_UUID_BEFORE" ]; then
    ok "disk Ready on ${NODE}, UUID ${DISK_UUID_AFTER} (unchanged, so it was never stale)"
  else
    ok "disk Ready on ${NODE}, UUID ${DISK_UUID_AFTER} (was ${DISK_UUID_BEFORE:-none})"
  fi
else
  bad "${NODE}'s disk is still not Ready (UUID ${DISK_UUID_AFTER:-none}, was ${DISK_UUID_BEFORE:-none})"
  warn "  Longhorn will not schedule replicas here until it is. Re-run once the manager settles:"
  warn "    make recover-node NODE=${NODE} YES=1"
fi

# --- 6. converge ---------------------------------------------------------------------------------------
# Counts LIVE pods only. A pod whose node died is left behind in phase Failed and never becomes Running, so
# counting those means waiting for something that cannot happen. They are reported once, at the end, as cruft.
say "6/6 waiting for things to come back (up to ${SETTLE_WAIT}s)"
deadline=$(( $(date +%s) + SETTLE_WAIT ))
while :; do
  PENDING="$(kubectl get pods -A --field-selector=status.phase!=Failed --no-headers 2>/dev/null | grep -Evc 'Running|Completed')"
  DEG="$(kubectl -n "$LH_NS" get volumes.longhorn.io -o jsonpath='{range .items[*]}{.status.robustness}{"\n"}{end}' 2>/dev/null | grep -vc '^healthy$')"
  printf '    pods not running: %s   volumes not healthy: %s\n' "${PENDING:-?}" "${DEG:-?}"
  [ "${PENDING:-1}" -eq 0 ] && [ "${DEG:-1}" -eq 0 ] && break
  [ "$(date +%s)" -ge "$deadline" ] && { warn "not fully converged yet; a Longhorn rebuild or a CNPG clone can outlast this"; break; }
  sleep "$POLL"
done

MCOUNT="$(talosctl -n "$SURVIVOR_IP" -e "$SURVIVOR_IP" etcd members 2>/dev/null | grep -c '^' )"
[ "${MCOUNT:-0}" -gt 1 ] && ok "etcd has $(( MCOUNT - 1 )) members"

# Pods their node died under. Harmless, but they show up in every `get pods` from here on.
ORPHANS="$(kubectl get pods -A --field-selector=status.phase=Failed -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c . )"

cat <<NEXT

Left for you, because it is not mechanical:
  - re-spread the stateless Deployments once everything is healthy: make rebalance-workloads
NEXT
[ "${ORPHANS:-0}" -gt 0 ] && cat <<NEXT
  - ${ORPHANS} pod(s) left in phase Failed by the outage, which nothing garbage-collects:
      kubectl delete pods -A --field-selector=status.phase=Failed
NEXT
cat <<NEXT

Then walk docs/15_node_recovery.md step 7 to confirm.
NEXT

summary || exit 1
