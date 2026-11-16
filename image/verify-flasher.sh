#!/usr/bin/env bash
#
# CI check of a built flasher image with tools that need root (loop devices,
# fsck.vfat, sgdisk). Run with sudo on a CI runner:
#
#   sudo image/verify-flasher.sh dist/bobcat-g295-flasher.img.xz
#
# It decompresses the image, validates the partition table with two independent
# tools, mounts the BOBCFG partition and checks it, and exercises tools/write-sd.sh
# against a copy.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
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

# 4. tools/write-sd.sh against a copy: settings must land on BOBCFG
printf 'HOSTNAME=ci-test\n' > "$WORK/my.conf"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest ci@test\n' > "$WORK/keys.pub"
"$ROOT/tools/write-sd.sh" --yes --config "$WORK/my.conf" --keys "$WORK/keys.pub" "$WORK/f.img" "$WORK/copy.img" > "$WORK/write.out" 2>&1 ||
    { cat "$WORK/write.out"; fail "tools/write-sd.sh failed"; }
LOOP="$(losetup -fP --show "$WORK/copy.img")"
for _ in $(seq 1 20); do [[ -b "${LOOP}p7" ]] && break; sleep 0.5; done
mount -t vfat -o ro "${LOOP}p7" "$WORK/mnt"
cmp "$WORK/my.conf" "$WORK/mnt/bobcat-install.conf" || fail "bobcat-install.conf differs after write-sd.sh"
cmp "$WORK/keys.pub" "$WORK/mnt/bobcat-authorized_keys" || fail "bobcat-authorized_keys differs after write-sd.sh"
ok "tools/write-sd.sh put the settings on BOBCFG byte for byte"
umount "$WORK/mnt"
printf 'bogus line without equals\nFREQUENCY=12\n' > "$WORK/bad.conf"
if "$ROOT/tools/write-sd.sh" --yes --config "$WORK/bad.conf" "$WORK/f.img" "$WORK/bad.img" > "$WORK/bad.out" 2>&1; then
    fail "write-sd.sh accepted an invalid settings file"
fi
[[ ! -e "$WORK/bad.img" ]] && ok "write-sd.sh refuses an invalid settings file before writing anything"
echo "flasher verification passed"
