#!/usr/bin/env bash
#
# 03b_talos_image_flasher.sh  (macOS)
#
# Writes the LOCAL custom Raspberry Pi 5 Talos image — built and validated by
# 03a_talos_image_builder.sh — to an NVMe SSD over a USB adapter. Run once per
# drive; swap the SSD each time.
#
# Boot chain: the EEPROM (step 02) tries SD first, then NVMe. With no card
# inserted, the Pi boots Talos from this NVMe straight into maintenance mode.
# Cluster config (IPs, VIP, partitions) is applied later by 03d_talos_cluster_config.sh.
#
# Requires: xz   (brew install xz)
#
set -euo pipefail

# Config (OUT_DIR, RAW_XZ — the compressed raw image from 03a_talos_image_builder.sh)
# lives in 03_config.sh. Override RAW_XZ to flash a specific build.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/03_config.sh"

command -v xz >/dev/null || { echo "ERROR: xz not found (brew install xz)"; exit 1; }
[ -f "$RAW_XZ" ] || {
  echo "ERROR: image not found: $RAW_XZ"
  echo "       build it first:  ./03a_talos_image_builder.sh"
  exit 1
}

# Decompress next to the .xz (only when missing or stale).
RAW="${RAW_XZ%.xz}"
if [ ! -f "$RAW" ] || [ "$RAW_XZ" -nt "$RAW" ]; then
  echo ">> decompressing -> $RAW"
  xz -dkf "$RAW_XZ"
fi
ls -lh "$RAW"

# ===== DESTRUCTIVE FROM HERE: writing the NVMe ===============================

# 1. Show disks so you can identify the USB-NVMe adapter
diskutil list

# 2. Pick the NVMe's WHOLE-DISK id (e.g. /dev/disk6 — NOT /dev/disk6s1)
read -r -p ">> enter NVMe disk id (e.g. /dev/disk6): " DISK
diskutil info "${DISK}" >/dev/null 2>&1 || { echo "ERROR: '${DISK}' is not a disk"; exit 1; }

# 3. Confirm — this erases the entire drive
diskutil info "${DISK}" | grep -E 'Device / Media Name|Disk Size|Protocol|Removable' || true
read -r -p ">> ERASE ${DISK} and write Talos? type YES: " ok
[ "${ok}" = "YES" ] || { echo "aborted."; exit 1; }

# 4. Unmount, then write to the raw device (/dev/rdiskN is much faster on macOS)
RDISK="/dev/r${DISK##*/}"
diskutil unmountDisk "${DISK}"
echo ">> writing to ${RDISK} ... (press Ctrl-T for progress)"
sudo dd if="${RAW}" of="${RDISK}" bs=4M
sync

# 5. Eject so the drive is safe to pull
diskutil eject "${DISK}"
echo ">> Done. ${DISK} ejected."
echo ">> Next: slot the SSD into a Pi, power on with NO SD card -> Talos boots into maintenance mode."
echo ">>   then repeat this script for each remaining drive."
