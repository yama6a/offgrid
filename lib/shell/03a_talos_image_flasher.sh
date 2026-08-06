#!/usr/bin/env bash
# Downloads a node's Talos image and writes it to an NVMe SSD over a USB adapter. Once per drive. The node then
# boots Talos from this NVMe straight into maintenance mode (a Pi needs NO SD card inserted); cluster config is
# applied later by 03c.
#
# Where the image comes from is the node's `imageSource` in inventory.yaml:
#   github-release   the TALOS_IMAGE_REPO release that TALOS_IMAGE_RELEASE pins, verified against sha256sums.txt
#   image-factory    factory.talos.dev, built from that node's imageSchematic at TALOS_VERSION, no checksum
#
# Usage:
#   bash 03a_talos_image_flasher.sh [hostname]     # no hostname: pick from the inventory interactively
#   make flash-talos-nvme [NODE=<hostname>]
# The drive is not bound to that hostname, only the IMAGE is, so one run covers every drive of the same type.
#
# Requires: curl + xz
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require curl xz

# Which node's IMAGE to write. Deliberately asks rather than defaulting to a node: the wrong pick writes another
# architecture's image, which boots to nothing, and that is not a thing to do silently.
NODE="${1:-}"
if [ -z "$NODE" ]; then
  echo
  echo "Which node's image? The drive is not tied to the node, so any node of the same type will do."
  for i in "${!ALL_HOSTS[@]}"; do
    h="${ALL_HOSTS[$i]}"
    printf '  %2d) %-14s %-16s %-12s %s\n' \
      "$((i+1))" "$h" "${NODE_TYPE[$h]}" "${NODE_ROLE[$h]}" "${NODE_IMAGE_FILE[$h]}"
  done
  echo
  while :; do
    read -r -p ">> number [1-${#ALL_HOSTS[@]}]: " pick \
      || die "no input to read (not a terminal?); name the node instead: make flash-talos-nvme NODE=<hostname>"
    case "$pick" in
      ''|*[!0-9]*) echo "   '${pick}' is not a number." ;;
      *) if [ "$pick" -ge 1 ] && [ "$pick" -le "${#ALL_HOSTS[@]}" ]; then
           NODE="${ALL_HOSTS[$((pick-1))]}"; break
         else
           echo "   ${pick} is out of range."
         fi ;;
    esac
  done
fi
[ -n "${NODE_ROLE[$NODE]:-}" ] || die "unknown node '${NODE}': inventory.yaml has ${ALL_HOSTS[*]}"
IMAGE_SOURCE="${NODE_IMAGE_SOURCE[$NODE]}"
IMAGE_FILE="${NODE_IMAGE_FILE[$NODE]}"

# Cache dir keyed by whatever identifies the build (the release tag, or the schematic id), so a version bump
# lands in a fresh dir and re-flashing a second drive of the same type re-downloads nothing.
case "$IMAGE_SOURCE" in
  github-release)
    # The raw image is a release ASSET on github.com, while the installer 03e uses is a CONTAINER on ghcr.io.
    # Same repo, two hosts, hence stripping the registry prefix off TALOS_IMAGE_REPO to build the web URL.
    SRC="https://github.com/${TALOS_IMAGE_REPO#ghcr.io/}/releases/download/${TALOS_IMAGE_RELEASE}/${IMAGE_FILE}"
    DIR="${IMAGE_CACHE}/${TALOS_IMAGE_RELEASE}"
    ;;
  image-factory)
    SCHEMATIC_ID="$(factory_schematic_id "${NODE_IMAGE_SCHEMATIC[$NODE]}")"
    SRC="https://${FACTORY_HOST}/image/${SCHEMATIC_ID}/${TALOS_VERSION}/${IMAGE_FILE}"
    DIR="${IMAGE_CACHE}/factory-${TALOS_VERSION}-${SCHEMATIC_ID:0:12}"
    ;;
esac
RAW_XZ="${DIR}/${IMAGE_FILE}"
mkdir -p "$DIR"

say "${NODE}: ${NODE_TYPE[$NODE]}, imageSource ${IMAGE_SOURCE}"
echo "   ${SRC}"

if [ ! -f "$RAW_XZ" ]; then
  say "downloading ${IMAGE_FILE} (~100 MB)"
  curl -fL --retry 3 --progress-bar -o "${RAW_XZ}.part" "$SRC" \
    || die "download failed: ${SRC} (does that release/schematic exist?)"
  mv "${RAW_XZ}.part" "$RAW_XZ"
fi

# Only the release publishes a checksum file; the factory does not, so that path is a plain HTTPS download.
if [ "$IMAGE_SOURCE" = github-release ]; then
  SUMS_URL="https://github.com/${TALOS_IMAGE_REPO#ghcr.io/}/releases/download/${TALOS_IMAGE_RELEASE}/sha256sums.txt"
  curl -fsSL --retry 3 -o "${DIR}/sha256sums.txt" "$SUMS_URL" || die "cannot fetch ${SUMS_URL}"
  say "verifying checksum"
  WANT="$(awk -v a="$IMAGE_FILE" '$2 ~ a {print $1; exit}' "${DIR}/sha256sums.txt")"
  [ -n "$WANT" ] || die "sha256sums.txt names no ${IMAGE_FILE}"
  GOT="$(shasum -a 256 "$RAW_XZ" | awk '{print $1}')"
  [ "$WANT" = "$GOT" ] || die "checksum mismatch for ${RAW_XZ}: got ${GOT}, expected ${WANT}. Delete it and re-run."
  echo "   sha256 ok (${GOT})"
else
  warn "${FACTORY_HOST} publishes no sha256sums.txt, so this image is unverified beyond HTTPS"
fi

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
read -r -p ">> enter NVMe disk id (e.g. /dev/disk6): " DISK \
  || die "no input to read (not a terminal?); this step needs a human to identify the drive"
diskutil info "${DISK}" >/dev/null 2>&1 || die "'${DISK}' is not a disk"

# 3. Confirm, this erases the entire drive
diskutil info "${DISK}" | grep -E 'Device / Media Name|Disk Size|Protocol|Removable' || true
read -r -p ">> ERASE ${DISK} and write the ${NODE_TYPE[$NODE]} Talos image (${IMAGE_FILE})? type YES: " confirm
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
echo "   Next: slot the SSD into its ${NODE_TYPE[$NODE]} and power on (a Pi needs NO SD card) -> maintenance mode."
echo "   Repeat for each remaining ${NODE_TYPE[$NODE]} drive; a different hardware type needs its own NODE=."
