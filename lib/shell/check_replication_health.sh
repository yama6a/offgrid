#!/usr/bin/env bash
# Exits 0 when every replicated store on this cluster is healthy AND in sync, non-zero otherwise. One shot, no
# waiting: the caller decides how long to keep asking.
#
# Its reason to exist is the OS repo's PRE_DRAIN_HEALTH_HOOK, which cannot know what runs here:
#   in the OS repo's .env:  PRE_DRAIN_HEALTH_HOOK="/abs/path/to/offgrid/lib/shell/check_replication_health.sh"
# Point that at this file and 03e blocks on it before draining EACH node. Also runnable by hand before any
# disruptive work: `make check-replication-health`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
# Each check ECHOES the not-yet-in-sync items, space-separated, empty when all good. A missing CRD or absent
# subsystem means kubectl errors to /dev/null, so empty, so healthy: there is nothing to protect.
# etcd is deliberately NOT here: `talosctl upgrade` already refuses to reboot if it would break quorum.
# Redis is not here either: the instance is standalone with no replication, its data sits on Longhorn (covered
# by the first check), and it simply restarts after a reboot.
CHECKS=(
  "Longhorn volumes:_longhorn_unready"
  "CNPG clusters:_cnpg_unready"
  "RabbitMQ:_rabbitmq_unready"
)

# ---- functions ----

# `healthy` IS Longhorn's all-replicas-in-sync signal; it drops to `degraded` during a rebuild, and detached
# volumes report `unknown` (fine). A degraded volume is exactly when a node might hold its LAST healthy
# replica, so never reboot into that.
_longhorn_unready() {
  kubectl -n longhorn-system get volumes.longhorn.io \
    -o jsonpath='{range .items[?(@.status.robustness=="degraded")]}{.metadata.name}{" "}{end}{range .items[?(@.status.robustness=="faulted")]}{.metadata.name}{" "}{end}' \
    2>/dev/null
}

# In sync means phase=="Cluster in healthy state", readyInstances==spec.instances (the streaming standby is up
# and caught up), and currentPrimary==targetPrimary (no switchover/failover mid-flight). Not zero-lag: the
# operator does a controlled switchover on drain, which needs a caught-up standby, and readyInstances is the
# practical proxy. pg_stat_replication is not queried.
_cnpg_unready() {
  kubectl get clusters.postgresql.cnpg.io -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"|"}{.spec.instances}{"|"}{.status.readyInstances}{"|"}{.status.phase}{"|"}{.status.currentPrimary}{"|"}{.status.targetPrimary}{"\n"}{end}' \
    2>/dev/null \
  | awk -F'|' 'NF>=4 && ( $3 != $2 || $4 != "Cluster in healthy state" || ($6 != "" && $5 != $6) ) { printf "%s ", $1 }'
}

# All broker replicas ready (quorum queues have full membership) plus cluster available. Deliberately ignores
# the NoWarnings condition (benign, e.g. mem request != limit): gating on it would hang forever.
_rabbitmq_unready() {
  kubectl get rabbitmqclusters.rabbitmq.com -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"|"}{range .status.conditions[*]}{.type}={.status};{end}{"\n"}{end}' \
    2>/dev/null \
  | awk -F'|' 'NF>=2 && !( $2 ~ /AllReplicasReady=True;/ && $2 ~ /ClusterAvailable=True;/ ) { printf "%s ", $1 }'
}

run_checks() {
  local pair what fn pending
  [ -n "${NODE:-}" ] && say "replication health (about to drain ${NODE})" || say "replication health"
  for pair in "${CHECKS[@]}"; do
    what="${pair%%:*}"; fn="${pair##*:}"
    pending="$("$fn")"
    if [ -z "${pending// }" ]; then ok "${what} healthy + in sync"; else bad "${what} not in sync: ${pending}"; fi
  done
}

# ---- main ----

require kubectl
use_kubeconfig
assert_api
run_checks

summary || exit 1
