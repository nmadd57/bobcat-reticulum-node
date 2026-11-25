#!/usr/bin/env bash
#
# Build the self-installing eMMC FLASHER image: the recommended way to put the
# Reticulum node on a Bobcat G290/G295.
#
# It is the community eMMC flasher (an SD card image that writes an OS image to
# the internal storage) with three changes:
#   1. the OS image it carries has the installer and a first-boot service added;
#   2. its init script also copies settings files from a small FAT partition on
#      the SD card (label BOBCFG, partition 7) to the eMMC while flashing;
#   3. that BOBCFG partition is added to the image, so you can drop your
#      settings file onto the card from any computer before powering on.
# No settings or secrets are stored in the image.
#
# Needs no root. Requires: bash, curl, xz, python3, e2fsprogs (debugfs, e2fsck),
# sha256sum, and for the settings partition dosfstools (mkfs.vfat) and mtools.
#
# Usage: image/build-flasher.sh [options]
#   --installer FILE       installer bundle (default dist/bobcat-g295-install.sh,
#                          built if missing)
#   --preload-config FILE  also place FILE on the BOBCFG partition as
#                          bobcat-install.conf. The image then holds your
#                          settings: for your own use only, never publish it.
#   --out FILE             output (default dist/bobcat-g295-flasher.img.xz)
#   --emmc-out FILE        also write the patched OS image the flasher carries as its own
#                          compressed file (an image that boots from the eMMC, for writing it by
#                          other means, for example over USB; see docs/usb-flashing.md)
#   --cache DIR            download/work directory (default .cache)
#   --no-compress          leave the raw image instead of compressing
#   --skip-fat             do not format the BOBCFG partition (testing only)
#
# Environment: FLASHER_URL, FLASHER_SHA256, XZ_LEVEL (default 3), BUILD_REF.
#
# The flasher is a third-party community build: it is downloaded, never stored
# in this repository, and the output should not be redistributed unless its
# license allows it.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=image/lib.sh
source "$HERE/lib.sh"

FLASHER_URL="${FLASHER_URL:-https://github.com/sicXnull/Bobcat-Armbian/releases/download/1.0/Bobcat29X_EMMC_Flasher.img.xz}"
FLASHER_SHA256="${FLASHER_SHA256:-f797aaff9406e8db66a5c49075ac569e070a2ddc25b84de38b6995d621b56889}"
PAYLOAD_NAME="Armbian-unofficial_26.02.0-trunk_Bobcat-29x_bookworm_current_6.18.4.img"
CONFIG_PART_MIB=64
XZ_LEVEL="${XZ_LEVEL:-3}"

INSTALLER="$ROOT/dist/bobcat-g295-install.sh"
PRELOAD=""
OUT="$ROOT/dist/bobcat-g295-flasher.img.xz"
EMMC_OUT=""
CACHE="$ROOT/.cache"
COMPRESS=1
SKIP_FAT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --installer)      [[ $# -ge 2 ]] || fail "$1 needs a value"; INSTALLER="$2"; shift 2 ;;
        --preload-config) [[ $# -ge 2 ]] || fail "$1 needs a value"; PRELOAD="$2"; shift 2 ;;
        --out)            [[ $# -ge 2 ]] || fail "$1 needs a value"; OUT="$2"; shift 2 ;;
        --emmc-out)       [[ $# -ge 2 ]] || fail "$1 needs a value"; EMMC_OUT="$2"; shift 2 ;;
        --cache)          [[ $# -ge 2 ]] || fail "$1 needs a value"; CACHE="$2"; shift 2 ;;
        --no-compress)    COMPRESS=0; shift ;;
        --skip-fat)       SKIP_FAT=1; shift ;;
        -h|--help)        sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                fail "unknown option: $1" ;;
    esac
done

need_tools curl xz python3 debugfs e2fsck sha256sum
[[ "$SKIP_FAT" -eq 1 ]] || need_tools mkfs.vfat mcopy mdir

if [[ ! -f "$INSTALLER" ]]; then
    log "Building the installer bundle"
    "$ROOT/installer/build-installer.sh"
fi
[[ -f "$INSTALLER" ]] || fail "installer not found: $INSTALLER"
[[ -z "$PRELOAD" || -f "$PRELOAD" ]] || fail "config file not found: $PRELOAD"

FIRSTBOOT="$HERE/firstboot/bobcat-firstboot"
UNIT="$HERE/firstboot/bobcat-firstboot.service"
INIT="$HERE/flasher/init.sh"
for f in "$FIRSTBOOT" "$UNIT" "$INIT" "$HERE/tools/gpt_tool.py"; do [[ -f "$f" ]] || fail "missing $f"; done

mkdir -p "$CACHE" "$(dirname "$OUT")"
BASE_XZ="$CACHE/$(basename "$FLASHER_URL")"
WORK="$CACHE/work-flasher"
IMG="$WORK/bobcat-g295-flasher.img"
PAYLOAD="$WORK/payload.img"
BUILD_REF="${BUILD_REF:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
BASE_DESC="flasher $(basename "$FLASHER_URL") sha256=$FLASHER_SHA256"
export INSTALLER FIRSTBOOT UNIT WORK BUILD_REF BASE_DESC
unset BAKED_CONFIG

log "Base flasher"
download_verified "$FLASHER_URL" "$FLASHER_SHA256" "$BASE_XZ"
rm -rf "$WORK"
mkdir -p "$WORK"
note "decompressing"
xz -dc "$BASE_XZ" > "$IMG"

read -r ROOT_OFF ROOT_SIZE < <(gpt_partition "$IMG" rootfs) || fail "no rootfs partition in the flasher"
FS="$IMG?offset=$ROOT_OFF"
note "flasher rootfs at byte offset $ROOT_OFF (size $ROOT_SIZE)"
# The community flasher's filesystem was left with an unreplayed journal. Replay it
# now, before any edit: replaying it later would overwrite the edits.
log "Preparing the flasher filesystem"
pending=0
has_pending_journal "$FS" || pending=$?
[[ "$pending" -ne 2 ]] || exit 1
if [[ "$pending" -eq 0 ]]; then
    note "replaying the pending journal (e2fsck -fy)"
    repair_partition "$IMG" "$ROOT_OFF" "$ROOT_SIZE" "$WORK/e2fsck-prep.out"
else
    note "no pending journal"
fi
assert_clean_journal "$FS"
note "ok  no pending journal"
debugfs -R "stat /$PAYLOAD_NAME" "$FS" 2>/dev/null | grep -q '^Inode:' ||
    fail "the OS image $PAYLOAD_NAME is not in the flasher (a different flasher version?)"
debugfs -R "stat /init.sh" "$FS" 2>/dev/null | grep -q '^Inode:' || fail "no /init.sh in the flasher"

log "Extracting the OS image the flasher carries"
debugfs -R "dump /$PAYLOAD_NAME $PAYLOAD" "$FS" >/dev/null 2>&1
[[ -s "$PAYLOAD" ]] || fail "could not extract the OS image"
note "$(du -h "$PAYLOAD" | cut -f1)"

log "Adding the installer and first-boot service to it"
patch_os_image "$PAYLOAD"
verify_os_image "$PAYLOAD"
PAYLOAD_SHA="$(sha256sum "$PAYLOAD" | cut -d' ' -f1)"

if [[ -n "$EMMC_OUT" ]]; then
    log "Writing the patched OS image as its own file (boots from the eMMC)"
    mkdir -p "$(dirname "$EMMC_OUT")"
    xz -T0 -"${XZ_LEVEL:-3}" -c "$PAYLOAD" > "$EMMC_OUT.part"
    mv "$EMMC_OUT.part" "$EMMC_OUT"
    (cd "$(dirname "$EMMC_OUT")" && sha256sum "$(basename "$EMMC_OUT")" > "$(basename "$EMMC_OUT").sha256")
    note "$EMMC_OUT ($(du -h "$EMMC_OUT" | cut -f1)), uncompressed sha256 $PAYLOAD_SHA"
fi

log "Putting the patched OS image and the new init script into the flasher"
CMDS="$WORK/flasher.cmds"
{
    echo "rm /$PAYLOAD_NAME"
    echo "write $PAYLOAD /$PAYLOAD_NAME"
    echo "set_inode_field /$PAYLOAD_NAME uid 0"
    echo "set_inode_field /$PAYLOAD_NAME gid 0"
    echo "set_inode_field /$PAYLOAD_NAME mode 0100644"
    echo "rm /init.sh"
    echo "write $INIT /init.sh"
    echo "set_inode_field /init.sh uid 0"
    echo "set_inode_field /init.sh gid 0"
    echo "set_inode_field /init.sh mode 0100755"
} > "$CMDS"
debugfs -w -f "$CMDS" "$FS" > "$WORK/flasher.out" 2>&1 || true
if grep -iE "(error|not found|already exists|invalid|cannot|no such|no free|no space)" "$WORK/flasher.out" | grep -qv "^debugfs [0-9]"; then
    grep -iE "(error|not found|already exists|invalid|cannot|no such|no free|no space)" "$WORK/flasher.out" >&2 || true
    fail "debugfs reported problems writing into the flasher (log: $WORK/flasher.out)"
fi
rm -f "$PAYLOAD"

log "Verifying the flasher contents"
got="$(debugfs -R "cat /$PAYLOAD_NAME" "$FS" 2>/dev/null | sha256sum | cut -d' ' -f1)"
[[ "$got" == "$PAYLOAD_SHA" ]] || fail "the OS image inside the flasher does not match what was patched"
note "ok  patched OS image is in place (sha256 ${PAYLOAD_SHA:0:16}...)"
check_file "$FS" "$INIT" /init.sh 0755
# Removing and rewriting a multi-gigabyte file with debugfs leaves the free-block
# counters stale. That is bookkeeping, not corruption: fix it with a real repair
# pass (safe now, the journal is clean) and demand a clean check afterwards.
note "repairing filesystem counters (e2fsck -fy on a copy of the partition)"
repair_partition "$IMG" "$ROOT_OFF" "$ROOT_SIZE" "$WORK/e2fsck-fix.out"
note "ok  filesystem clean"
got="$(debugfs -R "cat /$PAYLOAD_NAME" "$FS" 2>/dev/null | sha256sum | cut -d' ' -f1)"
[[ "$got" == "$PAYLOAD_SHA" ]] || fail "the OS image changed during the repair pass"

log "Adding the BOBCFG settings partition (${CONFIG_PART_MIB} MiB, partition 7)"
read -r CFG_START CFG_SIZE < <(python3 -I "$HERE/tools/gpt_tool.py" add "$IMG" --name BOBCFG --size-mib "$CONFIG_PART_MIB" --number 7)
note "at byte offset $CFG_START (size $CFG_SIZE)"
if [[ "$SKIP_FAT" -eq 0 ]]; then
    FAT="$WORK/bobcfg.img"
    dd if=/dev/zero of="$FAT" bs=1M count="$CONFIG_PART_MIB" status=none
    mkfs.vfat -n BOBCFG "$FAT" >/dev/null
    mcopy -i "$FAT" "$HERE/flasher/config-partition/README.txt" ::/README.txt
    mcopy -i "$FAT" "$HERE/firstboot/bobcat-install.conf.example" ::/bobcat-install.conf.example
    if [[ -n "$PRELOAD" ]]; then
        mcopy -i "$FAT" "$PRELOAD" ::/bobcat-install.conf
        note "preloaded $PRELOAD as bobcat-install.conf"
    fi
    dd if="$FAT" of="$IMG" bs=1M seek=$((CFG_START / 1048576)) conv=notrunc status=none
    rm -f "$FAT"
    note "files on the partition:"
    mdir -b -i "$IMG@@$CFG_START" :: | sed 's/^/      /'
else
    note "--skip-fat: partition left unformatted (testing only)"
fi
python3 -I "$HERE/tools/gpt_tool.py" check "$IMG" | sed 's/^/      /'
note "ok  partition table valid"

if [[ "$COMPRESS" -eq 1 ]]; then
    log "Compressing (xz -$XZ_LEVEL)"
    xz -T0 -"$XZ_LEVEL" -c "$IMG" > "$OUT.part"
    mv "$OUT.part" "$OUT"
    rm -f "$IMG"
else
    OUT="${OUT%.xz}"
    mv "$IMG" "$OUT"
fi
(cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")

log "Done: $OUT ($(du -h "$OUT" | cut -f1))"
cat "$OUT.sha256"
[[ -z "$PRELOAD" ]] || note "this image contains the settings from $PRELOAD (including secrets): do not publish it"
