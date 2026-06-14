#!/usr/bin/env bash
#
# build-rpi5-eeprom-card.sh  (macOS)
#
# Builds a REUSABLE Raspberry Pi 5 EEPROM-flashing SD card.
# Bakes two settings into the latest stable Pi 5 (BCM2712) bootloader:
#     BOOT_ORDER=0xf461     -> SD first, then NVMe, then USB, then loop
#     PCIE_PROBE=1          -> force PCIe probe so 3rd-party NVMe boards are seen
# Because the image is written as pieeprom.bin (not .upd), recovery.bin
# flashes and then stops without disabling the card -> one card, every node.
#
# Requires: git + python3  (Xcode Command Line Tools, or: brew install python git)
#
set -euo pipefail

# ---- knobs you might change -------------------------------------------------
WORKDIR="$(mktemp -d)/rpi-eeprom-build"   # build scratch dir
BOOT_ORDER="0xf461"                  # SD -> NVMe -> USB -> retry
SD_LABEL="RPIBOOT"                   # FAT32 volume name (<=11 chars, UPPERCASE)
# -----------------------------------------------------------------------------

# 1. Fresh workdir + shallow clone of the official firmware repo
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"
rm -rf rpi-eeprom
echo ">> cloning rpi-eeprom repo to ${WORKDIR}"
git clone --depth 1 https://github.com/raspberrypi/rpi-eeprom.git
cd rpi-eeprom

# 2. Find the newest *stable* Pi 5 (2712) bootloader image + its recovery.bin
#    (skip beta/old so we land on a release build)
PIEEPROM_SRC="$(find . -path '*2712*' -name 'pieeprom-*.bin' ! -path '*beta*' ! -path '*old*' | sort | tail -n1)"
[ -n "${PIEEPROM_SRC}" ] || { echo "ERROR: no 2712 pieeprom image found"; exit 1; }
RECOVERY_SRC="$(dirname "${PIEEPROM_SRC}")/recovery.bin"
echo ">> using bootloader: ${PIEEPROM_SRC}"

# 3. Dump that image's default EEPROM config to a text file
python3 ./rpi-eeprom-config "${PIEEPROM_SRC}" > boot.conf

# 4. Force our settings: strip any existing copies, then append the ones we want
#    (everything else in the default config is preserved)
grep -v -E '^(BOOT_ORDER|PCIE_PROBE)=' boot.conf > boot.conf.new || true
cat >> boot.conf.new <<EOF
BOOT_ORDER=${BOOT_ORDER}
PCIE_PROBE=1
EOF
mv boot.conf.new boot.conf
echo "----- final EEPROM config -----"; cat boot.conf; echo "-------------------------------"

# 5. Embed the edited config into a new bootloader image
python3 ./rpi-eeprom-config --config boot.conf --out pieeprom.bin "${PIEEPROM_SRC}"

# 6. Create pieeprom.sig (first line = hex sha256 of the image) using macOS shasum
shasum -a 256 pieeprom.bin | cut -d' ' -f1 > pieeprom.sig

# 7. Stage the three files the boot ROM looks for
mkdir -p ../card
cp "${RECOVERY_SRC}" pieeprom.bin pieeprom.sig ../card/
echo ">> card payload ready:"; ls -l ../card

# ===== DESTRUCTIVE FROM HERE: writing the SD card ============================

# 8. Show disks so you can identify the SD card
diskutil list

# 9. Pick the SD card's WHOLE-DISK id (e.g. /dev/disk4 — NOT /dev/disk4s1)
read -r -p ">> enter SD card disk id (e.g. /dev/disk4): " SD_DISK
diskutil info "${SD_DISK}" >/dev/null 2>&1 || { echo "ERROR: '${SD_DISK}' is not a disk"; exit 1; }

# 10. Confirm — this erases the entire card
diskutil info "${SD_DISK}" | grep -E 'Device / Media Name|Disk Size|Removable|Protocol' || true
read -r -p ">> ERASE ${SD_DISK} and write the EEPROM card? type YES: " ok
[ "${ok}" = "YES" ] || { echo "aborted."; exit 1; }

# 11. Format FAT32 (MBR scheme) and copy the payload to the card
diskutil eraseDisk FAT32 "${SD_LABEL}" MBRFormat "${SD_DISK}"
cp ../card/recovery.bin ../card/pieeprom.bin ../card/pieeprom.sig "/Volumes/${SD_LABEL}/"

# 12. Flush + eject so the card is safe to pull
sync
diskutil eject "${SD_DISK}"
echo ">> Done. Card ejected."
echo ">> Next (physical): boot each Pi 5 from this card."
echo ">>   success = rapid green LED blink (green screen on HDMI); failure = red + blink code."
echo ">>   then power off, remove the card, move to the next board."
