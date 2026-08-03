#!/usr/bin/env bash
# Downloads the pinned Pi 5 Talos image release and writes it to an NVMe SSD over a USB adapter. Once per
# drive. With no SD card inserted the Pi then boots Talos from this NVMe straight into maintenance mode;
# cluster config is applied later by 03c.
# The image is built by github.com/yama6a/talos-raspberry-pi5; TALOS_IMAGE_RELEASE in versions.env pins which
# release. To flash a different one, bump that pin.
#
# Requires: curl + xz
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
IMAGE_ASSET="metal-arm64-rpi5.raw.xz"   # the release's raw-image asset (checksummed by sha256sums.txt)

require curl xz
RELEASE_URL="https://github.com/${TALOS_IMAGE_REPO#ghcr.io/}/releases/download/${TALOS_IMAGE_RELEASE}"
DIR="${IMAGE_CACHE}/${TALOS_IMAGE_RELEASE}"
RAW_XZ="${DIR}/${IMAGE_ASSET}"
mkdir -p "$DIR"

# Cached per release tag, so re-flashing the next drive re-downloads nothing.
if [ ! -f "$RAW_XZ" ]; then
  say "downloading ${TALOS_IMAGE_RELEASE} (~100 MB)"
  curl -fL --retry 3 --progress-bar -o "${RAW_XZ}.part" "${RELEASE_URL}/${IMAGE_ASSET}" \
    || die "download failed: ${RELEASE_URL}/${IMAGE_ASSET} (does that release exist?)"
  mv "${RAW_XZ}.part" "$RAW_XZ"
fi
curl -fsSL --retry 3 -o "${DIR}/sha256sums.txt" "${RELEASE_URL}/sha256sums.txt" \
  || die "cannot fetch ${RELEASE_URL}/sha256sums.txt"

say "verifying checksum"
WANT="$(awk -v a="$IMAGE_ASSET" '$2 ~ a {print $1; exit}' "${DIR}/sha256sums.txt")"
[ -n "$WANT" ] || die "sha256sums.txt names no ${IMAGE_ASSET}"
GOT="$(shasum -a 256 "$RAW_XZ" | awk '{print $1}')"
[ "$WANT" = "$GOT" ] || die "checksum mismatch for ${RAW_XZ}: got ${GOT}, expected ${WANT}. Delete it and re-run."
echo "   sha256 ok (${GOT})"

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
read -r -p ">> ERASE ${DISK} and write Talos ${TALOS_IMAGE_RELEASE}? type YES: " confirm
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
