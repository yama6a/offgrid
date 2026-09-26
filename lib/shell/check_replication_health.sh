#!/usr/bin/env bash
# Exits 0 when every replicated store is healthy and in sync, non-zero otherwise.
# It checks once and does not wait. The caller decides how long to retry.
#
# Point the pre-drain gate of your node tooling at this script, so it waits before draining each node.
# Example: PRE_DRAIN_HEALTH_HOOK="/abs/path/to/lib/shell/check_replication_health.sh"
# Run it by hand before disruptive work with `make check-replication-health`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
# Each check prints the items not yet in sync, space-separated, and nothing when all are in sync.
# A missing CRD prints nothing and counts as healthy, because there is nothing to protect.
# etcd has no check: node tooling already refuses a reboot that breaks etcd quorum, and it sees quorum directly.
# Redis has no check: it is standalone, its data is on Longhorn, and it restarts after a reboot.
CHECKS=(
  "Longhorn volumes:_longhorn_unready"
  "CNPG clusters:_cnpg_unready"
  "RabbitMQ:_rabbitmq_unready"
)

# ---- functions ----

# Longhorn reports `degraded` during a replica rebuild and `unknown` for a detached volume, which is fine.
# A node can hold the last healthy replica of a degraded volume, so a reboot then risks the data.
_longhorn_unready() {
  kubectl -n longhorn-system get volumes.longhorn.io \
    -o jsonpath='{range .items[?(@.status.robustness=="degraded")]}{.metadata.name}{" "}{end}{range .items[?(@.status.robustness=="faulted")]}{.metadata.name}{" "}{end}' \
    2> /dev/null
}

# readyInstances stands in for replication lag. The operator switches over on drain, which needs a caught-up
# standby. currentPrimary differs from targetPrimary while a switchover or failover runs.
_cnpg_unready() {
  kubectl get clusters.postgresql.cnpg.io -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"|"}{.spec.instances}{"|"}{.status.readyInstances}{"|"}{.status.phase}{"|"}{.status.currentPrimary}{"|"}{.status.targetPrimary}{"\n"}{end}' \
    2> /dev/null \
    | awk -F'|' 'NF>=4 && ( $3 != $2 || $4 != "Cluster in healthy state" || ($6 != "" && $5 != $6) ) { printf "%s ", $1 }'
}

# Ignores the NoWarnings condition. It flags harmless settings, such as a memory request below the limit,
# so a gate on it never passes.
_rabbitmq_unready() {
  kubectl get rabbitmqclusters.rabbitmq.com -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"|"}{range .status.conditions[*]}{.type}={.status};{end}{"\n"}{end}' \
    2> /dev/null \
    | awk -F'|' 'NF>=2 && !( $2 ~ /AllReplicasReady=True;/ && $2 ~ /ClusterAvailable=True;/ ) { printf "%s ", $1 }'
}

run_checks() {
  local pair what fn pending
  [ -n "${NODE:-}" ] && say "replication health (about to drain ${NODE})" || say "replication health"
  for pair in "${CHECKS[@]}"; do
    what="${pair%%:*}"
    fn="${pair##*:}"
    pending="$("$fn")"
    if [ -z "${pending// /}" ]; then ok "${what} healthy and in sync"; else bad "${what} not in sync: ${pending}"; fi
  done
}

# ---- main ----

require kubectl
use_kubeconfig
assert_api
run_checks

summary || exit 1
