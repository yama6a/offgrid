#!/usr/bin/env bash
# Moves the roles that must not be killed abruptly off NODE, then exits 0. Nothing else about the node changes:
# no cordon, no drain, no reboot.
#
# Its reason to exist is node tooling that drains a node before rebooting it. That tooling force-deletes pods
# whose graceful eviction times out, and a Postgres PRIMARY killed that way can be left unable to pg_rewind
# against the instance that replaced it, so it never rejoins and needs its data directory rebuilt by hand.
# A replica killed the same way just re-syncs.
#   e.g. an evacuate hook variable:  PRE_DRAIN_EVACUATE_HOOK="/abs/path/to/lib/shell/evacuate_node.sh"
# The caller runs this ONCE per node, never in a retry loop: it elects a new primary, so repeated calls would
# keep moving it. Re-running by hand is still safe; with no primary on NODE it does nothing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
SWITCHOVER_TIMEOUT=300  # secs to wait for one cluster to finish promoting the instance we picked

# ---- functions ----

check_prerequisites() {
  require kubectl
  use_kubeconfig
  assert_api
  [ -n "${NODE:-}" ] || die "NODE is unset: pass the node to evacuate, e.g. NODE=pi-cp1 $0"
  kubectl get node "$NODE" >/dev/null 2>&1 || die "no such node: ${NODE}"
}

# ns/name of every CNPG cluster whose CURRENT primary pod sits on NODE. Reads the pod rather than the Cluster's
# status.currentPrimary alone, because that names an instance, not where it is running.
_clusters_primary_here() {
  kubectl get pods -A -l cnpg.io/instanceRole=primary \
    -o jsonpath="{range .items[?(@.spec.nodeName=='${NODE}')]}{.metadata.namespace}/{.metadata.labels.cnpg\.io/cluster}|{.metadata.name}{\"\n\"}{end}" 2>/dev/null
}

_instances() { kubectl -n "${1%%/*}" get cluster "${1##*/}" -o jsonpath='{.spec.instances}' 2>/dev/null; }

# A ready instance of $1 that is NOT on NODE and is not the primary. Empty when there is nowhere to go, which is
# a single-instance cluster or one whose replicas are all on this node.
_switchover_target() {
  local ns="${1%%/*}" cluster="${1##*/}"
  kubectl -n "$ns" get pods -l "cnpg.io/cluster=${cluster},cnpg.io/instanceRole=replica" \
    -o jsonpath="{range .items[?(@.spec.nodeName!='${NODE}')]}{.metadata.name}{\" \"}{range .status.conditions[?(@.type=='Ready')]}{.status}{end}{\"\n\"}{end}" 2>/dev/null \
  | awk '$2=="True"{print $1; exit}'
}

# CNPG switches over by being told which instance should be primary: it checkpoints and demotes the old one
# cleanly, so the old primary rejoins on the new timeline instead of diverging. `kubectl cnpg promote` is the
# same write, and is not assumed to be installed.
_promote() {
  local ns="${1%%/*}" cluster="${1##*/}" target="$2"
  kubectl -n "$ns" patch cluster "$cluster" --subresource status --type merge \
    -p "{\"status\":{\"targetPrimary\":\"${target}\"}}" >/dev/null 2>&1
}

_wait_switchover() {
  local ns="${1%%/*}" cluster="${1##*/}" target="$2" deadline
  deadline=$(( $(date +%s) + SWITCHOVER_TIMEOUT ))
  until [ "$(kubectl -n "$ns" get cluster "$cluster" -o jsonpath='{.status.currentPrimary}' 2>/dev/null)" = "$target" ]; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    printf '.'; sleep 5
  done
  # currentPrimary flips before the old one has finished rejoining, and draining into that is the thing we came
  # here to avoid.
  until [ "$(kubectl -n "$ns" get cluster "$cluster" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Cluster in healthy state" ]; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    printf '.'; sleep 5
  done
  return 0
}

evacuate_cnpg() {
  local line id pod target found=0
  while read -r line; do
    [ -n "$line" ] || continue
    id="${line%%|*}"; pod="${line##*|}"
    found=1
    # Nothing to switch to and nothing to lose: with one instance no replica is ever promoted, so there is no
    # new timeline for the old primary to fail to rewind against. It just stops and starts again on its data.
    if [ "$(_instances "$id")" = "1" ]; then
      warn "${id}: single instance on ${NODE}, skipped (it goes down with the node either way)"
      continue
    fi
    target="$(_switchover_target "$id")"
    if [ -z "$target" ]; then
      die "${id}: primary ${pod} is on ${NODE} and no ready replica is elsewhere, so the drain would force-kill a primary that CAN diverge. Wait for a replica, or move one off ${NODE}, then re-run."
    fi
    printf '  %s: %s -> %s' "$id" "$pod" "$target"
    _promote "$id" "$target" || { printf '\n'; die "${id}: could not set targetPrimary to ${target}"; }
    _wait_switchover "$id" "$target" || { printf '\n'; die "${id}: switchover to ${target} did not settle in ${SWITCHOVER_TIMEOUT}s"; }
    printf ' ok\n'
  done < <(_clusters_primary_here)
  [ "$found" -eq 1 ] || echo "  no CNPG primary on ${NODE}"
}

# ---- main ----

case "${1:-}" in
  -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

check_prerequisites
say "evacuating ${NODE}"
evacuate_cnpg
