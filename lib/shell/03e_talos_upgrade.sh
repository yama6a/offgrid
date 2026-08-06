#!/usr/bin/env bash
# Rolling, in-place upgrade of the running Talos cluster. Each node goes to the installer its own hardware type
# is built from, resolved by installer_ref_for: the Pi 5 release pinned by TALOS_IMAGE_RELEASE in versions.env
# (built by github.com/yama6a/talos-raspberry-pi5), or a factory.talos.dev image for a type we don't build.
# No reflash: Talos upgrades are atomic A/B with rollback, and talosctl refuses to proceed if a reboot would
# break etcd quorum.
# We CORDON + DRAIN each node ourselves before `talosctl upgrade`, so Talos's own in-upgrade drain finds an
# empty node and cannot hang on a PDB or a slow-terminating pod. A Longhorn volume-health gate runs first, so
# we never reboot a node holding a volume's last healthy replica.
# This upgrades the OS ONLY. Kubernetes is a separate, no-reboot roll: 03f. If both changed, run 03e then 03f.
# Re-run-safe: a node already on the target image is a clean no-op, so a re-run resumes.
set -euo pipefail

# Node list in inventory.yaml; installer_ref_for / TALOSCTL_VERSION come from lib/shell/common.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
HEALTH_TIMEOUT=1800   # secs to wait per node for reboot + installer pull + rejoin-healthy (nodes pull the
                      # image over your home link, so keep this generous; matches talosctl's own default)
# Pre-drain (this script cordons+drains each node BEFORE talosctl upgrade, so Talos's own in-upgrade drain
# finds an empty node and can't hang on a PDB or a slow-terminating pod). See 03_operating_system.md.
REPLICATION_HEALTH_TIMEOUT=1800  # secs: before draining EACH node, wait until every replicated store is healthy
                                 # + in sync (Longhorn volumes, CNPG clusters, RabbitMQ) so taking a node down
                                 # can't drop a volume's last replica or an un-caught-up DB standby. Also waits
                                 # out the PREVIOUS node's post-reboot resync. Abort if exceeded (fix + re-run).
GRACEFUL_DRAIN_TIMEOUT=120  # secs: bounded polite drain (honors eviction) before escalating to force
FORCE_GRACE=20              # secs: grace-period on the force-delete of stragglers (let rabbit flush; 0=now)

require docker kubectl
docker info >/dev/null 2>&1 || die "docker not responding (start Rancher/Docker Desktop)"
[ -f "${CLUSTER_DIR}/talosconfig" ] || die "missing ${CLUSTER_DIR}/talosconfig, run step 03 (03c) first"
use_kubeconfig                                    # KUBECONFIG from secrets/ (native kubectl drives the drain)
assert_api                                        # kubectl must reach the API before we start rebooting

# node_for_ip <ip> -> the k8s node name whose InternalIP == <ip> (Talos nodes are addressed by IP, kubectl by name)
node_for_ip() {
  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
    | awk -v ip="$1" '$2==ip{print $1; exit}'
}

# Each _*_unready below ECHOES the not-yet-in-sync items (space-separated), empty when all good. A missing
# CRD / absent subsystem => kubectl errors to /dev/null => empty => treated as healthy (nothing to protect).

# Longhorn: volumes whose robustness is degraded/faulted. `healthy` IS Longhorn's all-replicas-in-sync signal
# (it drops to `degraded` during a rebuild); detached volumes report `unknown` (fine). A degraded volume is
# exactly when a node might hold its LAST healthy replica -> don't reboot into that.
_longhorn_unready() {
  kubectl -n longhorn-system get volumes.longhorn.io \
    -o jsonpath='{range .items[?(@.status.robustness=="degraded")]}{.metadata.name}{" "}{end}{range .items[?(@.status.robustness=="faulted")]}{.metadata.name}{" "}{end}' \
    2>/dev/null
}

# CNPG: a cluster is in sync only when phase=="Cluster in healthy state", readyInstances==spec.instances (the
# streaming standby is up + caught up), and currentPrimary==targetPrimary (no switchover/failover mid-flight).
_cnpg_unready() {
  kubectl get clusters.postgresql.cnpg.io -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"|"}{.spec.instances}{"|"}{.status.readyInstances}{"|"}{.status.phase}{"|"}{.status.currentPrimary}{"|"}{.status.targetPrimary}{"\n"}{end}' \
    2>/dev/null \
  | awk -F'|' 'NF>=4 && ( $3 != $2 || $4 != "Cluster in healthy state" || ($6 != "" && $5 != $6) ) { printf "%s ", $1 }'
}

# RabbitMQ: all broker replicas ready (quorum queues have full membership) + cluster available. Deliberately
# ignores the NoWarnings condition (benign, e.g. mem request!=limit): gating on it would hang forever.
_rabbitmq_unready() {
  kubectl get rabbitmqclusters.rabbitmq.com -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"|"}{range .status.conditions[*]}{.type}={.status};{end}{"\n"}{end}' \
    2>/dev/null \
  | awk -F'|' 'NF>=2 && !( $2 ~ /AllReplicasReady=True;/ && $2 ~ /ClusterAvailable=True;/ ) { printf "%s ", $1 }'
}

# wait_replication_healthy -> block until Longhorn + CNPG + RabbitMQ are all healthy/in-sync, or die after
# REPLICATION_HEALTH_TIMEOUT naming the stragglers. Run before draining EACH node so the previous node's
# post-reboot resync (replica rebuild / standby catch-up / broker rejoin) has fully settled first.
wait_replication_healthy() {
  local what fn deadline pending pair
  for pair in "Longhorn volumes:_longhorn_unready" "CNPG clusters:_cnpg_unready" "RabbitMQ:_rabbitmq_unready"; do
    what="${pair%%:*}"; fn="${pair##*:}"
    printf '  waiting for %s healthy + in sync' "$what"
    deadline=$(( $(date +%s) + REPLICATION_HEALTH_TIMEOUT ))
    while :; do
      pending="$("$fn")"
      [ -z "${pending// }" ] && { printf ' ok\n'; break; }
      [ "$(date +%s)" -ge "$deadline" ] && die "${what} not healthy/in-sync after ${REPLICATION_HEALTH_TIMEOUT}s: ${pending}. Fix, then re-run (idempotent, skips done nodes)."
      printf '.'; sleep 15
    done
  done
}

# drain_node <node> -> cordon, then a bounded graceful drain; force-delete any stragglers so the node can
# ALWAYS reboot (the per-node Longhorn engine, plus the CNPG and RabbitMQ instances hard anti-affinity pins one
# per node, so a graceful drain can only kill them; they come back after the reboot).
# Do NOT shorten GRACEFUL_DRAIN_TIMEOUT below the time a CNPG switchover needs (~33s measured): the primary's
# eviction is REFUSED by its own PDB until CNPG has handed over, so force-deleting it early turns a ~20s
# switchover into a ~60s failover. See docs/15_node_recovery.md.
drain_node() {
  local node="$1"
  kubectl cordon "$node" >/dev/null
  if ! kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data \
        --timeout="${GRACEFUL_DRAIN_TIMEOUT}s" >/dev/null 2>&1; then
    warn "graceful drain of ${node} timed out; force-deleting stragglers"
    kubectl delete pod --all-namespaces --field-selector "spec.nodeName=${node}" \
      --force --grace-period="${FORCE_GRACE}" >/dev/null 2>&1 || true
  fi
}

# Don't strand a node cordoned OR tainted if we die mid-node (drain/upgrade failure); Talos also uncordons on
# rejoin. The out-of-service taint is dead-node-watcher's: it fires on the reboot (cordoned + NotReady past its
# grace), and a node keeping it accepts no pods, so clear it here rather than depending on that loop being up.
DRAINING_NODE=""
trap '[ -n "$DRAINING_NODE" ] && { kubectl uncordon "$DRAINING_NODE"; kubectl taint node "$DRAINING_NODE" node.kubernetes.io/out-of-service-; } >/dev/null 2>&1 || true' EXIT

# Workers FIRST, then control-plane: a worker holds no etcd, so if an upgrade wedges there it costs no quorum
# and you find out before touching a member. Each node gets the installer its own type is built from, so a
# mixed-hardware cluster cannot be handed one arch's image.
HOSTS=("${WORKER_HOSTS[@]}" "${CP_HOSTS[@]}")

say "pulling ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION} (first run only)"
docker pull -q "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" >/dev/null

# Preflight: the cluster must answer before we start rebooting nodes.
talosctl -n "${CP_IPS[0]}" version >/dev/null 2>&1 || die "cluster API not reachable via ${CLUSTER_DIR}/talosconfig (is the cluster up?)"

echo "== Talos rolling upgrade (talosctl ${TALOSCTL_VERSION}, dockerized) =="
for h in "${HOSTS[@]}"; do
  printf 'Node:   %-12s %-16s %s -> %s\n' "$h" "${NODE_IP[$h]}" "${NODE_TYPE[$h]}" "$(installer_ref_for "$h")"
done
echo
warn "this reboots EVERY node in turn (atomic A/B, a few min each). etcd quorum is held throughout."
printf '>> proceed with the rolling upgrade? type yes: '
read -r confirm </dev/tty 2>/dev/null || confirm=""
[ "$confirm" = "yes" ] || die "aborted"

for host in "${HOSTS[@]}"; do
  ip="${NODE_IP[$host]}"
  installer="$(installer_ref_for "$host")"
  node="$(node_for_ip "$ip")"
  [ -n "$node" ] || die "no k8s node has InternalIP ${ip} (is the cluster up / is inventory.yaml right?)"

  # Gate on replication health BEFORE cordoning (an abort here leaves no stray cordon): never take a node
  # down while any replicated store is degraded / a standby is catching up / a broker is rejoining.
  say "checking replicated stores are healthy + in sync before draining ${node} (${ip})"
  wait_replication_healthy

  # Pre-drain ourselves so Talos's own in-upgrade drain is a fast no-op (can't hang on a PDB / slow pod).
  say "draining ${node}"
  DRAINING_NODE="$node"
  drain_node "$node"

  say "upgrading ${ip} -> ${installer}"
  # --wait tracks the node until it reboots into the new system and rejoins; a node already on the target
  # image completes immediately. talosctl won't proceed if the reboot would cost etcd quorum.
  if talosctl -n "$ip" upgrade --image "$installer" --wait --timeout "${HEALTH_TIMEOUT}s"; then
    ok "${ip} upgraded"
  else
    die "${ip} upgrade failed (see above). Cluster left as-is; fix and re-run (idempotent, skips done nodes)."
  fi
  # Gate on FULL cluster health (etcd quorum fully restored) before touching the next node. A false
  # negative just stops us early; re-running resumes (the upgraded node is then a no-op).
  # Asked of a CONTROL-PLANE node, never of the node just upgraded: Talos answers this check only there
  # ("cluster health check is only available on control plane nodes"), so aiming it at a worker always fails.
  say "waiting for cluster health before the next node"
  talosctl -n "${CP_IPS[0]}" health --wait-timeout "${HEALTH_TIMEOUT}s" >/dev/null 2>&1 \
    || die "cluster not healthy after upgrading ${ip}; stopping. Investigate, then re-run to resume."

  kubectl uncordon "$node" >/dev/null 2>&1 || true   # Talos uncordons on rejoin; make it explicit/idempotent
  kubectl taint node "$node" node.kubernetes.io/out-of-service- >/dev/null 2>&1 || true   # see the trap above
  DRAINING_NODE=""
done

bash "${SCRIPT_DIR}/03g_rebalance_workloads.sh" \
  || warn "rebalance had failures (the upgrade itself succeeded); re-run: make rebalance-workloads"

say "ROLLING UPGRADE COMPLETE"
echo "   image:  ${INSTALLER_REF}"
echo "   verify: talosctl version   (server tag on every node)   /   kubectl get nodes"
echo "   note:   this did NOT change the k8s version; for that run 03f_k8s_upgrade.sh"
