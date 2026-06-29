#!/usr/bin/env bash
#
# lib/config.sh — the single source of truth for the repo's CONFIGURABLE knobs/values.
#
# Sourced (transitively, via lib/common.sh) by all bootstrap scripts. Assignments only — no side
# effects, no `set` (each script manages its own shell options). These are plain values: to change
# the cluster's config, EDIT them here. (The handful of genuine per-run overrides — KUBECONFIG, the
# flasher's RAW_XZ, ArgoCD's REPO_URL/GIT_TOKEN/ASSUME_PUSHED — keep the `${VAR:-…}` form, but in
# their own scripts, not here.)
#
# This file holds things you might actually CONFIGURE (versions, topology, domains, namespaces, …)
# plus the few values genuinely shared across scripts. Build-machinery internals used by a single
# script — registry/builder names, the gmake path, the staged-image filename, a step's own check
# expectations — live in that script, not here.

# Repo root — anchors the paths below. Set by lib/common.sh; fall back to the dir above this file
# (config.sh lives in lib/) when sourced directly.
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ============================================================================
# Cluster topology  (nodes / VIP / disk / NIC — step 03)
# ============================================================================
# "hostname:ip" per node — reserve each IP in your router. Edit to your cluster.
CLUSTER_NODES=("pi-cp1:192.168.10.201" "pi-cp2:192.168.10.202" "pi-cp3:192.168.10.203")
NODES="${CLUSTER_NODES[*]##*:}"       # IPs only (space-separated); used by boot-verify + reset

CLUSTER_NAME="home-pi"                # talosctl gen config cluster name
CLUSTER_VIP="192.168.100.1"           # control-plane VIP (unused IP, outside your DHCP pool)
API_PORT=50000                        # Talos API port

EXPECT_NIC="end0"                     # Pi 5 wired NIC
EXPECT_DISK="nvme0n1"                 # the NVMe
IFACE="${EXPECT_NIC}"                 # wired NIC the VIP binds to (dhcp + vip)
INSTALL_DISK="/dev/${EXPECT_DISK}"    # nvme0n1 -> /dev/nvme0n1
EPHEMERAL_SIZE="64GiB"                # EPHEMERAL cap; rest of the NVMe -> cnpg (fixed) + longhorn (remainder)
CNPG_VOLUME_SIZE="50GiB"              # fixed-size 'cnpg' user volume (local-path-provisioner backs CNPG here). See 18_local_path_provisioner.md
# Node label node.kubernetes.io/instance-type, stamped via machine.nodeLabels in 03d. Lets the
# nic-keeper DaemonSet (06_nic_keeper.md) target rpi5 hardware only. On the kubelet NodeRestriction
# allowlist (so Talos may set it); an arbitrary kubernetes.io/* label would be rejected by admission.
NODE_INSTANCE_TYPE="rpi5"

# ============================================================================
# Image build — versions + extensions  (step 03 image build)
# ============================================================================
TALOS_VERSION="v1.13.4"               # siderolabs/talos; also the talosctl client + expected server
PKG_VERSION="v1.13.0"                 # siderolabs/pkgs (matches Talos minor; ships the 6.18 base config)
BUILDER_VERSION="v1.11.5"             # talos-rpi5/talos-builder release (the Makefile scaffold; versions overridden below)
# talos-rpi5/sbc-raspberrypi5 (u-boot + BCM2712 dtb + config.txt). The repo has no tags,
# so pin a commit. SHA below = main as of 2026-06-20; bump deliberately, diff against main.
SBCOVERLAY_VERSION="7d04484be2beb4b1fca56538d2b6d07e7d58681f"
MACHINERY_VERSION="${TALOS_VERSION}"  # overlay rebuilt against this (must match TALOS_VERSION)
TALOSCTL_VERSION="${TALOS_VERSION}"   # talosctl container (lib/common.sh talosctl(); boot-verify)

# Kernel: a raspberrypi/linux tag on rpi-6.18.y.
KERNEL_REF="stable_20260609"          # stable_20260609 == Linux 6.18.34.

# Digest-pinned system extensions for this Talos version; from the Image Factory:
#   curl -s https://factory.talos.dev/version/${TALOS_VERSION}/extensions/official | jq .
ISCSI_EXT="ghcr.io/siderolabs/iscsi-tools:v0.2.0@sha256:12521145e65403037a7412bf9abce1efd08583e018e5eed8e1c5b9faf52d1da4"
UTIL_EXT="ghcr.io/siderolabs/util-linux-tools:2.41.4@sha256:3f0105dd85607dcd81ee12703c0f432f32159cde430dfe16b5112e76e9d5a5d4"

# ---- build cache key + output dir (shared: 03a builder writes, 03b flasher reads) ----
# Keyed by the pinned inputs above so 03a and 03b resolve the SAME paths: change any version/ref/tag
# and the build lands in a fresh .cache/<key> dir (no stale checkouts). The registry/builder names,
# the gmake path, the staged-image filename, and the RAW_XZ override are 03a/03b-local build internals.
CONFIG_DIR="${REPO_ROOT}/03_operating_system"        # the step-03 folder (build scratch lives under it)
BUILD_KEY="${TALOS_VERSION}-${KERNEL_REF}-$(printf '%s' \
  "${BUILDER_VERSION}|${PKG_VERSION}|${SBCOVERLAY_VERSION}|${MACHINERY_VERSION}|${ISCSI_EXT}|${UTIL_EXT}" \
  | shasum -a 256 | cut -c1-8)"
BUILD_DIR="${CONFIG_DIR}/.cache/${BUILD_KEY}"        # build scratch + output (gitignored)
OUT_DIR="${BUILD_DIR}/out"                           # final image is staged here for the flasher

# ============================================================================
# Shared Kubernetes identifiers  (used across 07/12/15/16)
# ============================================================================
# The sealed-secrets controller to seal against (kubeseal --controller-namespace/--controller-name).
# Matches 02_sealed_secrets (fullnameOverride: sealed-secrets in its values.yaml).
SS_CONTROLLER_NS="sealed-secrets"
SS_CONTROLLER_NAME="sealed-secrets"
SS_POD_SELECTOR="app.kubernetes.io/name=sealed-secrets"      # the controller pods
SS_KEY_LABEL="sealedsecrets.bitnami.com/sealed-secrets-key"  # label on its key Secrets

MONITORING_NS="monitoring"   # the monitoring stack namespace (15/16)

# ============================================================================
# Networking + domains  (step 04 Cilium LB-IPAM, step 10 gateway)
# ============================================================================
# LoadBalancer-IPAM address pool (CiliumLoadBalancerIPPool). Must sit on the same L2 segment as the
# nodes' end0 interface and OUTSIDE the DHCP lease range, or you'll get IP conflicts. See 04_networking.md.
LB_RANGE_START="192.168.100.10"
LB_RANGE_STOP="192.168.100.250"

# ACME registration email for the Let's Encrypt ClusterIssuers (account-level; expiry notices here).
LE_EMAIL="letsencrypt@example.com"
# Base domain for cluster-hosted app hostnames. Hostnames are derived as <subdomain>.<baseDomain>,
# e.g. the sample app becomes sample-workload.${BASE_DOMAIN}.
BASE_DOMAIN="example.com"

# ============================================================================
# SMTP  (step 15 Alertmanager, step 16 Grafana)
# ============================================================================
# SMTP smarthost Alertmanager relays through (Gmail submission). host:port.
SMTP_SMARTHOST="smtp.gmail.com:587"
SMTP_SECRET_KEY="password"   # data key in both SMTP secrets (the secret NAMES live in 15/16)

# Cilium (CNI/LB/gateway/encryption) is step 04. Its version, values, Gateway API CRDs, and LB-IPAM
# pool all live in the wrapper chart argo_apps/platform/charts/00_cilium/ — see 04_networking.md.
