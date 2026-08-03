# Pi 5 EEPROM / boot prep

Firmware setup for each Pi 5 before the OS goes on. Every board ends up booting the same way, whatever EEPROM
version it shipped with.

- One reusable SD card reflashes each Pi's bootloader EEPROM with the latest stable firmware and a known config.
- The config sets the boot order (SD first, NVMe fallback) and forces a PCIe probe.
- The script always picks the latest stable bootloader binary from the official repo, so flashing also levels
  every board onto the same firmware version.
- Once every EEPROM is flashed, the card's job is done.

The Pi Imager's "NVMe/USB Boot" preset writes a fixed config with no way to add `PCIE_PROBE` or pick the boot
order, hence the custom card.

## The settings

`BOOT_ORDER=0xf461` means SD, then NVMe, then USB, then loop.

- Tries SD first; with no bootable card it falls through to NVMe.
- SD-first on purpose: you can always drop in a card to recover or override a node.

`PCIE_PROBE=1` forces the bootloader to probe PCIe.

- The RS-P11 is not a HAT+ board and has no ID EEPROM, so the firmware will not auto-probe PCIe and may not see
  the NVMe as a boot device at all.
- Forcing the probe fixes that. Harmless otherwise; worst case is a small boot delay with no drive present.

## Build the card

`make build-eeprom-card` (`lib/shell/02_raspi_eeprom.sh`, macOS). It:

1. Clones the official `rpi-eeprom` repo.
2. Picks the newest stable Pi 5 (2712) bootloader image.
3. Dumps its config, sets `BOOT_ORDER` + `PCIE_PROBE`.
4. Re-embeds the config and writes `pieeprom.sig` (the image's sha256).
5. Formats the SD as FAT32 and copies `recovery.bin`, `pieeprom.bin` and `pieeprom.sig`.

## Per board

1. Insert the card, power on. The NVMe does not need to be installed yet, this only touches the EEPROM.
2. Fast green LED blink, green screen on HDMI: success. Red plus a blink code: failure.
3. Power off, pull the card, next board.

Then flash the OS image to each NVMe over the USB adapter (03a), slot it in, and boot.
