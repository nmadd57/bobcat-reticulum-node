# Flashing a G290/G295 over USB

How to write a whole OS image to the board's eMMC from a host computer over the OTG USB port, with no SD card.
Developed and tested on one G295 (RK3566/RK3568, 58 GiB Samsung eMMC, U-Boot from the community Armbian image).

**Status: worked on one unit** (flashed the eMMC image over USB, it booted and installed itself; settings seeding on top of
that has not been run yet). The steps below were run by hand; the build script
(`tools/usb-flash/build-flashmode.sh`) reproduces the pieces but the whole procedure is not yet automated or run on
other units.

## Which image to write

Use **`bobcat-g295-emmc.img.xz`** (a release asset from v0.2.5): the Armbian OS the eMMC flasher installs, with this
project's installer and first-boot service already in it. It uses the generic Armbian boot script, which picks the
boot device and the root filesystem by itself, so it boots from the eMMC.

Do **not** write the standalone SD image (`bobcat-g295-reticulum.img.xz`) to the eMMC. Its boot script is hard-wired
to the SD card: it loads the kernel with `load mmc 1:1` (the SD slot) and sets `root=/dev/mmcblk0p2`, but on this board
the eMMC is `mmcblk1`. Written to the eMMC it was verified byte for byte and still never booted (solid blue LED; the
root filesystem was untouched, with no first boot). The same method with the eMMC image booted and ran the installer.

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


## Fastboot: the browser-friendly way (tested)

U-Boot's `ums` makes the board a mass-storage disk, which browsers cannot open (WebUSB blocks that class). The same
U-Boot also has `fastboot usb 0`, which WebUSB can use. Verified on one unit:

- A boot script running `fastboot usb 0` (`tools/usb-flash/build-flashmode.sh --mode fastboot`) written through download
  mode makes the board appear as `18d1:4d00`, interface class `ff/42/03` (standard fastboot).
- `getvar all`: `max-download-size` 0x04000000 (64 MiB), partitions listed by GPT name with type and size,
  `unlocked: no`, `secure: yes`. **Flashing is not blocked by the lock state**: `fastboot flash` returned OKAY while it
  reported `unlocked: no`; `flashing unlock` is not implemented.
- **Writes work past 32 MiB and in pieces larger than the buffer.** 200 MiB of random data flashed to a partition at sector
  1,000,000 (the tool sent four sparse pieces, ~10.7 s) read back byte for byte over the mass-storage disk.
- `fastboot flash gpt` returns OKAY but did not change the partitions the board lists in the same session; the table is
  set through download mode (rockusb) instead, which works.

### Flow for a whole image

1. Download mode (Recovery + Reset). Write, through rockusb, the image's partition table (root partition extended to the
   end of the disk, so the image's size fits) at sector 0 and an 8 MiB FAT12 `fat.img` holding `boot.scr` (runs
   `fastboot usb 0`) at sector 32768, where the image's `bootfs` starts. Reset the device.
2. Fastboot: `flash rootfs`, then `flash bootfs` **last** (it overwrites the temporary boot partition with the real one,
   including any settings file), then `reboot`. No partition table change is needed afterwards.

Not yet done: this whole sequence on a real image, and the browser version (WebUSB) of either step.

## The browser flasher (the USB flasher section of `site/index.html`)

The page does the two phases above from Chrome or Edge over WebUSB: download mode writes the image's partition
table (with `rootfs` extended to the end of the disk) and a temporary 8 MiB boot partition holding a
`fastboot usb 0` script, then resets; fastboot then flashes `rootfs`, and `bootfs` last (with
`bobcat-install.conf` added to it), and reboots. The image (`bobcat-g295-emmc.img.xz` or the unpacked `.img`) is
chosen from disk because GitHub release downloads send no CORS headers. The `.xz` is decompressed in the browser.

Tested: every module against emulated boards and real filesystem tools (`test/test-flash-*.mjs`), the sparse
encoder against `simg2img`, and the fastboot write path by hand on a real unit. **Not yet tested:** the page
itself on a real unit. Linux needs a udev rule for the USB ids; Windows needs the WinUSB driver.

## Seeding the settings file

For the standalone image, put `bobcat-install.conf` on its FAT boot partition before writing (inside the image file,
for example `mcopy -i image.img@@$((32768*512)) bobcat-install.conf ::bobcat-install.conf`). The first boot reads it.

## Limits and open points

- Tested on one unit with this U-Boot. A different bootloader may lack `ums`, or number its MMC devices differently
  (`ums 0 mmc 0` is the eMMC here).
- Needs the host to see a plain USB disk; nothing here works from a browser (WebUSB cannot open mass storage).
- The script replaces the eMMC's partition table and its first 8 MiB of the old first partition.
- A browser-only flasher is therefore not possible with this approach; a host script is.
