# Self-installing image

`build-image.sh` takes the community Bobcat Armbian image for the G290/G295 and
adds two things to its root filesystem:

- the installer bundle (`/usr/local/share/bobcat-lora/bobcat-g295-install.sh`);
- a one-shot systemd service, `bobcat-firstboot`, that runs it on first boot
  once the network is up and the clock is synchronized.

Nothing else changes. The partition table, the boot partition and the rest of
the disk are byte-identical to the base image (checked when this was written).

## Build

In CI: **Actions → Build image → Run workflow**. Push a tag such as `v1.0.0`
to also attach the image to a release.

Locally (no root needed; `e2fsprogs`, `xz`, `curl`, `python3` required):

```
image/build-image.sh                    # -> dist/bobcat-g295-reticulum.img.xz
image/build-image.sh --config my.conf   # bake Wi-Fi etc. into the image
```

A baked config puts secrets inside the image. Never publish such an image.

## Use

1. Write the `.img.xz` where you would write the community image, following the
   community instructions for your unit. This image is a drop-in replacement
   for `BobcatArmbian29x.img`.
2. Optional: before first boot, put a `bobcat-install.conf` on the small FAT
   partition (label `armbi_boot`) of the card. Start from
   [`firstboot/bobcat-install.conf.example`](firstboot/bobcat-install.conf.example).
   A complete netplan file named `bobcat-netplan.yaml` there is also accepted.
3. Power on with Ethernet connected (or Wi-Fi settings in the file). First boot
   waits for the clock to sync, then installs. Watch it with
   `journalctl -u bobcat-firstboot -f` or read `/var/log/bobcat-firstboot.log`.
   A failed attempt is retried every two minutes, up to five times an hour.

When it finishes, `/var/lib/bobcat-lora/firstboot.done` exists and the
`rnsd-sx1302` service is running.

## Settings (`bobcat-install.conf`)

`KEY=value` lines; the file is parsed, never executed, and only these keys are
read: `WIFI_SSID WIFI_PASS WIFI_HIDDEN WIFI_OPEN FREQUENCY BANDWIDTH
SPREADINGFACTOR CODINGRATE TXPOWER TRANSPORT AUTOINTERFACE SCRUB_BOOT_CONF`.
The Wi-Fi passphrase is passed to the installer through a mode-600 temporary
file, and is blanked in the FAT-partition copy after a successful install
unless `SCRUB_BOOT_CONF=no`.

## Status

The build, the filesystem check and the first-boot script's logic are tested in
CI and locally. **The built image has not been flashed to a unit yet**; the
installer it carries is the one verified on hardware.
