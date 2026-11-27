# Recovering a G295 that boots nothing

How to get the unit into recovery mode (with photos): [`recovery-mode.md`](recovery-mode.md).

The Recovery button (next section) gives a quick, reliable way to **read and rewrite the first 32 MiB** of the eMMC:
the partition table and the bootloader. It **cannot flash a whole OS image**: on the unit tested, reads and writes
beyond sector 65,535 do not work. The Maskrom method further down is the fallback when the bootloader itself is
damaged and the button cannot work.

## Recovery button: U-Boot download mode (preferred)

The board has **Reset** and **Recovery** buttons next to its USB debug port. Holding Recovery while resetting
makes the board's own U-Boot enter download mode and present the eMMC to a host over the micro-USB port labelled **COM**.

Verified on one unit:
- U-Boot has the `rockusb` command, ADC-key support and messages "download key pressed" / "enter rockusb/bootrom
  download mode" (strings in the Armbian image's U-Boot).
- With the **COM** port connected to a host: hold **Recovery**, press and release **Reset**, release Recovery after
  about two seconds.
- The host then sees `2207:350a`, `bcdDevice 0223`, product **"USB download gadget"** (Maskrom has no product
  string and `bcdDevice 0100`).
- `rkdeveloptool ld` reports **Loader**. `rci` (chip info), `rid`, `rfi` (Samsung eMMC, 59,640 MB) and `ppt`
  (the eMMC's GPT) all worked. These are read-only.

**Limit found (tested):** the first 32 MiB (sectors 0-65,535) can be read and written; beyond that it cannot.
- `rkdeveloptool wl 0 <image>` of a 2.8 GB image reported no error, but read back as correct only for the first
  32 MiB. From sector 65,536 on, reads return a repeated `0xCC` filler.
- A write-then-read test of 4 KiB at sectors 60,000 (OK), 65,536, 70,000, 1,000,000 and 5,000,000 (all read `0xCC`)
  confirms it for single small writes too, so it is not a size or timing problem.
- Not determined: whether the cause is this U-Boot's rockusb support or the host tool (Debian's `rkdeveloptool`).
  `rl` and `wl` take their length in **bytes**, not sectors, despite the help text.
- Consequence: a full-image write leaves the unit with a new partition table and the start of the new boot
  partition on top of old data, and it will not boot. Flash a whole image from Linux instead (`dd` from a booted
  system, for example one started from an SD card, or through the Maskrom method below).

The "USB debug" port next to the buttons is not a serial bridge on this unit: connected to a host it presented
nothing. The board's real debug UART is `ttyS2` at 1,500,000 baud (kernel `console=ttyS2,1500000`).

## Maskrom (fallback)

What follows was done on one Bobcat Miner 300 G295 (RK3566/RK3568-class board, 58 GiB Samsung eMMC).
It is a record of what worked and what did not, not a supported procedure. Anything marked
*unverified* was inferred, not measured.

## How the unit got into Maskrom

After a successful flash, the eMMC held this project's Armbian image, with its own bootloader. With
the flasher card in the slot, the unit booted the eMMC and ignored the card (see
[`image/README.md`](../image/README.md#re-flashing-a-unit-that-already-runs-this-system-known-problem)).
Zeroing the eMMC's bootloader sectors (64-16383) to force the card to boot left the board with no LED,
no network, and a USB device `2207:350a` that `rkdeveloptool ld` reports as **Maskrom**. Two different,
freshly written flasher cards were not booted by the ROM either.

## What did not work

Public Rockchip loaders (`rkbin`) built with `boot_merger` and sent with `rkdeveloptool db`:
RAM init v1.26 and v1.21 (RK3566 1056 MHz), v1.26 (RK3568 1056 MHz), v1.16 (the version in the
card's own bootloader); usbplug v1.17 and v1.14. Every one downloaded successfully and the board
then fell back to Maskrom. The RAM-init was not the cause: the 59,392-byte
`rk3566_ddr_1056MHz_v1.21.bin` appears byte for byte inside the Armbian image's bootloader.
A second `db` on a board that had not been power-cycled stalled; always power-cycle first.

## What worked

Use the RAM-init **and the SPL from the Armbian image's own idbloader** as the two loader stages, with
the flasher SD card inserted:

1. The Armbian image's idbloader (sectors 64 up to the `u-boot` FIT at sector 16384) has the layout
   `RKNS` header (0x800 bytes) | RAM-init blob (0x800-0xF000, 59,392 bytes) | U-Boot SPL (0xF000 to the
   end, about 257 KB). Extract the SPL as `idbloader[0xF000:0x4DE00]`.
2. Build a loader with `boot_merger` from `rkbin`'s `RK3566MINIALL.ini`, replacing the RAM-init file with
   `rk3566_ddr_1056MHz_v1.21.bin` (from an older `rkbin` commit) and both the usbplug and SPL entries
   with the extracted SPL.
3. Power-cycle the board with the USB cable connected and the SD card **in**, then send it:
   `rkdeveloptool db rk356x_loader_armspl.bin`.
4. The board leaves Maskrom (the USB device disappears) and boots. U-Boot found the system on the eMMC
   and booted it, so the unit came back on the network.

*Unverified:* why this works when the usbplug loaders do not. The most likely explanation is that the SPL
starts U-Boot from storage instead of waiting for the host, but no console output was seen.

## Restoring the eMMC bootloader

Once the system is running, put the idbloader back from the Armbian image that is on the flasher
card (the card's root filesystem holds it). Only the bootloader area is rewritten; U-Boot at sector
16384 and the partitions from sector 32768 are untouched:

```
mount -o ro /dev/mmcblk0p6 /mnt/sd          # the card's rootfs; check lsblk first
IMG=/mnt/sd/Armbian-unofficial_*.img
dd if="$IMG" of=/dev/mmcblk1 bs=512 skip=64 seek=64 count=16320 conv=fsync
cmp <(dd if="$IMG" bs=512 skip=64 count=16320 2>/dev/null) <(dd if=/dev/mmcblk1 bs=512 skip=64 count=16320 2>/dev/null)
```

Compare the source region's SHA-256 with a known-good copy first, and confirm `mmcblk1` is the eMMC
(the disk with `boot0`/`boot1`). After it, the unit booted from the eMMC alone with the card removed.

## Notes on the hardware and tooling

- `rkdeveloptool rci` / `rid` / `rfi` work in Maskrom and are read-only: they reported chip info
  `38 36 35 33` (reads as 3568), flash ID `EMMC`, Samsung, 59,640 MB.
- `rkdeveloptool` needs write access to the USB node. The device number changes on every reset;
  a udev rule such as `SUBSYSTEM=="usb", ATTR{idVendor}=="2207", MODE="0666"` avoids a per-node ACL.
  Never set an ACL recursively on a `/dev/bus/usb/<bus>` directory (it removes search permission).
- The U-Boot in these images has `boot_targets=mmc1 mmc0 ...`. On this board Linux names the eMMC
  `mmcblk1`, so the eMMC is probably tried first (*unverified*, inferred from the numbering).
- Bobber publishes stock firmware (`295_US915_*.zip`) and a Windows upgrade tool; the `.img` inside the
  package is a password-protected zip, and no attempt was made to open it.

## What is still not solved

Re-flashing a unit that already runs this system from the flasher card. The recovery above gets a unit
running again; it does not make the card win the boot order.
