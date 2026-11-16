# Development notes and gotchas

Things learned while building this, kept because each one cost time.

## Radio / HAL
- The community kernel exposes the radio as `/dev/spidev5.0`; there is no
  hardware SPI5 on the RK3566. It is a bit-banged `spi-gpio` bus declared in
  the DTB, so no overlay is needed (and `armbianEnv.txt` overlays are ignored
  anyway: the boot script loads the DTB directly).
- The SX1302 reset must be driven before the HAL opens SPI. The interface runs
  `reset_bobcat_g295.sh` on start and stop. The script finds the right
  `gpiochip` by label because chip numbers depend on probe order.
- The image ships libgpiod v1; v2 is not in bookworm. The script handles both.
- No temperature sensor is present. Semtech's HAL aborts without one, so a
  small patch (`sx1302_rns/patches/`) lets it carry on.
- RNode framing needs the HAL payload limit raised from 254 to 255 bytes.

## Reticulum
- **Never start a Reticulum client (`rnstatus`, an announce script) before
  `rnsd` is up.** The first process becomes the shared instance, takes the
  radio, and the real daemon attaches to it as a client. The installer waits
  for the service's own "interface online" log line first.
- `enable_transport = yes` makes the node repeat announces it hears, which
  doubles the airtime of every announce. It is the installer's default; use
  `--no-transport` to turn it off.

## Networking
- `netplan set` in 0.106 fails with "Duplicate access point SSID" when the SSID
  is already defined. Edit the file instead. Netplan also rejects the same SSID
  in two files.
- A hidden SSID never appears in a scan, and NetworkManager will not try it
  until the profile says `hidden: true`.
- The Wi-Fi chip is 2.4 GHz only.
- `netplan apply` does not remove virtual devices or always the in-memory
  NetworkManager profile of a deleted definition; the revert script prunes
  stale `netplan-*` profiles.
- The NetworkManager backend ignores `dhcp-identifier` and renders IPv6 as
  `ignore` even with `accept-ra`.
- Switching the Ethernet profile that carries your SSH session can change the
  DHCP lease. Arm a timer first (`systemd-run --on-active=240 ...`) and switch
  from a detached job.
- A remote `pkill -f <pattern>` can kill your own SSH shell when the pattern
  appears in its command line; use `pgrep -f '[b]in/rnsd'`-style patterns.

## Image / first boot
- There is no battery-backed clock. After a power cycle the time is stale until
  `chrony` syncs, which breaks TLS (apt, pip). First boot waits for sync.
- `unattended-upgrades` is enabled in the base image; the kernel, DTB and
  U-Boot packages are held first thing so it cannot replace them.
- The base image's boot script loads `rk3566-bobcat.dtb` directly and ignores
  the `fdtfile` line in `armbianEnv.txt`.

## Editing ext4 images without root
- `debugfs -w image?offset=N` edits a filesystem inside a disk image. Read-only
  `debugfs` and `e2fsck -fn` accept the same syntax. **`dumpe2fs` does not on
  every version** (1.47.2 fails with "Unable to resolve '-h'"), so superblock
  facts come from `debugfs -R "stats -h"`.
- **`e2fsck -fy` does not work through `?offset=`**: after replaying the journal
  it re-opens the file by plain name and fails. Extract the partition, repair it,
  write it back (`repair_partition` in `image/lib.sh`).
- **Never edit a filesystem that has an unreplayed journal.** `debugfs` writes
  metadata directly; replaying the journal afterwards (at mount, or by e2fsck)
  overwrites those edits with older logged blocks. The community flasher's
  filesystem has one. Replay first, then edit; `assert_clean_journal` enforces it.
- Removing and rewriting a multi-gigabyte file with `debugfs` leaves the
  free-block counters stale; fix with an `e2fsck -fy` pass once the journal is clean.
- Appending a GPT partition to an image means growing the file, rewriting both
  headers and the entry array with correct CRCs, and clearing the old backup
  header that is now in the middle of the disk (`image/tools/gpt_tool.py`).
- A BusyBox-only environment has no `cp`; copy with `cat src > dst` and compare
  with `cmp`.

## Settings
- Settings parsing lives in one place (the installer). The first boot only
  merges files and passes `--config`, and `--dry-run` makes the whole thing
  testable without hardware.
- Values in the settings file are literal. Do not try to escape quotes; a
  passphrase can contain `"` and `$(...)` safely because nothing is evaluated.
- Do not hide a tool's stderr inside a `set -o pipefail` pipeline: a failure
  there ends the script with no message. Capture output into a variable and
  report it (`super_info` in `image/lib.sh`). `grep -q` at the end of a pipe can
  also close it early and make the left side look like it failed (SIGPIPE).
