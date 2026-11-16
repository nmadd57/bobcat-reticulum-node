#!/usr/bin/env bash
#
# Tests for the flasher's init.sh logic (settings partition detection and copy),
# run under every POSIX shell found (bash always, dash if installed) because the
# real script runs under BusyBox ash. mount/umount/blockdev are stubbed.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT="$HERE/init.sh"
pass=0 failed=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '     %s\n' "$2"; }

# A scenario runs in a fresh sh process; its output and exit code are captured.
run_case() {   # run_case <shell> <T dir> <script body>
    local shell="$1" t="$2" body="$3"
    # shellcheck disable=SC2016
    env -i PATH="$t/bin:/usr/bin:/bin" T="$t" BASH_ENV=/dev/null ENV=/dev/null BOBCAT_FLASHER_NO_MAIN=1 \
        BOBCAT_DEV_DIR="$t/dev" BOBCAT_SD_MP="$t/mnt/sd" BOBCAT_EMMC_MP="$t/mnt/emmc" \
        BOBCAT_EMMC_DEV="$t/dev/mmcblk0" "$shell" -c '
            . "$0"
            is_block() { [ -e "$1" ]; }
            '"$body" "$INIT" 2>&1
}

setup() {   # setup <dir>: stub commands + empty fake devices
    local t="$1"
    mkdir -p "$t/bin" "$t/dev" "$t/mnt/sd" "$t/mnt/emmc"
    cat > "$t/bin/mount" <<'STUB'
#!/bin/sh
# mount -t vfat -o OPTS DEV MP  : "mounts" by pointing MP at DEV.d
opts=""; while [ $# -gt 0 ]; do case "$1" in -o) opts="$2"; shift 2;; -t) shift 2;; *) break;; esac; done
dev="$1"; mp="$2"
[ -d "$dev.d" ] || exit 32
case "${MOUNT_NEEDS:-}" in "") ;; *) case "$opts" in *"$MOUNT_NEEDS"*) ;; *) exit 32;; esac;; esac
rmdir "$mp" 2>/dev/null || rm -f "$mp"
ln -s "$dev.d" "$mp"
echo "$opts" >> "$T/mount.log"
STUB
    cat > "$t/bin/umount" <<'STUB'
#!/bin/sh
[ -L "$1" ] && { rm -f "$1"; mkdir -p "$1"; }
exit 0
STUB
    printf '#!/bin/sh\nexit 0\n' > "$t/bin/blockdev"
    cp "$t/bin/blockdev" "$t/bin/partprobe"
    cp "$t/bin/blockdev" "$t/bin/sleep"
    cp "$t/bin/blockdev" "$t/bin/sync"
    chmod +x "$t/bin/"*
}

make_sd() {    # make_sd <T> [files...]: SD card settings partition mmcblk1p7
    local t="$1"; shift
    : > "$t/dev/mmcblk1p7"; mkdir -p "$t/dev/mmcblk1p7.d"
    local f
    for f in "$@"; do printf 'contents of %s\r\nline2\n' "$f" > "$t/dev/mmcblk1p7.d/$f"; done
}
make_emmc() { : > "$1/dev/mmcblk0"; : > "$1/dev/mmcblk0p1"; mkdir -p "$1/dev/mmcblk0p1.d"; }

for shell in bash dash; do
    command -v "$shell" >/dev/null 2>&1 || continue
    echo "--- under $shell"
    T="$(mktemp -d)"

    # 1. normal case: config + extra files copied byte for byte
    rm -rf "$T"; T="$(mktemp -d)"; setup "$T"; make_sd "$T" bobcat-install.conf bobcat-authorized_keys; make_emmc "$T"
    out="$(run_case "$shell" "$T" 'find_sidecar || true; rc=0; copy_sidecar || rc=$?; echo "rc=$rc"')"
    [[ "$out" == *"rc=0"* ]] && ok "$shell: copy succeeds" || bad "$shell: copy succeeds" "$out"
    cmp -s "$T/dev/mmcblk1p7.d/bobcat-install.conf" "$T/dev/mmcblk0p1.d/bobcat-install.conf" &&
        ok "$shell: config copied byte for byte (CRLF kept)" || bad "$shell: config copied byte for byte"
    [[ -f "$T/dev/mmcblk0p1.d/bobcat-authorized_keys" ]] && ok "$shell: side file copied" || bad "$shell: side file copied"
    [[ ! -e "$T/dev/mmcblk0p1.d/bobcat-netplan.yaml" ]] && ok "$shell: absent files are not invented" || bad "$shell: absent files are not invented"
    [[ "$(head -1 "$T/mount.log")" == "ro,iocharset=cp437" ]] && ok "$shell: first mount try is the built-in cp437 table" || bad "$shell: first mount try" "$(cat "$T/mount.log")"

    # 2. charset fallback: only utf8 works
    rm -rf "$T"; T="$(mktemp -d)"; setup "$T"; make_sd "$T" bobcat-install.conf; make_emmc "$T"
    out="$(MOUNT_NEEDS=utf8 run_case "$shell" "$T" 'find_sidecar || true; rc=0; copy_sidecar || rc=$?; echo "rc=$rc"')"
    [[ "$out" == *"rc=0"* ]] && ok "$shell: falls back to another charset" || bad "$shell: falls back to another charset" "$out"

    # 3. no settings partition at all
    rm -rf "$T"; T="$(mktemp -d)"; setup "$T"; make_emmc "$T"
    out="$(run_case "$shell" "$T" 'find_sidecar || true; rc=0; copy_sidecar || rc=$?; echo "rc=$rc"')"
    [[ "$out" == *"rc=0"* && "$out" == *"install with defaults"* ]] && ok "$shell: no partition is not an error" || bad "$shell: no partition is not an error" "$out"

    # 4. partition present but empty
    rm -rf "$T"; T="$(mktemp -d)"; setup "$T"; make_sd "$T"; make_emmc "$T"
    out="$(run_case "$shell" "$T" 'find_sidecar || true; rc=0; copy_sidecar || rc=$?; echo "rc=$rc"')"
    [[ "$out" == *"rc=0"* && "$out" == *"no settings files"* ]] && ok "$shell: empty partition is not an error" || bad "$shell: empty partition is not an error" "$out"

    # 5. eMMC boot partition never appears -> failure reported
    rm -rf "$T"; T="$(mktemp -d)"; setup "$T"; make_sd "$T" bobcat-install.conf; : > "$T/dev/mmcblk0"
    out="$(run_case "$shell" "$T" 'find_sidecar || true; rc=0; copy_sidecar || rc=$?; echo "rc=$rc"')"
    [[ "$out" == *"rc=1"* && "$out" == *"did not appear"* ]] && ok "$shell: missing eMMC partition is reported" || bad "$shell: missing eMMC partition is reported" "$out"

    # 6. eMMC boot partition cannot be mounted -> failure reported
    rm -rf "$T"; T="$(mktemp -d)"; setup "$T"; make_sd "$T" bobcat-install.conf; : > "$T/dev/mmcblk0"; : > "$T/dev/mmcblk0p1"
    out="$(run_case "$shell" "$T" 'find_sidecar || true; rc=0; copy_sidecar || rc=$?; echo "rc=$rc"')"
    [[ "$out" == *"rc=1"* && "$out" == *"cannot mount"* ]] && ok "$shell: unmountable eMMC partition is reported" || bad "$shell: unmountable eMMC partition is reported" "$out"

    # 7. a partition 7 on the eMMC itself is never taken for the SD card
    rm -rf "$T"; T="$(mktemp -d)"; setup "$T"; make_emmc "$T"; : > "$T/dev/mmcblk0p7"; mkdir -p "$T/dev/mmcblk0p7.d"; printf x > "$T/dev/mmcblk0p7.d/bobcat-install.conf"
    out="$(run_case "$shell" "$T" 'find_sidecar || true; echo "found=$SIDECAR_MOUNTED"')"
    [[ "$out" == *"found=0"* ]] && ok "$shell: the eMMC's own partition 7 is ignored" || bad "$shell: the eMMC's own partition 7 is ignored" "$out"

    rm -rf "$T"
done

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[[ "$failed" -eq 0 ]]
