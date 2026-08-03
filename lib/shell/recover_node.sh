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
DISK_RETRIES=12     # re-add attempts for the Longhorn disk; its webhook refuses while the manager resyncs
DISK_RETRY_SLEEP=10
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

# --- 2. etcd: drop the member whose peer URL is this node -----------------------------------------------
# A wiped node comes back with a NEW etcd identity, and the old entry at the same peer URL blocks the join.
say "2/7 etcd membership"
MEMBER="$(talosctl -n "$SURVIVOR_IP" -e "$SURVIVOR_IP" etcd members 2>/dev/null | awk -v ip="$IP" '$0 ~ ip {print $2}' | head -1)"
if [ -z "$MEMBER" ]; then
  ok "no etcd member at ${IP} (already removed, or the node never joined)"
else
  if talosctl -n "$SURVIVOR_IP" -e "$SURVIVOR_IP" etcd remove-member "$MEMBER" >/dev/null 2>&1; then
    ok "removed stale etcd member ${MEMBER}"
  else
    bad "could not remove etcd member ${MEMBER}; check quorum on ${SURVIVOR}"
  fi
fi

# --- 3. machine config ---------------------------------------------------------------------------------
# A maintenance node answers --insecure and rejects a secure call; a configured one is the reverse. That is
# how we tell "waiting to be adopted" from "already adopted", which is what makes this step re-runnable.
say "3/7 machine config"
if talosctl -n "$IP" -e "$IP" version >/dev/null 2>&1; then
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
        # MANDATORY before the wipe, not a remedy afterwards: the survivors still hold this broker as a
        # metadata-store member, and a member that comes back blank is refused. Worst for the lowest-ordered
        # broker, which peer discovery makes seed a SECOND cluster instead of joining.
        kubectl -n "$ns" exec "$POD" -c rabbitmq -- rabbitmqctl stop_app >/dev/null 2>&1 \
          && ok "  stopped the app on ${POD}" || warn "  ${POD} was not reachable to stop, continuing"
        if kubectl -n "$ns" exec "$PEER_POD" -c rabbitmq -- rabbitmqctl forget_cluster_node "$ERL" >/dev/null 2>&1; then
          ok "  ${PEER_POD} forgot ${ERL}"
        else
          warn "  ${PEER_POD} would not forget ${ERL} (already forgotten, or it still looks running)"
        fi
        kubectl -n "$ns" delete pvc "$pvc" --wait=false >/dev/null 2>&1
        kubectl -n "$ns" delete pod "$POD" --wait=false >/dev/null 2>&1
        ok "  deleted ${ns}/${pvc} + pod ${POD}; it rejoins as a new member"
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

DISK_COND="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" -o jsonpath='{range .status.diskStatus.*}{range .conditions[?(@.type=="Ready")]}{.status}{end}{end}' 2>/dev/null)"
if [ "$DISK_COND" = "True" ]; then
  ok "the disk record already matches the disk; nothing to reset"
else
  DKEY="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" -o go-template='{{range $k,$v := .spec.disks}}{{$k}}{{end}}' 2>/dev/null)"
  SPEC="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$SURVIVOR" -o jsonpath='{.spec.disks}' 2>/dev/null)"
  [ -n "$SPEC" ] || die "could not read ${SURVIVOR}'s disk spec to copy"
  if [ -n "$DKEY" ]; then
    # The webhook refuses to remove a schedulable disk, so allowScheduling has to land first. And a merge
    # patch of {"disks":{}} is a no-op, because JSON merge patch only deletes a key set to null.
    kubectl -n "$LH_NS" patch nodes.longhorn.io "$NODE" --type merge \
      -p "{\"spec\":{\"disks\":{\"${DKEY}\":{\"allowScheduling\":false}}}}" >/dev/null 2>&1 \
      && ok "disabled scheduling on ${DKEY}" || bad "could not disable scheduling on ${DKEY}"
    kubectl -n "$LH_NS" patch nodes.longhorn.io "$NODE" --type json \
      -p "[{\"op\":\"remove\",\"path\":\"/spec/disks/${DKEY}\"}]" >/dev/null 2>&1 \
      && ok "removed the stale disk record ${DKEY}" || bad "could not remove ${DKEY}"
  fi
  ADDED="no"
  for i in $(seq 1 "$DISK_RETRIES"); do
    if kubectl -n "$LH_NS" patch nodes.longhorn.io "$NODE" --type merge \
         -p "{\"spec\":{\"disks\":${SPEC}}}" >/dev/null 2>&1; then
      ok "re-added the disk from ${SURVIVOR}'s spec (attempt ${i})"; ADDED="yes"; break
    fi
    sleep "$DISK_RETRY_SLEEP"   # "spec and status of disks ... are being syncing": the manager is mid-resync
  done
  [ "$ADDED" = "yes" ] || bad "the disk re-add was refused ${DISK_RETRIES} times; retry: make recover-node NODE=${NODE}"
fi

# --- 7. converge ---------------------------------------------------------------------------------------
say "7/7 waiting for things to come back (up to ${SETTLE_WAIT}s)"
deadline=$(( $(date +%s) + SETTLE_WAIT ))
while :; do
  PENDING="$(kubectl get pods -A --no-headers 2>/dev/null | grep -Evc 'Running|Completed')"
  DEG="$(kubectl -n "$LH_NS" get volumes.longhorn.io -o jsonpath='{range .items[*]}{.status.robustness}{"\n"}{end}' 2>/dev/null | grep -vc '^healthy$')"
  printf '    pods not running: %s   volumes not healthy: %s\n' "${PENDING:-?}" "${DEG:-?}"
  [ "${PENDING:-1}" -eq 0 ] && [ "${DEG:-1}" -eq 0 ] && break
  [ "$(date +%s)" -ge "$deadline" ] && { warn "not fully converged yet; a Longhorn rebuild or a CNPG clone can outlast this"; break; }
  sleep "$POLL"
done

DISK_UUID="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" -o jsonpath='{range .status.diskStatus.*}{.diskUUID}{end}' 2>/dev/null)"
[ -n "$DISK_UUID" ] && ok "${NODE} Longhorn disk ${DISK_UUID}"
MCOUNT="$(talosctl -n "$SURVIVOR_IP" -e "$SURVIVOR_IP" etcd members 2>/dev/null | grep -c '^' )"
[ "${MCOUNT:-0}" -gt 1 ] && ok "etcd has $(( MCOUNT - 1 )) members"

cat <<NEXT

Left for you, because neither is mechanical:
  - any SINGLE-INSTANCE CNPG named above: make restore-cnpg
  - re-spread the stateless Deployments once everything is healthy: make rebalance-workloads

Then walk docs/15_node_recovery.md step 9 to confirm.
NEXT

summary || exit 1
