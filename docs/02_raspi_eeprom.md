# Pi 5 EEPROM / boot prep

Firmware setup for each Pi 5 node before installing the OS. Goal: every board boots the same way, no matter which EEPROM
version it shipped with.

## What we're doing

- Build one reusable SD card that reflashes each Pi's bootloader EEPROM with the latest firmware and a known config.
- That config sets boot order (SD first, NVMe fallback) and forces a PCIe probe.
- The script always picks the latest stable bootloader binary from the official repo, so flashing the card also
  updates every board to the same known firmware version, regardless of what it shipped with.
- Once the EEPROM is flashed, the card's job is done.

### Why a custom card instead of the Pi Imager preset

- Imager's "NVMe/USB Boot" preset writes a fixed config: no way to add `PCIE_PROBE` or choose the boot order.

## The settings

`BOOT_ORDER=0xf461` -> SD -> NVMe -> USB -> loop

- Tries SD first; if there's no bootable card, falls through to NVMe.
- SD-first on purpose: we can always drop in a card to recover or override a node.

`PCIE_PROBE=1` -> force the bootloader to probe PCIe

- The RS-P11 isn't a HAT+ board (no ID EEPROM), so the firmware won't auto-probe PCIe and might not see the NVMe as a
  boot device.
- Forcing the probe fixes that. Harmless when not needed; worst case is a tiny boot delay if no drive is present.

## How to build the card

Script: `build-rpi5-eeprom-card.sh` (runs on macOS). What it does:

1. Clones the official `rpi-eeprom` repo.
2. Picks the newest stable Pi 5 (2712) bootloader image.
3. Dumps its config, sets `BOOT_ORDER` + `PCIE_PROBE`.
4. Re-embeds the config, makes the `.sig` (sha256 of the image).
5. Formats the SD as FAT32 and copies `recovery.bin` + `pieeprom.bin` + `pieeprom.sig`.

## Per board

- Insert card, power on. NVMe doesn't need to be installed yet, this only touches the EEPROM.
- Fast green LED blink (green screen on HDMI) = success. Red + blink code = failure.
- Power off, pull the card, next board.

## Then

- Flash the OS image to each NVMe via the USB adapter, slot it in, boot.
