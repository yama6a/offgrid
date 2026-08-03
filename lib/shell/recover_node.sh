#!/usr/bin/env bash
# Puts ONE replaced or wiped node back into a running cluster, and fixes the state that does not fix itself.
# The executable half of docs/15_node_recovery.md: everything there except the single-instance CNPG restore,
# which spans git commits and is `make restore-cnpg`.
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
SETTLE_WAIT=300     # secs to wait for a recreated CNPG/RabbitMQ pod to come back Ready
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
say "1/7 preflight"

SURVIVOR=""   # the healthy node every etcd and rabbitmq call below is aimed at
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
    if (r.get("status") or {}).get("currentState") == "running" and not s.get("failedAt"): n += 1
print(n)')"
  if [ "${elsewhere:-0}" -eq 0 ]; then bad "${vol} has no running replica off ${NODE}"; SAFE="no"; fi
done <<< "$(kubectl -n "$LH_NS" get volumes.longhorn.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
if [ "$SAFE" != "yes" ]; then
  warn "those volumes would be destroyed, not rebuilt. Restore them first (make restore-longhorn), or wait if a"
  warn "rebuild is still running: kubectl -n ${LH_NS} get volumes.longhorn.io"
  summary; exit 1
fi
ok "every Longhorn volume has a running replica off ${NODE}"

echo
echo "    About to, on ${NODE}: drop its stale etcd member, apply its machine config, delete the local-path"
echo "    PVCs bound to it (empty since the wipe), and reset its Longhorn disk record."
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
say "2/7 etcd membership"
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
say "3/7 machine config"
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
  # 03d with a hostname applies to that node alone and skips the bootstrap, while still building certSANs and
  # the talosconfig endpoints from the full list.
  if bash "${SCRIPT_DIR}/03d_talos_cluster_config.sh" "$NODE"; then
    ok "applied ${NODE}'s machine config"
  else
    bad "03d failed for ${NODE}"; summary; exit 1
  fi
fi

# --- 4. kubelet ----------------------------------------------------------------------------------------
say "4/7 kubernetes node"
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

# A node that reports Ready is still bringing its DaemonSets up, and both steps below read state those pods
# publish: the consumers that mount the local-path PVCs, and the longhorn-manager that writes diskStatus. Judge
# any of it too early and a perfectly good volume looks broken. Waiting here is what makes a re-run safe.
printf '    letting %s settle: longhorn-manager (up to %ss) ' "$NODE" "$SETTLE_WAIT"
deadline=$(( $(date +%s) + SETTLE_WAIT ))
while :; do
  LHM="$(kubectl -n "$LH_NS" get pods -l app=longhorn-manager \
         --field-selector="spec.nodeName=${NODE}" -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)"
  [ "$LHM" = "true" ] && { echo "ready"; break; }
  [ "$(date +%s)" -ge "$deadline" ] && { echo "TIMEOUT"; warn "longhorn-manager on ${NODE} is not Ready; its disk state may read stale below"; break; }
  printf '.'; sleep "$POLL"
done

# pod_settled <ns> <pod>: true once the pod is Running with every container ready. Give it time before calling
# a volume stale, because "not ready yet" and "wedged on an empty volume" look identical in the first minute.
pod_settled() {
  [ "$(kubectl -n "$1" get pod "$2" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] || return 1
  ! kubectl -n "$1" get pod "$2" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null | grep -q false
}

# --- 5. local-path PVCs bound to this node -------------------------------------------------------------
# The wipe took their contents; the PVC and PV objects survived, still Bound and still node-affine, pointing
# at an empty directory. No operator will delete a PVC that might hold the last copy of something, so they
# crashloop until we do. See docs/15_node_recovery.md.
say "5/7 local-path PVCs bound to ${NODE}"
PVCS="$(kubectl get pv -o json | NODE="$NODE" python3 -c '
import json,os,sys
node = os.environ["NODE"]
for pv in json.load(sys.stdin)["items"]:
    spec = pv["spec"]
    if not (spec.get("storageClassName") or "").startswith("local-path"): continue
    try:
        terms = spec["nodeAffinity"]["required"]["nodeSelectorTerms"][0]["matchExpressions"][0]["values"]
    except (KeyError, IndexError):
        continue
    if node not in terms: continue
    ref = spec.get("claimRef") or {}
    ns, name = ref.get("namespace"), ref.get("name")
    if ns and name:
        print(ns + "\t" + name)
')"

if [ -z "${PVCS// }" ]; then
  ok "none bound to ${NODE}"
else
  while IFS=$'\t' read -r ns pvc; do
    [ -z "$ns" ] && continue
    kubectl -n "$ns" get pvc "$pvc" >/dev/null 2>&1 || { ok "${ns}/${pvc} already gone"; continue; }
    LABELS="$(kubectl -n "$ns" get pvc "$pvc" -o json)"
    KIND="$(printf '%s' "$LABELS" | python3 -c '
import json,sys
l = (json.load(sys.stdin)["metadata"].get("labels") or {})
if l.get("cnpg.io/cluster"): print("cnpg\t" + l["cnpg.io/cluster"] + "\t" + l.get("cnpg.io/instanceName",""))
elif l.get("app.kubernetes.io/name") == "rabbitmq": print("rabbitmq\t\t")
else: print("other\t\t")')"
    IFS=$'\t' read -r kind owner instance <<< "$KIND"

    # A consumer that reaches Ready is proof the volume under it works, which is the one signal separating
    # "empty since the wipe" from "already rebuilt by an earlier run of this script". Give it the full settle
    # window before concluding otherwise: a broker replaying Ra logs is not ready for a minute or two either.
    CONSUMER="$instance"
    [ "$kind" = "rabbitmq" ] && CONSUMER="${pvc#persistence-}"
    if [ -n "$CONSUMER" ] && kubectl -n "$ns" get pod "$CONSUMER" >/dev/null 2>&1; then
      printf '    %s/%s: waiting to see if %s comes up (up to %ss) ' "$ns" "$pvc" "$CONSUMER" "$SETTLE_WAIT"
      deadline=$(( $(date +%s) + SETTLE_WAIT ))
      SETTLED="no"
      while :; do
        pod_settled "$ns" "$CONSUMER" && { SETTLED="yes"; echo "up"; break; }
        [ "$(date +%s)" -ge "$deadline" ] && { echo "no"; break; }
        printf '.'; sleep "$POLL"
      done
      if [ "$SETTLED" = "yes" ]; then
        ok "${ns}/${pvc}: ${CONSUMER} is Ready, so its volume is fine; leaving it"
        continue
      fi
    fi

    case "$kind" in
      cnpg)
        WANT="$(kubectl -n "$ns" get cluster.postgresql.cnpg.io "$owner" -o jsonpath='{.spec.instances}' 2>/dev/null)"
        if [ "${WANT:-1}" -le 1 ]; then
          # Its only copy died with the node, so an empty PVC is not the problem and deleting it fixes nothing.
          # The restore recreates the Cluster from scratch and takes the PVC with it.
          warn "${ns}/${pvc} belongs to SINGLE-INSTANCE ${owner}; leaving it. Restore it from S3 afterwards:"
          warn "    make restore-cnpg      # in-place, namespace ${ns}, database ${owner}"
          continue
        fi
        say "  ${ns}/${pvc}: CNPG replica of ${owner}, re-cloning from the primary"
        kubectl -n "$ns" delete pvc "$pvc" --wait=false >/dev/null 2>&1
        [ -n "$instance" ] && kubectl -n "$ns" delete pod "$instance" --wait=false >/dev/null 2>&1
        ok "  deleted ${ns}/${pvc}${instance:+ + pod ${instance}}"
        ;;
      rabbitmq)
        # PVC persistence-<sts>-<n>; the pod is the PVC name minus that prefix. The Erlang node adds the
        # RabbitmqCluster's headless-service suffix.
        POD="${pvc#persistence-}"
        RMQ="$(kubectl -n "$ns" get rabbitmqclusters.rabbitmq.com -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
        ERL="rabbit@${POD}.${RMQ}-nodes.${ns}"
        PEER_POD=""
        for p in $(kubectl -n "$ns" get pods -l app.kubernetes.io/name=rabbitmq -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
          case "$p" in *operator*) continue ;; esac
          [ "$p" = "$POD" ] && continue
          [ "$(kubectl -n "$ns" get pod "$p" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = "true" ] && { PEER_POD="$p"; break; }
        done
        say "  ${ns}/${pvc}: RabbitMQ broker ${POD}"
        if [ -z "$PEER_POD" ]; then
          bad "  no Ready broker to forget ${ERL} from; fix the quorum first, then re-run"
          continue
        fi
        PEER_ERL="rabbit@${PEER_POD}.${RMQ}-nodes.${ns}"
        rmq_is_member() {   # is $ERL in the metadata store membership the peer knows about?
          kubectl -n "$ns" exec "$PEER_POD" -c rabbitmq -- \
            rabbitmqctl eval 'ra:members({rabbitmq_metadata, node()}).' 2>/dev/null | grep -q "$POD\."
        }
        # MANDATORY before the wipe, not a remedy afterwards: the survivors hold this broker as a metadata-store
        # member, and a member that comes back blank is refused. So the wipe only happens if the forget worked.
        kubectl -n "$ns" exec "$POD" -c rabbitmq -- rabbitmqctl stop_app >/dev/null 2>&1 \
          && ok "  stopped the app on ${POD}" || warn "  ${POD} was not reachable to stop (gone with the node?)"
        kubectl -n "$ns" exec "$PEER_POD" -c rabbitmq -- rabbitmqctl forget_cluster_node "$ERL" >/dev/null 2>&1
        if rmq_is_member; then
          bad "  ${PEER_POD} still holds ${ERL} as a member; NOT wiping, it could not rejoin"
          warn "  it usually means the peer still sees it running. Stop it, then re-run:"
          warn "    kubectl -n ${ns} exec ${POD} -c rabbitmq -- rabbitmqctl stop_app"
          continue
        fi
        ok "  ${ERL} is no longer a member, safe to wipe"
        kubectl -n "$ns" delete pvc "$pvc" --wait=false >/dev/null 2>&1
        kubectl -n "$ns" delete pod "$POD" --wait=false >/dev/null 2>&1
        ok "  deleted ${ns}/${pvc} + pod ${POD}"
        # Peer discovery auto-clusters onto the LOWEST-ordered broker, so for that one (server-0) a blank start
        # seeds its own cluster of one and nothing ever pulls it in. An explicit join is deterministic for all
        # of them, so just always do it once the broker is back up.
        printf '    waiting for %s to come back (up to %ss) ' "$POD" "$SETTLE_WAIT"
        deadline=$(( $(date +%s) + SETTLE_WAIT ))
        while :; do
          [ "$(kubectl -n "$ns" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && { echo "up"; break; }
          [ "$(date +%s)" -ge "$deadline" ] && { echo "no"; break; }
          printf '.'; sleep "$POLL"
        done
        if kubectl -n "$ns" exec "$POD" -c rabbitmq -- rabbitmqctl eval 'rabbit_nodes:list_running().' 2>/dev/null | grep -q "$PEER_POD\."; then
          ok "  ${POD} joined on its own"
        elif kubectl -n "$ns" exec "$POD" -c rabbitmq -- rabbitmqctl join_cluster "$PEER_ERL" >/dev/null 2>&1; then
          ok "  joined ${POD} to ${PEER_ERL} explicitly"
        else
          bad "  ${POD} is not clustered and would not join ${PEER_ERL}; check its logs"
        fi
        ;;
      *)
        warn "${ns}/${pvc} is on local-path but is neither CNPG nor RabbitMQ; leaving it. Its owner knows what"
        warn "  an empty volume means better than this script does."
        ;;
    esac
  done <<< "$PVCS"
fi

# --- 6. Longhorn: stale replicas, then the disk record -------------------------------------------------
# Longhorn keeps the disk UUID in both the node CR and a longhorn-disk.cfg on the disk. The wipe made a new
# filesystem, so the manager wrote a new cfg while the CR kept the old UUID, and it refuses the disk rather
# than risk the wrong one. The node itself still reports Ready, so this hides unless you look at the disk.
say "6/7 Longhorn disk record on ${NODE}"
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

# --- 7. converge ---------------------------------------------------------------------------------------
# Counts LIVE pods only. A pod whose node died is left behind in phase Failed and never becomes Running, so
# counting those means waiting for something that cannot happen. They are reported once, at the end, as cruft.
say "7/7 waiting for things to come back (up to ${SETTLE_WAIT}s)"
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

Left for you, because neither is mechanical:
  - any SINGLE-INSTANCE CNPG named above: make restore-cnpg
  - re-spread the stateless Deployments once everything is healthy: make rebalance-workloads
NEXT
[ "${ORPHANS:-0}" -gt 0 ] && cat <<NEXT
  - ${ORPHANS} pod(s) left in phase Failed by the outage, which nothing garbage-collects:
      kubectl delete pods -A --field-selector=status.phase=Failed
NEXT
cat <<NEXT

Then walk docs/15_node_recovery.md step 9 to confirm.
NEXT

summary || exit 1
