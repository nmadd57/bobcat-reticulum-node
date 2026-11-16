#!/usr/bin/env bash
#
# CI check of a built flasher image with tools that need root (loop devices,
# fsck.vfat, sgdisk). Run with sudo on a CI runner:
#
#   sudo image/verify-flasher.sh dist/bobcat-g295-flasher.img.xz
#
# It decompresses the image, validates the partition table with two independent
# tools, mounts the BOBCFG partition and checks it, then does what a user does:
# drops a settings file on it and reads it back.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${1:?usage: verify-flasher.sh IMAGE.img.xz}"
WORK="$(mktemp -d)"
LOOP=""
cleanup() {
    mountpoint -q "$WORK/mnt" 2>/dev/null && umount "$WORK/mnt" || true
    [[ -z "$LOOP" ]] || losetup -d "$LOOP" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

ok()   { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

case "$SRC" in
    *.xz) xz -dc "$SRC" > "$WORK/f.img" ;;
    *)    cp "$SRC" "$WORK/f.img" ;;
esac

# 1. partition table: our own checker and sgdisk
python3 -I "$HERE/tools/gpt_tool.py" check "$WORK/f.img" > "$WORK/parts.txt"
for want in uboot misc rootfs BOBCFG; do
    grep -q "$want" "$WORK/parts.txt" || fail "partition $want missing"
done
ok "partition table lists uboot, misc, rootfs, BOBCFG"
sgdisk -v "$WORK/f.img" > "$WORK/sgdisk.out" 2>&1 || { cat "$WORK/sgdisk.out"; fail "sgdisk reports a problem"; }
grep -qi "no problems found" "$WORK/sgdisk.out" || { cat "$WORK/sgdisk.out"; fail "sgdisk did not report 'no problems found'"; }
ok "sgdisk: no problems found"

# 2. the kernel's view: loop device with partition scanning
LOOP="$(losetup -fP --show "$WORK/f.img")"
for _ in $(seq 1 20); do [[ -b "${LOOP}p7" ]] && break; sleep 0.5; done
[[ -b "${LOOP}p7" ]] || fail "the kernel did not create partition 7"
ok "kernel sees partition 7 (${LOOP}p7)"

fsck.vfat -n "${LOOP}p7" > "$WORK/fsck.out" 2>&1 || { cat "$WORK/fsck.out"; fail "fsck.vfat found problems on BOBCFG"; }
ok "fsck.vfat: BOBCFG is clean"
mkdir -p "$WORK/mnt"
mount -t vfat -o ro "${LOOP}p7" "$WORK/mnt"
[[ -f "$WORK/mnt/README.txt" && -f "$WORK/mnt/bobcat-install.conf.example" ]] || { ls -la "$WORK/mnt"; fail "BOBCFG is missing its README or example"; }
[[ "$(blkid -s LABEL -o value "${LOOP}p7")" == "BOBCFG" ]] || fail "wrong filesystem label"
ok "BOBCFG mounts, has README.txt and the example, label BOBCFG"
umount "$WORK/mnt"

# 3. the flasher's own root filesystem and init script
mount -t ext4 -o ro "${LOOP}p6" "$WORK/mnt"
[[ -x "$WORK/mnt/init.sh" ]] || fail "no executable /init.sh"
grep -q "SIDECAR_PART=7" "$WORK/mnt/init.sh" || fail "/init.sh is not the Bobcat Reticulum one"
[[ -s "$WORK/mnt/Armbian-unofficial_26.02.0-trunk_Bobcat-29x_bookworm_current_6.18.4.img" ]] || fail "OS image missing"
ok "flasher root filesystem mounts; /init.sh and the OS image are present"
umount "$WORK/mnt"
losetup -d "$LOOP"; LOOP=""

# 4. What a user does: write the image (a plain copy here, dd on a real card),
#    mount the BOBCFG partition, drop a settings file on it, and read it back.
cp "$WORK/f.img" "$WORK/card.img"
LOOP="$(losetup -fP --show "$WORK/card.img")"
for _ in $(seq 1 20); do [[ -b "${LOOP}p7" ]] && break; sleep 0.5; done
mount -t vfat "${LOOP}p7" "$WORK/mnt"
printf 'HOSTNAME=ci-test\r\nFREQUENCY=915000000\r\n' > "$WORK/my.conf"
cp "$WORK/my.conf" "$WORK/mnt/bobcat-install.conf"
sync
umount "$WORK/mnt"
losetup -d "$LOOP"; LOOP=""
LOOP="$(losetup -fP --show "$WORK/card.img")"
for _ in $(seq 1 20); do [[ -b "${LOOP}p7" ]] && break; sleep 0.5; done
mount -t vfat -o ro "${LOOP}p7" "$WORK/mnt"
cmp "$WORK/my.conf" "$WORK/mnt/bobcat-install.conf" || fail "the settings file changed on the card"
ok "a settings file dropped on BOBCFG survives and reads back byte for byte"
# The flasher looks files up by exact name on a case-insensitive FAT: a name typed
# with different capitals (as Windows or macOS may store it) must still resolve.
[[ -f "$WORK/mnt/BOBCAT-INSTALL.CONF" ]] && ok "names resolve case-insensitively" || fail "FAT lookup is not case-insensitive"
umount "$WORK/mnt"
fsck.vfat -n "${LOOP}p7" > "$WORK/fsck2.out" 2>&1 || { cat "$WORK/fsck2.out"; fail "fsck.vfat found problems after writing a file"; }
ok "BOBCFG is still clean after a file was added"
echo "flasher verification passed"
