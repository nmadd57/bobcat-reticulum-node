#!/usr/bin/env bash
#
# Build a self-installing Bobcat Reticulum node image.
#
# Takes the community Bobcat Armbian image (G290/G295), adds the installer and
# a first-boot service to its root filesystem, and writes a new .img.xz. On its
# first boot with internet access the image installs and starts the Reticulum
# node by itself.
#
# Needs no root: the ext4 root filesystem is edited in place with debugfs.
# Requires: bash, curl, xz, python3, e2fsprogs (debugfs, e2fsck), sha256sum.
#
# Usage:
#   image/build-image.sh [options]
#
#   --installer FILE   installer bundle (default: dist/bobcat-g295-install.sh,
#                      built with installer/build-installer.sh if missing)
#   --config FILE      bake install settings (Wi-Fi etc.) into the image as
#                      /etc/bobcat-lora/install.conf. The image then CONTAINS
#                      those secrets: do not publish it.
#   --out FILE         output (default: dist/bobcat-g295-reticulum.img.xz)
#   --cache DIR        download/work directory (default: .cache)
#   --no-compress      leave the raw .img next to --out instead of compressing
#   --skip-verify      skip the filesystem check (faster, not recommended)
#   -h, --help
#
# Environment:
#   UPSTREAM_URL, UPSTREAM_SHA256   the base image and its checksum
#   XZ_LEVEL                        xz preset for the output (default 3)
#   BUILD_REF                       text recorded in the image (default: git hash)
#
# The base image is a third-party community build; it is downloaded, never
# stored in this repository, and the output should not be redistributed unless
# its license allows it.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/sicXnull/Bobcat-Armbian/releases/download/1.0/BobcatArmbian29x.img.xz}"
UPSTREAM_SHA256="${UPSTREAM_SHA256:-079b540477c34534dbceccd617c9920e60cbbdf8bf5a442c9bd0b29a6a64ad00}"
XZ_LEVEL="${XZ_LEVEL:-3}"

INSTALLER="$ROOT/dist/bobcat-g295-install.sh"
CONFIG=""
OUT="$ROOT/dist/bobcat-g295-reticulum.img.xz"
CACHE="$ROOT/.cache"
COMPRESS=1
VERIFY=1

log()  { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --installer)   [[ $# -ge 2 ]] || fail "$1 needs a value"; INSTALLER="$2"; shift 2 ;;
        --config)      [[ $# -ge 2 ]] || fail "$1 needs a value"; CONFIG="$2"; shift 2 ;;
        --out)         [[ $# -ge 2 ]] || fail "$1 needs a value"; OUT="$2"; shift 2 ;;
        --cache)       [[ $# -ge 2 ]] || fail "$1 needs a value"; CACHE="$2"; shift 2 ;;
        --no-compress) COMPRESS=0; shift ;;
        --skip-verify) VERIFY=0; shift ;;
        -h|--help)     sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             fail "unknown option: $1" ;;
    esac
done

for tool in curl xz python3 debugfs e2fsck sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing tool: $tool"
done

# --- inputs ---------------------------------------------------------------

if [[ ! -f "$INSTALLER" ]]; then
    log "Building the installer bundle"
    "$ROOT/installer/build-installer.sh"
fi
[[ -f "$INSTALLER" ]] || fail "installer not found: $INSTALLER"
[[ -z "$CONFIG" || -f "$CONFIG" ]] || fail "config file not found: $CONFIG"

FIRSTBOOT="$HERE/firstboot/bobcat-firstboot"
UNIT="$HERE/firstboot/bobcat-firstboot.service"
for f in "$FIRSTBOOT" "$UNIT"; do [[ -f "$f" ]] || fail "missing $f"; done

mkdir -p "$CACHE" "$(dirname "$OUT")"
BASE_XZ="$CACHE/$(basename "$UPSTREAM_URL")"

log "Base image"
if [[ ! -f "$BASE_XZ" ]]; then
    note "downloading $UPSTREAM_URL"
    curl -fL --retry 3 -o "$BASE_XZ.part" "$UPSTREAM_URL"
    mv "$BASE_XZ.part" "$BASE_XZ"
fi
if [[ "$UPSTREAM_SHA256" != "skip" ]]; then
    actual="$(sha256sum "$BASE_XZ" | cut -d' ' -f1)"
    [[ "$actual" == "$UPSTREAM_SHA256" ]] ||
        fail "checksum mismatch for $BASE_XZ (expected $UPSTREAM_SHA256, got $actual); delete it to re-download"
    note "checksum ok"
fi

WORK="$CACHE/work"
IMG="$WORK/bobcat-g295-reticulum.img"
rm -rf "$WORK"
mkdir -p "$WORK"
note "decompressing"
xz -dc "$BASE_XZ" > "$IMG"

# --- locate the root filesystem ------------------------------------------

log "Locating the root filesystem"
read -r ROOT_OFFSET ROOT_SIZE < <(python3 -I - "$IMG" <<'PY'
import struct, sys
with open(sys.argv[1], "rb") as f:
    f.seek(512)
    hdr = f.read(92)
    if hdr[:8] != b"EFI PART":
        sys.exit("not a GPT disk image")
    entries_lba, count, size = struct.unpack("<QII", hdr[72:88])
    f.seek(entries_lba * 512)
    for _ in range(count):
        e = f.read(size)
        if len(e) < size or e[:16] == b"\0" * 16:
            continue
        first, last = struct.unpack("<QQ", e[32:48])
        name = e[56:128].decode("utf-16le").rstrip("\0")
        if name == "rootfs":
            print(first * 512, (last - first + 1) * 512)
            break
    else:
        sys.exit("no partition named rootfs")
PY
)
[[ -n "${ROOT_OFFSET:-}" ]] || fail "could not find the rootfs partition"
note "rootfs at byte offset $ROOT_OFFSET (size $ROOT_SIZE)"
FS="$IMG?offset=$ROOT_OFFSET"

dfs() { debugfs "$@" 2>&1; }
dfs -R "stat /etc/os-release" "$FS" | grep -q "^Inode:" || fail "cannot read the root filesystem (is this the right image?)"

# --- stage files ----------------------------------------------------------

BUILD_REF="${BUILD_REF:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
{
    echo "bobcat-reticulum-node image"
    echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "ref:   $BUILD_REF"
    echo "base:  $(basename "$UPSTREAM_URL") sha256=$UPSTREAM_SHA256"
} > "$STAGE/BUILD_INFO"

# --- patch ----------------------------------------------------------------

log "Adding the installer and first-boot service"
CMDS="$WORK/debugfs.cmds"
{
    echo "mkdir /usr/local/share/bobcat-lora"
    echo "write $INSTALLER /usr/local/share/bobcat-lora/bobcat-g295-install.sh"
    echo "write $STAGE/BUILD_INFO /usr/local/share/bobcat-lora/BUILD_INFO"
    echo "write $FIRSTBOOT /usr/local/sbin/bobcat-firstboot"
    echo "write $UNIT /etc/systemd/system/bobcat-firstboot.service"
    echo "symlink /etc/systemd/system/multi-user.target.wants/bobcat-firstboot.service ../bobcat-firstboot.service"
    if [[ -n "$CONFIG" ]]; then
        echo "mkdir /etc/bobcat-lora"
        echo "write $CONFIG /etc/bobcat-lora/install.conf"
    fi
    # Ownership and modes: files written by debugfs take the local owner.
    for f in /usr/local/share/bobcat-lora /usr/local/share/bobcat-lora/BUILD_INFO \
             /etc/systemd/system/bobcat-firstboot.service; do
        echo "set_inode_field $f uid 0"
        echo "set_inode_field $f gid 0"
    done
    echo "set_inode_field /usr/local/share/bobcat-lora/bobcat-g295-install.sh uid 0"
    echo "set_inode_field /usr/local/share/bobcat-lora/bobcat-g295-install.sh gid 0"
    echo "set_inode_field /usr/local/share/bobcat-lora/bobcat-g295-install.sh mode 0100755"
    echo "set_inode_field /usr/local/share/bobcat-lora/BUILD_INFO mode 0100644"
    echo "set_inode_field /usr/local/sbin/bobcat-firstboot uid 0"
    echo "set_inode_field /usr/local/sbin/bobcat-firstboot gid 0"
    echo "set_inode_field /usr/local/sbin/bobcat-firstboot mode 0100755"
    echo "set_inode_field /etc/systemd/system/bobcat-firstboot.service mode 0100644"
    echo "set_inode_field /etc/systemd/system/multi-user.target.wants/bobcat-firstboot.service uid 0"
    echo "set_inode_field /etc/systemd/system/multi-user.target.wants/bobcat-firstboot.service gid 0"
    if [[ -n "$CONFIG" ]]; then
        for f in /etc/bobcat-lora /etc/bobcat-lora/install.conf; do
            echo "set_inode_field $f uid 0"
            echo "set_inode_field $f gid 0"
        done
        echo "set_inode_field /etc/bobcat-lora mode 040700"
        echo "set_inode_field /etc/bobcat-lora/install.conf mode 0100600"
    fi
} > "$CMDS"

PATCH_LOG="$WORK/debugfs.out"
debugfs -w -f "$CMDS" "$FS" > "$PATCH_LOG" 2>&1 || true
# debugfs reports problems on stderr but still exits 0; scan for them.
if grep -iE "(error|not found|already exists|invalid|cannot|no such)" "$PATCH_LOG" | grep -v "^debugfs [0-9]" >/dev/null; then
    grep -iE "(error|not found|already exists|invalid|cannot|no such)" "$PATCH_LOG" >&2 || true
    fail "debugfs reported problems while patching (log: $PATCH_LOG)"
fi

# --- verify ---------------------------------------------------------------

log "Verifying"
check_file() {   # check_file <local file> <path in image> <mode> [--secret]
    local want got mode
    want="$(sha256sum "$1" | cut -d' ' -f1)"
    got="$(debugfs -R "cat $2" "$FS" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "$want" == "$got" ]] || fail "content mismatch for $2"
    mode="$(debugfs -R "stat $2" "$FS" 2>/dev/null | sed -n 's/.*Mode: *\([0-7]*\).*/\1/p' | head -1)"
    [[ "$mode" == "$3" ]] || fail "wrong mode for $2: $mode (want $3)"
    note "ok  $2 ($3)"
}
check_file "$INSTALLER" /usr/local/share/bobcat-lora/bobcat-g295-install.sh 0755
check_file "$FIRSTBOOT" /usr/local/sbin/bobcat-firstboot 0755
check_file "$UNIT" /etc/systemd/system/bobcat-firstboot.service 0644
[[ -z "$CONFIG" ]] || check_file "$CONFIG" /etc/bobcat-lora/install.conf 0600

link="$(debugfs -R "stat /etc/systemd/system/multi-user.target.wants/bobcat-firstboot.service" "$FS" 2>/dev/null | sed -n 's/.*Fast link dest: "\(.*\)".*/\1/p')"
[[ "$link" == "../bobcat-firstboot.service" ]] || fail "service enable symlink is wrong: '$link'"
note "ok  service enabled via multi-user.target.wants"

uid_gid="$(debugfs -R "stat /usr/local/sbin/bobcat-firstboot" "$FS" 2>/dev/null | sed -n 's/.*User: *\([0-9]*\).*Group: *\([0-9]*\).*/\1:\2/p' | head -1)"
[[ "$uid_gid" == "0:0" ]] || fail "wrong owner on the first-boot script: $uid_gid"
note "ok  owner root:root"

if [[ "$VERIFY" -eq 1 ]]; then
    note "checking the filesystem (e2fsck -fn)"
    if ! e2fsck -fn "$FS" > "$WORK/e2fsck.out" 2>&1; then
        tail -15 "$WORK/e2fsck.out" >&2
        fail "filesystem check failed (full output: $WORK/e2fsck.out)"
    fi
    note "ok  filesystem clean"
fi

# --- output ---------------------------------------------------------------

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
[[ -z "$CONFIG" ]] || note "this image contains the settings from $CONFIG (including secrets): do not publish it"
