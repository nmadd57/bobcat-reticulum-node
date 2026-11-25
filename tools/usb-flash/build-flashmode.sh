#!/usr/bin/env bash
#
# Build the pieces that turn a Bobcat G290/G295 into a USB disk (U-Boot "ums") so a whole OS image can be
# written to its eMMC from a host with plain dd.
#
# Why: the board's download mode (Recovery + Reset, "rockusb") can only read and write the first 32 MiB of the
# eMMC; past sector 65,535 it answers success but returns 0xCC filler. U-Boot's own USB mass-storage mode has no
# such limit. Download mode CAN write the small area where U-Boot looks for a boot script, so the script
# `ums 0 mmc 0` is placed there; the next boot exports the whole eMMC over USB.
#
# Output (in --out DIR, default ./flashmode):
#   boot.scr   compiled U-Boot script that runs `ums 0 mmc 0` (--mode ums, the default) or
#              `fastboot usb 0` (--mode fastboot)
#   fat.img    8 MiB FAT12 partition holding boot.scr
#   gpt.bin    34 sectors (protective MBR + GPT) whose partition 1 is fat.img at sector 32768
# Write gpt.bin at sector 0 and fat.img at sector 32768 in download mode (both are inside the first 32 MiB).
# Needs: mkimage (u-boot-tools), mkfs.fat (dosfstools), mcopy (mtools), python3.
set -euo pipefail
OUT=flashmode; DISK_SECTORS=122142720; MODE=ums   # the 58 GiB Samsung eMMC; from READ_FLASH_INFO on the board
while [[ $# -gt 0 ]]; do case "$1" in --out) OUT="$2"; shift 2 ;; --disk-sectors) DISK_SECTORS="$2"; shift 2 ;; --mode) MODE="$2"; shift 2 ;; *) echo "unknown option $1" >&2; exit 2 ;; esac; done
[[ "$MODE" == ums || "$MODE" == fastboot ]] || { echo "--mode must be ums or fastboot" >&2; exit 2; }
for t in mkimage mkfs.fat mcopy python3; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done
mkdir -p "$OUT"; cd "$OUT"; rm -f ums.cmd boot.scr fat.img gpt.bin
if [[ "$MODE" == ums ]]; then
cat > ums.cmd <<'SCRIPT'
echo ==============================================
echo  BOBCAT USB FLASH MODE: exporting the eMMC as a USB disk
echo  (ums 0 mmc 0). Write the image with dd from the host.
echo ==============================================
ums 0 mmc 0
echo ums returned, falling back to the normal boot targets
SCRIPT
else
cat > ums.cmd <<'SCRIPT'
echo ==============================================
echo  BOBCAT USB FLASH MODE: fastboot (fastboot usb 0)
echo ==============================================
fastboot usb 0
echo fastboot returned, falling back to the normal boot targets
SCRIPT
fi
mkimage -A arm64 -O linux -T script -C none -n "bobcat usb flash mode" -d ums.cmd boot.scr >/dev/null
truncate -s 8M fat.img
mkfs.fat -F 12 -s 4 -n BOBFLASH fat.img >/dev/null
mcopy -i fat.img boot.scr ::boot.scr
DISK_SECTORS="$DISK_SECTORS" python3 - <<'PY'
import os, struct, uuid, zlib
DISK = int(os.environ["DISK_SECTORS"]); P1_FIRST = 32768; P1_LAST = P1_FIRST + 16384 - 1; LAST_USABLE = DISK - 34
ent = bytearray(128 * 128)
e = bytearray(128); e[0:16] = uuid.UUID("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7").bytes_le; e[16:32] = uuid.uuid4().bytes_le
struct.pack_into("<QQQ", e, 32, P1_FIRST, P1_LAST, 0); e[56:72] = "bobflash".encode("utf-16le"); ent[0:128] = e
hdr = bytearray(92); hdr[0:8] = b"EFI PART"; struct.pack_into("<IIIIQQQQ", hdr, 8, 0x10000, 92, 0, 0, 1, DISK - 1, 34, LAST_USABLE)
hdr[56:72] = uuid.uuid4().bytes_le; struct.pack_into("<QIII", hdr, 72, 2, 128, 128, zlib.crc32(bytes(ent)) & 0xffffffff)
struct.pack_into("<I", hdr, 16, zlib.crc32(bytes(hdr)) & 0xffffffff)
mbr = bytearray(512); mbr[446:462] = bytes([0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF]) + struct.pack("<II", 1, 0xFFFFFFFF); mbr[510:512] = b"\x55\xaa"
out = bytes(mbr) + bytes(hdr).ljust(512, b"\0") + bytes(ent); assert len(out) == 34 * 512
open("gpt.bin", "wb").write(out)
PY
echo "built in $PWD:"; ls -l boot.scr fat.img gpt.bin
