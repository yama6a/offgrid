#!/usr/bin/env bash
#
# config.sh — shared knobs for step 04 (networking).
#
# Sourced by 04_cilium.sh. The script writes these into the cilium wrapper chart's
# values.yaml (loadBalancer.ipPool) via yq, so the imperative bootstrap and ArgoCD
# render the SAME LB-IPAM pool. This file is the source of truth for the range; edit
# it here and re-run 04_cilium.sh — don't hand-edit values.yaml. Override per-run via
# env, e.g. `LB_RANGE_START=192.168.100.50 ./04_cilium.sh`.

# ---- knobs ------------------------------------------------------------------
# LoadBalancer-IPAM address pool (CiliumLoadBalancerIPPool). Must sit on the same L2
# segment as the nodes' end0 interface and OUTSIDE the DHCP lease range, or you'll get
# IP conflicts. See 04_networking.md.
LB_RANGE_START="${LB_RANGE_START:-192.168.100.10}"
LB_RANGE_STOP="${LB_RANGE_STOP:-192.168.100.250}"
# -----------------------------------------------------------------------------
