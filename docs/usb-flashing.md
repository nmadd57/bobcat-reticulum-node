# Flashing a G290/G295 over USB

How to write a whole OS image to the board's eMMC from a host computer over the OTG USB port, with no SD card.
Developed and tested on one G295 (RK3566/RK3568, 58 GiB Samsung eMMC, U-Boot from the community Armbian image).

**Status: worked once, end to end, on one unit.** The steps below were run by hand; the build script
(`tools/usb-flash/build-flashmode.sh`) reproduces the pieces but the whole procedure is not yet automated or run on
other units.

## Why the obvious way does not work

The board's download mode (hold **Recovery**, press **Reset**; the host sees `2207:350a` "USB download gadget" and
`rkdeveloptool ld` says *Loader*) reads and writes only the **first 32 MiB** of the eMMC (sectors 0-65,535). Past
that it answers every command with success and returns a repeated `0xCC`. Tested with `rkdeveloptool` **and** with a
separate minimal rockusb client (`tools/usb-flash/rockusb_probe.py`), at every read/write sub-code, and after
`CHANGE_STORAGE`: identical, so the limit is in the board's U-Boot, not the host tool. A full-image write in this mode
looks successful and leaves a unit that cannot boot (the read-back is the only way to see it).

## What does work: U-Boot USB mass storage

The same U-Boot has a `ums` command (`ums 0 mmc 0`) that exports the whole eMMC as a USB disk, with no limit. Download
mode can write the small area where U-Boot looks for a boot script. So:

1. **Build** the pieces: `tools/usb-flash/build-flashmode.sh` makes `boot.scr` (a compiled script that runs
   `ums 0 mmc 0`), an 8 MiB FAT12 `fat.img` holding it, and a `gpt.bin` whose only partition is that FAT at sector
   32768. Both fit inside the first 32 MiB.
2. **Enter download mode** (Recovery + Reset, OTG port connected, **no SD card in the unit**: U-Boot checks the SD slot
   first and would boot it).
3. **Write** `gpt.bin` at sector 0 and `fat.img` at sector 32768 (`rkdeveloptool wl 0 gpt.bin`,
   `rkdeveloptool wl 32768 fat.img`) and read them back to check. Note `rkdeveloptool rl` takes its length in
   **bytes**, not sectors.
4. **Reset** (`rkdeveloptool rd`, or the Reset button). U-Boot runs `boot.scr` and the board shows up as
   `2207:0010` "USB download gadget" and a new disk, model **"UMS disk 0"**, 122,142,720 sectors on the unit tested.
5. **Write the image** to that disk with `dd` (`bs=4M conv=fsync`) and verify with `cmp -n <image size> <image> <disk>`.
   Check the model and sector count first: the host disk node (often `/dev/sda`) is the Bobcat's eMMC now.
6. **Reset** the board without Recovery held. It boots the new system.

Measured: 2.84 GB written in 144 s (19.8 MB/s); the byte-for-byte verification of the whole image matched.

## Seeding the settings file

For the standalone image, put `bobcat-install.conf` on its FAT boot partition before writing (inside the image file,
for example `mcopy -i image.img@@$((32768*512)) bobcat-install.conf ::bobcat-install.conf`). The first boot reads it.

## Limits and open points

- Tested on one unit with this U-Boot. A different bootloader may lack `ums`, or number its MMC devices differently
  (`ums 0 mmc 0` is the eMMC here).
- Needs the host to see a plain USB disk; nothing here works from a browser (WebUSB cannot open mass storage).
- The script replaces the eMMC's partition table and its first 8 MiB of the old first partition.
- A browser-only flasher is therefore not possible with this approach; a host script is.
