#!/usr/bin/env bash
#
# Build the self-installing STANDALONE Bobcat image (boots from an SD card).
#
# For flashing the eMMC with a config file that travels with the image, use
# build-flasher.sh instead; it is the recommended path for G290/G295 units.
#
# Takes the community Bobcat Armbian image, adds the installer and a first-boot
# service to its root filesystem, and writes a new .img.xz. Needs no root: the
# ext4 root filesystem is edited in place with debugfs.
# Requires: bash, curl, xz, python3, e2fsprogs (debugfs, e2fsck), sha256sum.
#
# Usage: image/build-image.sh [options]
#   --installer FILE   installer bundle (default dist/bobcat-g295-install.sh,
#                      built if missing)
#   --config FILE      bake install settings into the image. The image then
#                      CONTAINS those secrets: never publish it.
#   --out FILE         output (default dist/bobcat-g295-reticulum.img.xz)
#   --cache DIR        download/work directory (default .cache)
#   --no-compress      leave the raw image instead of compressing
#   --skip-verify      skip the filesystem check
#
# Environment: UPSTREAM_URL, UPSTREAM_SHA256, XZ_LEVEL (default 3), BUILD_REF.
#
# The base image is a third-party community build: it is downloaded, never
# stored in this repository, and the output should not be redistributed unless
# its license allows it.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=image/lib.sh
source "$HERE/lib.sh"

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/sicXnull/Bobcat-Armbian/releases/download/1.0/BobcatArmbian29x.img.xz}"
UPSTREAM_SHA256="${UPSTREAM_SHA256:-079b540477c34534dbceccd617c9920e60cbbdf8bf5a442c9bd0b29a6a64ad00}"
XZ_LEVEL="${XZ_LEVEL:-3}"

INSTALLER="$ROOT/dist/bobcat-g295-install.sh"
BAKED_CONFIG=""
OUT="$ROOT/dist/bobcat-g295-reticulum.img.xz"
CACHE="$ROOT/.cache"
COMPRESS=1
VERIFY=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --installer)   [[ $# -ge 2 ]] || fail "$1 needs a value"; INSTALLER="$2"; shift 2 ;;
        --config)      [[ $# -ge 2 ]] || fail "$1 needs a value"; BAKED_CONFIG="$2"; shift 2 ;;
        --out)         [[ $# -ge 2 ]] || fail "$1 needs a value"; OUT="$2"; shift 2 ;;
        --cache)       [[ $# -ge 2 ]] || fail "$1 needs a value"; CACHE="$2"; shift 2 ;;
        --no-compress) COMPRESS=0; shift ;;
        --skip-verify) VERIFY=0; shift ;;
        -h|--help)     sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             fail "unknown option: $1" ;;
    esac
done

need_tools curl xz python3 debugfs e2fsck sha256sum

if [[ ! -f "$INSTALLER" ]]; then
    log "Building the installer bundle"
    "$ROOT/installer/build-installer.sh"
fi
[[ -f "$INSTALLER" ]] || fail "installer not found: $INSTALLER"
[[ -z "$BAKED_CONFIG" || -f "$BAKED_CONFIG" ]] || fail "config file not found: $BAKED_CONFIG"

FIRSTBOOT="$HERE/firstboot/bobcat-firstboot"
UNIT="$HERE/firstboot/bobcat-firstboot.service"
for f in "$FIRSTBOOT" "$UNIT"; do [[ -f "$f" ]] || fail "missing $f"; done

mkdir -p "$CACHE" "$(dirname "$OUT")"
BASE_XZ="$CACHE/$(basename "$UPSTREAM_URL")"
WORK="$CACHE/work"
IMG="$WORK/bobcat-g295-reticulum.img"
BUILD_REF="${BUILD_REF:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
BASE_DESC="$(basename "$UPSTREAM_URL") sha256=$UPSTREAM_SHA256"
export INSTALLER FIRSTBOOT UNIT WORK BUILD_REF BASE_DESC BAKED_CONFIG

log "Base image"
download_verified "$UPSTREAM_URL" "$UPSTREAM_SHA256" "$BASE_XZ"
rm -rf "$WORK"
mkdir -p "$WORK"
note "decompressing"
xz -dc "$BASE_XZ" > "$IMG"

log "Adding the installer and first-boot service"
patch_os_image "$IMG"

log "Verifying"
if [[ "$VERIFY" -eq 1 ]]; then verify_os_image "$IMG"; else verify_os_image "$IMG" --skip-fsck; fi

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
[[ -z "$BAKED_CONFIG" ]] || note "this image contains the settings from $BAKED_CONFIG (including secrets): do not publish it"
