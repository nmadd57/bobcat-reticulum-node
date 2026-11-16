#!/bin/sh
#
# eMMC flasher init for the Bobcat Reticulum node.
#
# Same job as the community flasher's init script (write the bundled OS image
# to the eMMC, then blink the LEDs), plus one thing: before flashing it looks
# for a small FAT partition on the SD card (partition 7, label BOBCFG) and,
# after flashing, copies the settings files found there onto the eMMC's boot
# partition. The first boot of the new system then installs itself from them.
# The image itself contains no settings or secrets.
#
# Runs as PID 1 in a tiny BusyBox environment: no cp, no kernel modules. The
# kernel's FAT driver is built in, but its default iso8859-1 table is a module,
# so mounts try the built-in cp437 table first.
set -eu

# --- config ---
# Bobcat RGB (or multi-LED) GPIOs
GPIOS="128 129 130"

# Target eMMC (WHOLE DISK)
EMMC_DEV="${BOBCAT_EMMC_DEV:-/dev/mmcblk0}"

# OS image to flash (lives in this root filesystem)
IMAGE="Armbian-unofficial_26.02.0-trunk_Bobcat-29x_bookworm_current_6.18.4.img"

# Where things live (overridable for tests)
DEVDIR="${BOBCAT_DEV_DIR:-/dev}"
SD_MP="${BOBCAT_SD_MP:-/tmp}"
EMMC_MP="${BOBCAT_EMMC_MP:-/run}"

# Settings partition on the SD card and the files copied from it
SIDECAR_PART=7
SIDECAR_FILES="bobcat-install.conf bobcat-netplan.yaml bobcat-authorized_keys bobcat-reticulum.conf"

# --- helpers ---
is_block() { [ -b "$1" ]; }
die() { echo "ERROR: $*" >&2; exit 1; }
FLOG=""
log() {
  echo "flasher: $*"
  FLOG="$FLOG
flasher: $*"
}

mount_if_dir() {
  mp="$1"
  fstype="$2"
  src="$3"
  [ -d "$mp" ] && mount -t "$fstype" "$src" "$mp" 2>/dev/null || true
}

set_gpio() {
  gpio="$1"
  val="$2"

  [ -d /sys/class/gpio ] || return 0

  [ -e "/sys/class/gpio/gpio${gpio}" ] || echo "$gpio" > /sys/class/gpio/export 2>/dev/null || true
  [ -e "/sys/class/gpio/gpio${gpio}/direction" ] || return 0

  echo out > "/sys/class/gpio/gpio${gpio}/direction" 2>/dev/null || true
  echo "$val" > "/sys/class/gpio/gpio${gpio}/value" 2>/dev/null || true
}

all_gpios() {
  val="$1"
  for g in $GPIOS; do
    set_gpio "$g" "$val"
  done
}

# "Complete" pattern: quick flashes, pause, repeat
blink_done_forever() {
  while true; do
    all_gpios 0; sleep 0.15
    all_gpios 1; sleep 0.15
    all_gpios 0; sleep 0.15
    all_gpios 1; sleep 0.15
    all_gpios 0; sleep 0.15
    all_gpios 1; sleep 0.15
    all_gpios 0; sleep 1.0
  done
}

# Flashed, but NO settings were found on the SD card, so the node will install with
# defaults (and needs a network cable): two slow flashes, a pause, repeat.
blink_nosettings_forever() {
  while true; do
    all_gpios 1; sleep 0.7
    all_gpios 0; sleep 0.5
    all_gpios 1; sleep 0.7
    all_gpios 0; sleep 2.0
  done
}

# Flashed, but the settings could not be copied: slow, even blinking.
blink_warn_forever() {
  while true; do
    all_gpios 1; sleep 1
    all_gpios 0; sleep 1
  done
}

# try_mount DEV MOUNTPOINT ro|rw  -- vfat, trying character tables that exist
try_mount() {
  tm_dev="$1"
  tm_mp="$2"
  tm_mode="$3"
  for tm_opt in "iocharset=cp437" "iocharset=utf8" "iocharset=ascii" ""; do
    if [ -n "$tm_opt" ]; then tm_o="$tm_mode,$tm_opt"; else tm_o="$tm_mode"; fi
    if mount -t vfat -o "$tm_o" "$tm_dev" "$tm_mp" 2>/dev/null; then
      log "mounted $tm_dev on $tm_mp ($tm_o)"
      return 0
    fi
  done
  return 1
}

# True when the mounted partition at $SD_MP holds at least one settings file.
sidecar_has_files() {
  for shf in $SIDECAR_FILES; do
    if [ -f "$SD_MP/$shf" ]; then return 0; fi
  done
  return 1
}

# Look for the settings on the SD card. Partition 7 (label BOBCFG) is tried first, then
# every other partition of every device except the eMMC, so a different partition
# numbering in this kernel does not hide the file. The first one that mounts as FAT and
# holds a settings file wins; what was tried is logged.
SIDECAR_MOUNTED=0
find_sidecar() {
  fs_tried=""
  for fs_dev in "$DEVDIR"/mmcblk*p"$SIDECAR_PART" "$DEVDIR"/mmcblk*p[1-9] "$DEVDIR"/sd*[1-9]; do
    is_block "$fs_dev" || continue
    case "$fs_dev" in "${EMMC_DEV}"p*) continue ;; esac
    case " $fs_tried " in *" $fs_dev "*) continue ;; esac
    fs_tried="$fs_tried $fs_dev"
    if try_mount "$fs_dev" "$SD_MP" ro; then
      if sidecar_has_files; then
        SIDECAR_MOUNTED=1
        log "settings found on $fs_dev"
        return 0
      fi
      log "$fs_dev mounted but holds no settings files"
      umount "$SD_MP" 2>/dev/null || true
    else
      log "$fs_dev could not be mounted as FAT"
    fi
  done
  [ -n "$fs_tried" ] || log "no partition other than the eMMC's was found"
  return 1
}

# Wait for the partitions of the image we just wrote and mount its boot partition on
# $EMMC_MP read-write. Returns 1 (with a log line) if that cannot be done.
mount_emmc_boot() {
  # The kernel needs to see the partitions of the image we just wrote.
  blockdev --rereadpt "$EMMC_DEV" 2>/dev/null || partprobe "$EMMC_DEV" 2>/dev/null || true
  n=0
  while ! is_block "${EMMC_DEV}p1" && [ "$n" -lt 20 ]; do
    sleep 1
    n=$((n + 1))
  done
  if ! is_block "${EMMC_DEV}p1"; then
    log "ERROR: ${EMMC_DEV}p1 did not appear after flashing"
    return 1
  fi
  if ! try_mount "${EMMC_DEV}p1" "$EMMC_MP" rw; then
    log "ERROR: cannot mount the eMMC boot partition"
    return 1
  fi
  return 0
}

# Leave a record on the new system (/boot/bobcat-flasher.log) of what the flasher saw.
write_flasher_log() {
  { printf '%s\n' "$FLOG"
    if [ -r /proc/partitions ]; then echo "flasher: /proc/partitions:"; cat /proc/partitions; fi
  } > "$EMMC_MP/bobcat-flasher.log" 2>/dev/null || true
}

# After flashing: copy the settings files onto the eMMC's boot partition.
# Returns 0 when the settings were copied, 2 when there was nothing to copy (the node
# will install with defaults), 1 when copying failed.
copy_sidecar() {
  have_sidecar=0
  if [ "$SIDECAR_MOUNTED" = 1 ] && sidecar_has_files; then
    have_sidecar=1
  else
    log "no settings found on the SD card: the node will install with defaults"
  fi

  if ! mount_emmc_boot; then
    [ "$have_sidecar" = 1 ] && return 1
    return 2
  fi

  rc=0
  if [ "$have_sidecar" = 1 ]; then
    for f in $SIDECAR_FILES; do
      [ -f "$SD_MP/$f" ] || continue
      if cat "$SD_MP/$f" > "$EMMC_MP/$f" && sync && cmp "$SD_MP/$f" "$EMMC_MP/$f"; then
        log "copied $f to the eMMC"
      else
        log "ERROR: could not copy $f"
        rc=1
      fi
    done
  else
    rc=2
  fi
  write_flasher_log
  sync
  umount "$EMMC_MP" 2>/dev/null || true
  umount "$SD_MP" 2>/dev/null || true
  return "$rc"
}

main() {
  # Minimal PATH for init environments
  PATH=/sbin:/bin:/usr/sbin:/usr/bin
  export PATH

  # --- mount pseudo-fs (NO mkdir) ---
  mount_if_dir /proc proc proc
  mount_if_dir /sys  sysfs sysfs
  mount_if_dir /dev  devtmpfs devtmpfs

  # --- sanity checks ---
  [ -b "$EMMC_DEV" ] || die "Missing block device: $EMMC_DEV"
  [ -f "$IMAGE" ] || die "Missing image file: $IMAGE"

  # Find the settings on the SD card first, while nothing is being written.
  log "eMMC is $EMMC_DEV"
  if [ -r /proc/partitions ]; then
    log "devices: $(tr '\n' ';' < /proc/partitions | tr -s ' ')"
  fi
  find_sidecar || log "no settings found on the SD card"

  echo "Flashing full disk image to eMMC..."
  echo "  Image : $IMAGE"
  echo "  Target: $EMMC_DEV"
  echo "WARNING: This will ERASE all data on $EMMC_DEV."

  # LEDs ON during flash
  all_gpios 1

  # Flash whole image to eMMC.
  # No status=progress (some init environments / busybox dd don't support it).
  dd if="$IMAGE" of="$EMMC_DEV" bs=4M conv=fsync

  sync
  echo "Done flashing."

  rc=0
  copy_sidecar || rc=$?
  case "$rc" in
    0) blink_done_forever ;;
    2) log "flashed; NO settings were found, the node will install with defaults"
       blink_nosettings_forever ;;
    *) log "flashed, but the settings were NOT copied; put them on the eMMC boot partition by hand"
       blink_warn_forever ;;
  esac
}

if [ -z "${BOBCAT_FLASHER_NO_MAIN:-}" ]; then
  main
fi
