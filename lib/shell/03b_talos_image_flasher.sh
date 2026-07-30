#!/usr/bin/env bash
# Writes the local custom Pi 5 Talos image built by 03a to an NVMe SSD over a USB adapter. Once per drive.
# With no SD card inserted the Pi then boots Talos from this NVMe straight into maintenance mode; cluster
# config is applied later by 03d.
#
# Requires: xz
set -euo pipefail

# OUT_DIR (the build-cache output dir from 03a_talos_image_builder.sh) is derived in lib/shell/common.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# The staged image from 03a (OUT_DIR comes from the shared build-cache key in lib/shell/common.sh).
# Filename matches 03a's IMAGE_NAME. To flash a different build, point OUT_DIR's inputs at it in .env.
RAW_XZ="${OUT_DIR}/metal-arm64-rpi5.raw.xz"

require xz
[ -f "$RAW_XZ" ] || die "image not found: $RAW_XZ, build it first: ./03a_talos_image_builder.sh"

# Decompress next to the .xz (only when missing or stale).
RAW="${RAW_XZ%.xz}"
if [ ! -f "$RAW" ] || [ "$RAW_XZ" -nt "$RAW" ]; then
  say "decompressing -> $RAW"
  xz -dkf "$RAW_XZ"
fi
ls -lh "$RAW"

# DESTRUCTIVE FROM HERE: writing the NVMe

# 1. Show disks so you can identify the USB-NVMe adapter
diskutil list

# 2. Pick the NVMe's WHOLE-DISK id (e.g. /dev/disk6, NOT /dev/disk6s1)
read -r -p ">> enter NVMe disk id (e.g. /dev/disk6): " DISK
diskutil info "${DISK}" >/dev/null 2>&1 || die "'${DISK}' is not a disk"

# 3. Confirm, this erases the entire drive
diskutil info "${DISK}" | grep -E 'Device / Media Name|Disk Size|Protocol|Removable' || true
read -r -p ">> ERASE ${DISK} and write Talos? type YES: " confirm
[ "${confirm}" = "YES" ] || { echo "aborted."; exit 1; }

# 4. Unmount, then write to the raw device (/dev/rdiskN is much faster on macOS)
RDISK="/dev/r${DISK##*/}"
diskutil unmountDisk "${DISK}"
say "writing to ${RDISK} ... (press Ctrl-T for progress)"
sudo dd if="${RAW}" of="${RDISK}" bs=4M
sync

# 5. Eject so the drive is safe to pull
diskutil eject "${DISK}"
say "Done. ${DISK} ejected."
echo "   Next: slot the SSD into a Pi, power on with NO SD card -> Talos boots into maintenance mode."
echo "   then repeat this script for each remaining drive."
