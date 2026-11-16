#!/usr/bin/env bash
# Shared helpers for the image builders (sourced, not run).

log()  { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

need_tools() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || fail "missing tool: $tool"
    done
}

# download_verified URL SHA256 DESTFILE   (SHA256 "skip" disables the check)
download_verified() {
    local url="$1" sha="$2" dest="$3"
    if [[ ! -f "$dest" ]]; then
        note "downloading $url"
        curl -fL --retry 3 -o "$dest.part" "$url"
        mv "$dest.part" "$dest"
    fi
    if [[ "$sha" != "skip" ]]; then
        local actual
        actual="$(sha256sum "$dest" | cut -d' ' -f1)"
        [[ "$actual" == "$sha" ]] ||
            fail "checksum mismatch for $dest (expected $sha, got $actual); delete it to re-download"
        note "checksum ok: $(basename "$dest")"
    fi
}

# gpt_partition IMAGE NAME  -> prints "<byte offset> <byte size>" of the named partition
gpt_partition() {
    python3 -I - "$1" "$2" <<'PY'
import struct, sys
path, want = sys.argv[1], sys.argv[2]
with open(path, "rb") as f:
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
        if name == want:
            print(first * 512, (last - first + 1) * 512)
            sys.exit(0)
sys.exit(f"no partition named {want}")
PY
}

# super_info FS_SPEC
#
# Prints the superblock summary (dumpe2fs -h). Captured into a variable first, so
# there is no pipe to be closed early, and a failure shows dumpe2fs's own message
# instead of vanishing. The exit status is not trusted, only whether a superblock
# came out.
super_info() {
    local out
    out="$(dumpe2fs -h "$1" 2>&1)" || true
    if ! grep -q '^Filesystem features:' <<<"$out"; then
        printf '%s\n' "$out" | tail -5 >&2
        fail "dumpe2fs could not read the filesystem at $1"
    fi
    printf '%s\n' "$out"
}

# has_pending_journal FS_SPEC   (status 0 = a journal still has to be replayed)
has_pending_journal() {
    local info feats start
    info="$(super_info "$1")" || return 2
    feats="$(sed -n 's/^Filesystem features: *//p' <<<"$info")"
    start="$(sed -n 's/^Journal start: *//p' <<<"$info")"
    [[ " $feats " == *" needs_recovery "* || ( -n "$start" && "$start" != "0" ) ]]
}

# assert_clean_journal FS_SPEC
#
# debugfs writes metadata directly. If the filesystem still has an unreplayed
# journal, the next mount (or fsck) replays it OVER those changes and silently
# undoes them. Refuse to edit such a filesystem.
assert_clean_journal() {
    local rc=0
    has_pending_journal "$1" || rc=$?
    [[ "$rc" -ne 2 ]] || exit 1
    if [[ "$rc" -eq 0 ]]; then
        fail "the filesystem has an unreplayed journal; editing it would be undone at mount (needs_recovery set)"
    fi
}

# repair_partition IMAGE OFFSET SIZE LOGFILE
#
# Runs e2fsck -fy on an extracted copy of the partition (it cannot repair through
# the ?offset= syntax) and writes the result back. Replays any journal and fixes
# stale counters. Must be run BEFORE editing with debugfs when a journal is
# pending, and may be run after to fix counters once the journal is clean.
repair_partition() {
    local img="$1" off="$2" size="$3" log="$4" part rc=0
    part="$WORK/repair.part"
    dd if="$img" of="$part" bs=4M iflag=skip_bytes,count_bytes skip="$off" count="$size" status=none
    e2fsck -fy "$part" > "$log" 2>&1 || rc=$?
    [[ "$rc" -le 1 ]] || { tail -15 "$log" >&2; rm -f "$part"; fail "e2fsck could not repair the filesystem (exit $rc)"; }
    e2fsck -fn "$part" > "$log.check" 2>&1 || { tail -15 "$log.check" >&2; rm -f "$part"; fail "filesystem still not clean after repair"; }
    dd if="$part" of="$img" bs=4M oflag=seek_bytes seek="$off" conv=notrunc status=none
    rm -f "$part"
}

# patch_os_image IMAGE
#
# Adds the installer and the first-boot service to the root filesystem of an
# Armbian-based Bobcat disk image, in place, without root (debugfs).
# Needs: INSTALLER FIRSTBOOT UNIT WORK BUILD_REF BASE_DESC; optional BAKED_CONFIG.
patch_os_image() {
    local img="$1" off size fs stage cmds out
    read -r off size < <(gpt_partition "$img" rootfs) || fail "no rootfs partition in $img"
    fs="$img?offset=$off"
    note "rootfs at byte offset $off (size $size)"

    debugfs -R "stat /etc/os-release" "$fs" 2>&1 | grep -q "^Inode:" ||
        fail "cannot read the root filesystem of $img"
    assert_clean_journal "$fs"

    stage="$WORK/stage"
    mkdir -p "$stage"
    {
        echo "bobcat-reticulum-node image"
        echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "ref:   $BUILD_REF"
        echo "base:  $BASE_DESC"
    } > "$stage/BUILD_INFO"

    cmds="$WORK/debugfs.cmds"
    {
        echo "mkdir /usr/local/share/bobcat-lora"
        echo "write $INSTALLER /usr/local/share/bobcat-lora/bobcat-g295-install.sh"
        echo "write $stage/BUILD_INFO /usr/local/share/bobcat-lora/BUILD_INFO"
        echo "write $FIRSTBOOT /usr/local/sbin/bobcat-firstboot"
        echo "write $UNIT /etc/systemd/system/bobcat-firstboot.service"
        echo "symlink /etc/systemd/system/multi-user.target.wants/bobcat-firstboot.service ../bobcat-firstboot.service"
        if [[ -n "${BAKED_CONFIG:-}" ]]; then
            echo "mkdir /etc/bobcat-lora"
            echo "write $BAKED_CONFIG /etc/bobcat-lora/install.conf"
        fi
        local f
        for f in /usr/local/share/bobcat-lora /usr/local/share/bobcat-lora/BUILD_INFO \
                 /usr/local/share/bobcat-lora/bobcat-g295-install.sh /usr/local/sbin/bobcat-firstboot \
                 /etc/systemd/system/bobcat-firstboot.service \
                 /etc/systemd/system/multi-user.target.wants/bobcat-firstboot.service; do
            echo "set_inode_field $f uid 0"
            echo "set_inode_field $f gid 0"
        done
        echo "set_inode_field /usr/local/share/bobcat-lora/bobcat-g295-install.sh mode 0100755"
        echo "set_inode_field /usr/local/share/bobcat-lora/BUILD_INFO mode 0100644"
        echo "set_inode_field /usr/local/sbin/bobcat-firstboot mode 0100755"
        echo "set_inode_field /etc/systemd/system/bobcat-firstboot.service mode 0100644"
        if [[ -n "${BAKED_CONFIG:-}" ]]; then
            for f in /etc/bobcat-lora /etc/bobcat-lora/install.conf; do
                echo "set_inode_field $f uid 0"
                echo "set_inode_field $f gid 0"
            done
            echo "set_inode_field /etc/bobcat-lora mode 040700"
            echo "set_inode_field /etc/bobcat-lora/install.conf mode 0100600"
        fi
    } > "$cmds"

    out="$WORK/debugfs.out"
    debugfs -w -f "$cmds" "$fs" > "$out" 2>&1 || true
    # debugfs reports problems on stderr but still exits 0; scan for them.
    if grep -iE "(error|not found|already exists|invalid|cannot|no such)" "$out" | grep -qv "^debugfs [0-9]"; then
        grep -iE "(error|not found|already exists|invalid|cannot|no such)" "$out" >&2 || true
        fail "debugfs reported problems while patching (log: $out)"
    fi
}

# check_file IMAGE_FS LOCAL_FILE PATH_IN_IMAGE EXPECTED_MODE
check_file() {
    local fs="$1" local_file="$2" path="$3" want_mode="$4" want got mode
    want="$(sha256sum "$local_file" | cut -d' ' -f1)"
    got="$(debugfs -R "cat $path" "$fs" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "$want" == "$got" ]] || fail "content mismatch for $path"
    mode="$(debugfs -R "stat $path" "$fs" 2>/dev/null | sed -n 's/.*Mode: *\([0-7]*\).*/\1/p' | head -1)"
    [[ "$mode" == "$want_mode" ]] || fail "wrong mode for $path: $mode (want $want_mode)"
    note "ok  $path ($want_mode)"
}

# verify_os_image IMAGE [--skip-fsck]
verify_os_image() {
    local img="$1" off size fs link owner
    read -r off size < <(gpt_partition "$img" rootfs)
    fs="$img?offset=$off"

    check_file "$fs" "$INSTALLER" /usr/local/share/bobcat-lora/bobcat-g295-install.sh 0755
    check_file "$fs" "$FIRSTBOOT" /usr/local/sbin/bobcat-firstboot 0755
    check_file "$fs" "$UNIT" /etc/systemd/system/bobcat-firstboot.service 0644
    [[ -z "${BAKED_CONFIG:-}" ]] || check_file "$fs" "$BAKED_CONFIG" /etc/bobcat-lora/install.conf 0600

    link="$(debugfs -R "stat /etc/systemd/system/multi-user.target.wants/bobcat-firstboot.service" "$fs" 2>/dev/null |
        sed -n 's/.*Fast link dest: "\(.*\)".*/\1/p')"
    [[ "$link" == "../bobcat-firstboot.service" ]] || fail "service enable symlink is wrong: '$link'"
    note "ok  service enabled via multi-user.target.wants"

    owner="$(debugfs -R "stat /usr/local/sbin/bobcat-firstboot" "$fs" 2>/dev/null |
        sed -n 's/.*User: *\([0-9]*\).*Group: *\([0-9]*\).*/\1:\2/p' | head -1)"
    [[ "$owner" == "0:0" ]] || fail "wrong owner on the first-boot script: $owner"
    note "ok  owner root:root"

    if [[ "${2:-}" != "--skip-fsck" ]]; then
        note "checking the filesystem (e2fsck -fn)"
        e2fsck -fn "$fs" > "$WORK/e2fsck.out" 2>&1 || {
            tail -15 "$WORK/e2fsck.out" >&2
            fail "filesystem check failed (full output: $WORK/e2fsck.out)"
        }
        note "ok  filesystem clean"
    fi
}
