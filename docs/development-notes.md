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
