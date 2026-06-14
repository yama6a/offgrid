#!/usr/bin/env bash
#
# 03_talos.sh  (macOS)
#
# Downloads a pinned Talos Linux image for Raspberry Pi 5 (community
# `talos-rpi5` build, which carries the custom RP1 kernel) and writes it to an
# NVMe SSD over a USB adapter. Run once per drive — swap the SSD each time.
#
# Boot chain: the EEPROM (step 02) tries SD first, then NVMe. With no card
# inserted, the Pi boots Talos from this NVMe straight into maintenance mode.
#
# Requires: curl + zstd   (brew install zstd)
#
set -euo pipefail

# ---- knobs ------------------------------------------------------------------
# Releases:  https://github.com/talos-rpi5/talos-builder/releases  (tag = Talos version)
# Latest:    curl -s https://api.github.com/repos/talos-rpi5/talos-builder/releases/latest | grep tag_name
# NOTE:      The asset filename has CHANGED across releases — confirm it on the release
#            page. metal-arm64.raw.zst vs. metal-arm64-rpi.raw.zst
RELEASE_TAG="v1.11.5"
IMAGE_ASSET="metal-arm64.raw.zst"
WORKDIR="${HOME}/.cache/talos-rpi5"     # image cached here; downloaded once
# -----------------------------------------------------------------------------

command -v zstd >/dev/null || { echo "ERROR: zstd not found (brew install zstd)"; exit 1; }

IMG_URL="https://github.com/talos-rpi5/talos-builder/releases/download/${RELEASE_TAG}/${IMAGE_ASSET}"
RAW="${IMAGE_ASSET%.zst}"               # decompressed filename

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# 1. Download + decompress once (cached for the remaining drives)
if [ ! -f "${RAW}" ]; then
  echo ">> downloading ${IMG_URL}"
  curl -fL --retry 3 -o "${IMAGE_ASSET}" "${IMG_URL}"
  echo ">> decompressing -> ${RAW}"
  zstd -d -f "${IMAGE_ASSET}" -o "${RAW}"
else
  echo ">> using cached image: ${WORKDIR}/${RAW}"
fi
ls -lh "${RAW}"

# ===== DESTRUCTIVE FROM HERE: writing the NVMe ===============================

# 2. Show disks so you can identify the USB-NVMe adapter
diskutil list

# 3. Pick the NVMe's WHOLE-DISK id (e.g. /dev/disk6 — NOT /dev/disk6s1)
read -r -p ">> enter NVMe disk id (e.g. /dev/disk6): " DISK
diskutil info "${DISK}" >/dev/null 2>&1 || { echo "ERROR: '${DISK}' is not a disk"; exit 1; }

# 4. Confirm — this erases the entire drive
diskutil info "${DISK}" | grep -E 'Device / Media Name|Disk Size|Protocol|Removable' || true
read -r -p ">> ERASE ${DISK} and write Talos? type YES: " ok
[ "${ok}" = "YES" ] || { echo "aborted."; exit 1; }

# 5. Unmount, then write to the raw device (/dev/rdiskN is much faster on macOS)
RDISK="/dev/r${DISK##*/}"
diskutil unmountDisk "${DISK}"
echo ">> writing to ${RDISK} ... (press Ctrl-T for progress)"
sudo dd if="${RAW}" of="${RDISK}" bs=4M
sync

# 6. Eject so the drive is safe to pull
diskutil eject "${DISK}"
echo ">> Done. ${DISK} ejected."
echo ">> Next: slot the SSD into a Pi, power on with NO SD card -> Talos boots into maintenance mode."
echo ">>   then repeat this script for each remaining drive."
