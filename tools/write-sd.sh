#!/usr/bin/env bash
#
# Write the flasher image to an SD card and put your settings on it, in one step.
#
#   tools/write-sd.sh [options] IMAGE DEVICE
#
#   IMAGE    bobcat-g295-flasher.img or .img.xz
#   DEVICE   a whole SD card, e.g. /dev/sdb or /dev/mmcblk0 (NOT a partition);
#            a regular file works too, for testing
#
#   --config FILE       your settings, stored as bobcat-install.conf
#   --keys FILE         SSH public keys, stored as bobcat-authorized_keys
#   --netplan FILE      a complete netplan config, stored as bobcat-netplan.yaml
#   --reticulum FILE    a complete Reticulum config, stored as bobcat-reticulum.conf
#   --yes               do not ask for confirmation
#   --force             allow a disk that is not flagged removable (DANGEROUS)
#
# Linux only (uses dd, mount, sudo). On Windows or macOS write the image with any
# imaging tool, then copy the settings files onto the card's BOBCFG drive.
#
# THIS ERASES THE DEVICE. Check the device name twice.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GPT="$ROOT/image/tools/gpt_tool.py"

log()  { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

CONFIG="" KEYS="" NETPLAN="" RETICULUM="" ASSUME_YES=0 FORCE=0
POS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)    [[ $# -ge 2 ]] || fail "$1 needs a file"; CONFIG="$2"; shift 2 ;;
        --keys)      [[ $# -ge 2 ]] || fail "$1 needs a file"; KEYS="$2"; shift 2 ;;
        --netplan)   [[ $# -ge 2 ]] || fail "$1 needs a file"; NETPLAN="$2"; shift 2 ;;
        --reticulum) [[ $# -ge 2 ]] || fail "$1 needs a file"; RETICULUM="$2"; shift 2 ;;
        --yes)       ASSUME_YES=1; shift ;;
        --force)     FORCE=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        -*)          fail "unknown option: $1" ;;
        *)           POS+=("$1"); shift ;;
    esac
done
[[ ${#POS[@]} -eq 2 ]] || { usage >&2; exit 2; }
IMAGE="${POS[0]}"
DEVICE="${POS[1]}"

[[ -f "$IMAGE" ]] || fail "image not found: $IMAGE"
for f in "$CONFIG" "$KEYS" "$NETPLAN" "$RETICULUM"; do
    [[ -z "$f" || -f "$f" ]] || fail "file not found: $f"
done
command -v python3 >/dev/null || fail "python3 is required"
[[ -f "$GPT" ]] || fail "missing $GPT (run this from a checkout of the repository)"
case "$IMAGE" in *.xz) command -v xz >/dev/null || fail "xz is required for .xz images" ;; esac

SUDO=""
[[ "$EUID" -eq 0 ]] || SUDO="sudo"

# --- check the settings file before touching the card ----------------------
if [[ -n "$CONFIG" ]]; then
    CHECKER=""
    for c in "$ROOT/installer/install-template.sh" "$ROOT/dist/bobcat-g295-install.sh"; do
        [[ -f "$c" ]] && { CHECKER="$c"; break; }
    done
    if [[ -n "$CHECKER" ]]; then
        log "Checking $CONFIG"
        args=(--dry-run --config "$CONFIG")
        [[ -z "$KEYS" ]] || args+=(--ssh-key-file "$KEYS")
        bash "$CHECKER" "${args[@]}" > /dev/null || fail "the settings file is not valid (see the message above); nothing was written"
        note "ok"
    else
        note "installer not found; the settings file could not be checked"
    fi
fi

# --- check the target -------------------------------------------------------
IS_FILE=0
if [[ -b "$DEVICE" ]]; then
    name="$(basename "$DEVICE")"
    type="$(lsblk -dno TYPE "$DEVICE" 2>/dev/null || true)"
    [[ "$type" == "disk" ]] || fail "$DEVICE is not a whole disk (type '$type'); give the device, not a partition"
    removable="$(cat "/sys/block/$name/removable" 2>/dev/null || echo 0)"
    if [[ "$removable" != "1" && "$FORCE" -ne 1 ]]; then
        fail "$DEVICE is not flagged removable. If it really is your SD card, repeat with --force"
    fi
    if lsblk -rno MOUNTPOINT "$DEVICE" 2>/dev/null | grep -q .; then
        fail "$DEVICE has mounted partitions; unmount them first"
    fi
    size="$(lsblk -dno SIZE "$DEVICE")"
    model="$(lsblk -dno MODEL "$DEVICE" 2>/dev/null | sed 's/ *$//')"
    echo
    echo "  About to ERASE $DEVICE ($size ${model:+, $model})"
    echo "  and write: $IMAGE"
    [[ -z "$CONFIG" ]] || echo "  with settings from: $CONFIG"
    echo
    if [[ "$ASSUME_YES" -ne 1 ]]; then
        read -r -p "  Type the device name to confirm ($DEVICE): " answer
        [[ "$answer" == "$DEVICE" ]] || fail "not confirmed; nothing was written"
    fi
elif [[ -e "$DEVICE" && ! -f "$DEVICE" ]]; then
    fail "$DEVICE is neither a block device nor a regular file"
else
    IS_FILE=1
    SUDO=""
    if [[ -n "$CONFIG$KEYS$NETPLAN$RETICULUM" ]]; then
        command -v mcopy >/dev/null || fail "mtools (mcopy) is needed to put settings into an image file"
    fi
    note "$DEVICE is a regular file: writing an image file (test mode)"
fi

# --- write ------------------------------------------------------------------
log "Writing the image"
if [[ "$IS_FILE" -eq 1 ]]; then
    case "$IMAGE" in
        *.xz) xz -dc "$IMAGE" > "$DEVICE" ;;
        *)    cp "$IMAGE" "$DEVICE" ;;
    esac
else
    case "$IMAGE" in
        *.xz) xz -dc "$IMAGE" | $SUDO dd of="$DEVICE" bs=4M conv=fsync status=progress ;;
        *)    $SUDO dd if="$IMAGE" of="$DEVICE" bs=4M conv=fsync status=progress ;;
    esac
    sync
fi

# --- settings ---------------------------------------------------------------
copy_pairs=()
[[ -z "$CONFIG"    ]] || copy_pairs+=("$CONFIG:bobcat-install.conf")
[[ -z "$KEYS"      ]] || copy_pairs+=("$KEYS:bobcat-authorized_keys")
[[ -z "$NETPLAN"   ]] || copy_pairs+=("$NETPLAN:bobcat-netplan.yaml")
[[ -z "$RETICULUM" ]] || copy_pairs+=("$RETICULUM:bobcat-reticulum.conf")

if [[ ${#copy_pairs[@]} -eq 0 ]]; then
    log "Done. No settings given: copy them to the card's BOBCFG drive before use."
    exit 0
fi

log "Copying settings to the BOBCFG partition"
if [[ "$IS_FILE" -eq 1 ]]; then
    command -v mcopy >/dev/null || fail "mtools (mcopy) is needed to write into an image file"
    offset="$(python3 -I "$GPT" check "$DEVICE" | awk -F'\t' '$1 == 7 { print $2 }')"
    [[ -n "$offset" ]] || fail "the image has no partition 7 (is this the flasher image?)"
    for pair in "${copy_pairs[@]}"; do
        mcopy -o -i "$DEVICE@@$offset" "${pair%%:*}" "::/${pair#*:}"
        note "${pair#*:}"
    done
else
    $SUDO partprobe "$DEVICE" 2>/dev/null || true
    command -v udevadm >/dev/null && $SUDO udevadm settle 2>/dev/null || true
    part=""
    for _ in $(seq 1 20); do
        for cand in "${DEVICE}7" "${DEVICE}p7"; do
            [[ -b "$cand" ]] && { part="$cand"; break 2; }
        done
        sleep 1
    done
    [[ -n "$part" ]] || fail "partition 7 did not appear on $DEVICE; copy the settings files to the BOBCFG drive by hand"
    mnt="$(mktemp -d)"
    cleanup() { $SUDO umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; }
    trap cleanup EXIT
    $SUDO mount -t vfat "$part" "$mnt"
    for pair in "${copy_pairs[@]}"; do
        $SUDO cp "${pair%%:*}" "$mnt/${pair#*:}"
        note "${pair#*:}"
    done
    sync
    cleanup
    trap - EXIT
fi
log "Done. Put the card in the Bobcat and power it on; it flashes itself, then installs on first boot."
