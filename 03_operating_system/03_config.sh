#!/usr/bin/env bash
#
# 03_config.sh — shared config for the step-03 scripts. Sourced by:
#   03a_talos_image_builder.sh, 03b_talos_image_flasher.sh,
#   03c_talos_boot_verify.sh, 03d_talos_cluster_config.sh
#
# Assignments only — no side effects, no `set` (the scripts manage their own shell
# options). `: "${VAR:=default}"` keeps env overrides working, e.g.
#   RAW_XZ=/path/to.raw.xz ./03b_talos_image_flasher.sh

# ---- versions (single source of truth) --------------------------------------
TALOS_VERSION="v1.13.4"               # siderolabs/talos; also the talosctl client + expected server
PKG_VERSION="v1.13.0"                 # siderolabs/pkgs (matches Talos minor; ships the 6.18 base config)
BUILDER_VERSION="v1.11.5"             # talos-rpi5/talos-builder release (the Makefile scaffold; versions overridden below)
# talos-rpi5/sbc-raspberrypi5 (u-boot + BCM2712 dtb + config.txt). The repo has no tags,
# so pin a commit. SHA below = main as of 2026-06-20; bump deliberately, diff against main.
SBCOVERLAY_VERSION="7d04484be2beb4b1fca56538d2b6d07e7d58681f"
MACHINERY_VERSION="${TALOS_VERSION}"  # overlay rebuilt against this (must match TALOS_VERSION)
TALOSCTL_VERSION="${TALOS_VERSION}"   # talosctl container used by boot-verify

# Kernel: a raspberrypi/linux tag on rpi-6.18.y.
KERNEL_REF="stable_20260609"          # stable_20260609 == Linux 6.18.34.

# ---- system extensions ------------------------------------------------------
# Digest-pinned for this Talos version; from the Image Factory:
#   curl -s https://factory.talos.dev/version/${TALOS_VERSION}/extensions/official | jq .
ISCSI_EXT="ghcr.io/siderolabs/iscsi-tools:v0.2.0@sha256:12521145e65403037a7412bf9abce1efd08583e018e5eed8e1c5b9faf52d1da4"
UTIL_EXT="ghcr.io/siderolabs/util-linux-tools:2.41.4@sha256:3f0105dd85607dcd81ee12703c0f432f32159cde430dfe16b5112e76e9d5a5d4"

# ---- paths + image name (builder + flasher) ---------------------------------
CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # this folder (03_operating_system)
# Cache is keyed by the pinned build inputs: change any version/ref/tag above and the
# build lands in a fresh .cache/<key> dir (switching back reuses the old one) — no stale
# checkouts. The flasher derives the same key, so it flashes the image matching this config.
BUILD_KEY="${TALOS_VERSION}-${KERNEL_REF}-$(printf '%s' \
  "${BUILDER_VERSION}|${PKG_VERSION}|${SBCOVERLAY_VERSION}|${MACHINERY_VERSION}|${ISCSI_EXT}|${UTIL_EXT}" \
  | shasum -a 256 | cut -c1-8)"
: "${BUILD_DIR:=${CONFIG_DIR}/.cache/${BUILD_KEY}}"  # build scratch + output (gitignored)
: "${OUT_DIR:=${BUILD_DIR}/out}"      # final image is staged here for the flasher
IMAGE_NAME="metal-arm64-rpi5.raw.xz"  # staged name (rpi5/grub imager profile emits .raw.xz)
: "${RAW_XZ:=${OUT_DIR}/${IMAGE_NAME}}"  # override to flash a specific build
GMAKE="/opt/homebrew/opt/make/libexec/gnubin/make"  # GNU make >= 4 (system make is 3.81)

# ---- local build infra (builder) --------------------------------------------
REGISTRY_PORT="5010"                       # 5001 is often taken by kind
REGISTRY_HOST="localhost:${REGISTRY_PORT}" # local build registry
REGISTRY_USER="talos-rpi5"                 # path component in the local registry
REGISTRY_NAME="talos-registry"             # registry container name
BUILDER_NAME="talos-bx"                    # docker-container buildx builder (mergeop-capable)
SRCSERVER_NAME="talos-srcserver"           # local HTTP server for the (non-byte-stable) kernel tarball
SRCSERVER_PORT="8099"

# ---- nodes (single source for boot-verify 03c + cluster bring-up 03d) -------
# "hostname:ip" per node — reserve each IP in your router. Edit to your cluster.
CLUSTER_NODES=("pi-cp1:192.168.10.201" "pi-cp2:192.168.10.202" "pi-cp3:192.168.10.203")
NODES="${CLUSTER_NODES[*]##*:}"       # IPs only (space-separated), used by boot-verify

# ---- boot-verify checks (03c_talos_boot_verify.sh) --------------------------
API_PORT=50000                        # Talos API
EXPECT_TALOS="${TALOS_VERSION}"       # our build's Talos version (a local "-dirty" build matches too)
EXPECT_NIC="end0"                     # Pi 5 wired NIC
EXPECT_DISK="nvme0n1"                 # the NVMe
EXPECT_CMDLINE="console=ttyAMA0,115200"  # rpi5 overlay signature in the kernel cmdline

# ---- cluster bring-up (03d_talos_cluster_config.sh) -------------------------
CLUSTER_NAME="home-pi"                # talosctl gen config cluster name
CLUSTER_VIP="192.168.100.1"          # control-plane VIP (unused IP, outside your DHCP pool)
INSTALL_DISK="/dev/${EXPECT_DISK}"   # nvme0n1 -> /dev/nvme0n1
EPHEMERAL_SIZE="64GiB"               # EPHEMERAL cap; rest of the NVMe -> longhorn user volume
IFACE="${EXPECT_NIC}"                # wired NIC the VIP binds to (dhcp + vip)
