#!/usr/bin/env bash
# Exits 0 when every replicated store on this cluster is healthy AND in sync, non-zero otherwise. One shot, no
# waiting: the caller decides how long to keep asking.
#
# Its reason to exist is the OS repo's PRE_DRAIN_HEALTH_HOOK. Point that at this file and 03e blocks on it
# before draining EACH node, so a reboot can never drop a volume's last healthy replica or take down the node
# hosting a primary whose standby has not caught up. It also waits out the PREVIOUS node's post-reboot resync.
# The OS repo cannot know what runs here, which is why the check lives on this side.
#
#   in the OS repo's .env:  PRE_DRAIN_HEALTH_HOOK="/abs/path/to/offgrid/lib/shell/check_replication_health.sh"
#
# Also runnable by hand before any disruptive work: `make check-replication-health`.
#
# A store whose CRD is absent is treated as healthy, so this is a no-op on a cluster that does not run it.
# etcd is deliberately NOT checked: `talosctl upgrade` already refuses to reboot if it would break quorum.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require kubectl
use_kubeconfig
assert_api

# Each _*_unready ECHOES the not-yet-in-sync items (space-separated), empty when all good. A missing CRD or an
# absent subsystem means kubectl errors to /dev/null, so empty, so healthy: nothing to protect.

# Longhorn: volumes whose robustness is degraded/faulted. `healthy` IS Longhorn's all-replicas-in-sync signal
# (it drops to `degraded` during a rebuild); detached volumes report `unknown` (fine). A degraded volume is
# exactly when a node might hold its LAST healthy replica, so never reboot into that.
_longhorn_unready() {
  kubectl -n longhorn-system get volumes.longhorn.io \
    -o jsonpath='{range .items[?(@.status.robustness=="degraded")]}{.metadata.name}{" "}{end}{range .items[?(@.status.robustness=="faulted")]}{.metadata.name}{" "}{end}' \
    2>/dev/null
}

# CNPG: a cluster is in sync only when phase=="Cluster in healthy state", readyInstances==spec.instances (the
# streaming standby is up + caught up), and currentPrimary==targetPrimary (no switchover/failover mid-flight).
# "In sync" here means the standby is ready/streaming, not zero-lag: the operator does a controlled switchover
# on drain, which needs a caught-up standby, and readyInstances is the practical proxy. We do not query
# pg_stat_replication.
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

# Redis is not gated: the instance is standalone with no replication, its data sits on Longhorn (covered
# above), and it simply restarts after a reboot.

[ -n "${NODE:-}" ] && say "replication health (about to drain ${NODE})" || say "replication health"

for pair in "Longhorn volumes:_longhorn_unready" \
            "CNPG clusters:_cnpg_unready" \
            "RabbitMQ:_rabbitmq_unready"; do
  what="${pair%%:*}"; fn="${pair##*:}"
  pending="$("$fn")"
  if [ -z "${pending// }" ]; then ok "${what} healthy + in sync"; else bad "${what} not in sync: ${pending}"; fi
done

summary || exit 1
