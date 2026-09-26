#!/usr/bin/env bash
# Moves every CNPG primary off NODE, then exits 0. It does not cordon, drain or reboot the node.
#
# A drain force-deletes a pod when its graceful eviction times out.
# A Postgres primary killed that way can fail to pg_rewind against the instance that replaced it.
# It then never rejoins, and its data directory needs a rebuild by hand. A replica killed that way re-syncs.
#
# Example hook: PRE_DRAIN_EVACUATE_HOOK="/abs/path/to/lib/shell/evacuate_node.sh"
# The caller runs this once per node, never in a retry loop, because each call elects a new primary.
# A re-run by hand is safe. With no primary on NODE, it does nothing.
# Usage: NODE=<hostname> evacuate_node.sh, or make evacuate-node NODE=<hostname>
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
SWITCHOVER_TIMEOUT=300 # seconds to wait for one cluster to promote the picked instance

# ---- functions ----

check_prerequisites() {
  require kubectl
  use_kubeconfig
  assert_api
  [ -n "${NODE:-}" ] || die "NODE is unset. Pass the node to evacuate, for example NODE=talos-cp1 $0"
  kubectl get node "$NODE" > /dev/null 2>&1 || die "no such node: ${NODE}"
}

# Reads the primary pod, not status.currentPrimary. That field names an instance, not the node it runs on.
_clusters_primary_here() {
  kubectl get pods -A -l cnpg.io/instanceRole=primary \
    -o jsonpath="{range .items[?(@.spec.nodeName=='${NODE}')]}{.metadata.namespace}/{.metadata.labels.cnpg\.io/cluster}|{.metadata.name}{\"\n\"}{end}" 2> /dev/null
}

_instances() { kubectl -n "${1%%/*}" get cluster "${1##*/}" -o jsonpath='{.spec.instances}' 2> /dev/null; }

# Prints nothing when no ready replica runs on another node.
_switchover_target() {
  local ns="${1%%/*}" cluster="${1##*/}"
  kubectl -n "$ns" get pods -l "cnpg.io/cluster=${cluster},cnpg.io/instanceRole=replica" \
    -o jsonpath="{range .items[?(@.spec.nodeName!='${NODE}')]}{.metadata.name}{\" \"}{range .status.conditions[?(@.type=='Ready')]}{.status}{end}{\"\n\"}{end}" 2> /dev/null \
    | awk '$2=="True"{print $1; exit}'
}

# Setting targetPrimary makes CNPG checkpoint and demote the old primary, so it rejoins on the new timeline.
# `kubectl cnpg promote` does the same write, but the plugin may not be installed.
_promote() {
  local ns="${1%%/*}" cluster="${1##*/}" target="$2"
  kubectl -n "$ns" patch cluster "$cluster" --subresource status --type merge \
    -p "{\"status\":{\"targetPrimary\":\"${target}\"}}" > /dev/null 2>&1
}

_wait_switchover() {
  local ns="${1%%/*}" cluster="${1##*/}" target="$2" deadline
  deadline=$(($(date +%s) + SWITCHOVER_TIMEOUT))
  until [ "$(kubectl -n "$ns" get cluster "$cluster" -o jsonpath='{.status.currentPrimary}' 2> /dev/null)" = "$target" ]; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    printf '.'
    sleep 5
  done
  # currentPrimary changes before the old primary finishes rejoining. A drain at that point is the risk to avoid.
  until [ "$(kubectl -n "$ns" get cluster "$cluster" -o jsonpath='{.status.phase}' 2> /dev/null)" = "Cluster in healthy state" ]; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    printf '.'
    sleep 5
  done
  return 0
}

evacuate_cnpg() {
  local line id pod target found=0
  while read -r line; do
    [ -n "$line" ] || continue
    id="${line%%|*}"
    pod="${line##*|}"
    found=1
    # A single instance never gets a new timeline, so it has nothing to rewind against. It restarts on its data.
    if [ "$(_instances "$id")" = "1" ]; then
      warn "${id}: single instance on ${NODE}, skipped. It goes down with the node either way."
      continue
    fi
    target="$(_switchover_target "$id")"
    if [ -z "$target" ]; then
      die "${id}: primary ${pod} is on ${NODE} and no ready replica runs on another node. The drain would force-kill a primary that can diverge. Wait for a replica, or move one off ${NODE}, then run this again."
    fi
    printf '  %s: %s to %s' "$id" "$pod" "$target"
    _promote "$id" "$target" || {
      printf '\n'
      die "${id}: could not set targetPrimary to ${target}"
    }
    _wait_switchover "$id" "$target" || {
      printf '\n'
      die "${id}: switchover to ${target} did not settle in ${SWITCHOVER_TIMEOUT}s"
    }
    printf ' ok\n'
  done < <(_clusters_primary_here)
  [ "$found" -eq 1 ] || echo "  no CNPG primary on ${NODE}"
}

# ---- main ----

case "${1:-}" in
  -h | --help)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

check_prerequisites
say "evacuating ${NODE}"
evacuate_cnpg
