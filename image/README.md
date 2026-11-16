# Self-installing images

Two images are built here. Both add the installer and a first-boot service to
the community Bobcat Armbian image, and neither contains any settings or
secrets: your Wi-Fi, network, system and radio settings travel in a separate
file that you place next to the image when you flash it.

| Image | Use it when |
|---|---|
| **Flasher** (`bobcat-g295-flasher.img.xz`) | normal case. It is the community eMMC flasher: boot the Bobcat from this SD card and it writes the OS to the internal storage, **copying your settings file across**. Recommended for G290/G295. |
| **Standalone SD** (`bobcat-g295-reticulum.img.xz`) | the OS runs from the SD card itself, nothing is written to the eMMC. |

## Using the flasher (recommended)

1. **Make your settings file.** `python3 tools/make-config.py` asks a few
   questions, checks the answers with the installer's own validator, and writes
   `bobcat-install.conf`. Or copy
   [`firstboot/bobcat-install.conf.example`](firstboot/bobcat-install.conf.example)
   and edit it ([reference](../docs/config-reference.md)). Every setting is
   optional. With Wi-Fi in the file **no network cable is needed**; without any
   file the install still works with defaults but needs a wired network.
2. **Write the image to an SD card** (8 GB or larger) the normal way, then **drop
   the file on it**:
   ```
   xz -dc bobcat-g295-flasher.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
   ```
   The card now has a small FAT partition at the end, **BOBCFG**, which Windows,
   macOS and Linux all mount (re-plug the card if it does not appear). Copy
   `bobcat-install.conf` onto it, with exactly that name, plus any of the optional
   files listed in the README on that drive. On a card larger than the image,
   Linux may log that the backup partition table is not at the end of the disk;
   that is harmless, the partitions are read from the primary table.
   **Windows and macOS:** the card also holds partitions they cannot read (the
   bootloader area and an ext4 root). **Never accept an offer to format or
   initialise those**; only the BOBCFG drive is yours to write to. Very old Windows
   versions show only a card's first partition, in which case use Linux (or any
   machine that shows BOBCFG) to add the file.
3. **Flash:** power the Bobcat off, put the card in, power on. The LEDs stay on
   while it writes (a few minutes; the community flasher says up to ten). Do not
   interrupt it. **This erases the internal storage.**
4. **Done flashing:** the LEDs flash quickly in a repeating pattern, as with the
   community flasher. A **slow, even blink** instead means the OS was written but
   the settings could not be copied (see below). Power off and remove the card.
   **The Wi-Fi network must have internet access.** The install downloads packages
   (apt, PyPI), may fetch SSH keys from GitHub, and syncs the clock. A network that
   only reaches your local network (an isolated IoT VLAN, for example) lets the unit
   join but not install. The installer checks first and stops with a clear message
   before changing anything; first boot retries every two minutes, so fixing the
   network is enough. Once installed, a node runs without internet access.
5. **First boot** from the eMMC: the system waits for the clock to sync, then
   installs the node (several minutes, using the network from your settings) and
   starts the Reticulum service. Follow it with `journalctl -u bobcat-firstboot -f`
   or `/var/log/bobcat-firstboot.log`. A failed attempt retries every two minutes,
   up to five times an hour.

### What the flasher does with your settings
- Before writing, it looks for partition 7 (`BOBCFG`) on the SD card.
- After writing, it re-reads the eMMC partition table, mounts the new system's boot
  partition, and copies these files from `BOBCFG`: `bobcat-install.conf`,
  `bobcat-netplan.yaml`, `bobcat-authorized_keys`, `bobcat-reticulum.conf`. Each
  copy is compared byte for byte.
- The files stay on your SD card. Delete them if the card is shared.
- The first boot moves them into the installed system under `/etc/bobcat-lora/`
  (root-only) and clears `WIFI_PASS` and `IFAC_PASSPHRASE` from the copy on the
  FAT boot partition, which any computer could read.

If the slow blink shows: the OS is installed but the settings are not on it. Put
`bobcat-install.conf` on the unit's FAT boot partition (mount `/dev/mmcblk0p1` or
move the eMMC) before its first boot, or run the installer by hand afterwards.

## Using the standalone SD image
Write it like any SD image. Before the first boot put the same settings files on
its small FAT boot partition (label `armbi_boot`). It then installs itself the
same way.

## Building
In CI: **Actions → Build images → Run workflow**, or push a `v*` tag to build
both and attach them to a release. Locally (no root; needs `e2fsprogs`, `xz`,
`curl`, `python3`, and for the flasher `dosfstools` and `mtools`):

```
image/build-flasher.sh                  # -> dist/bobcat-g295-flasher.img.xz
image/build-image.sh                    # -> dist/bobcat-g295-reticulum.img.xz
image/build-flasher.sh --preload-config my.conf   # your own copy, settings pre-placed
```
`--preload-config` (and `build-image.sh --config`) put your settings inside the
image: use them only for a private image and never publish it.

## How the flasher is made
The community flasher is a tiny Linux on an SD card whose only job is
`dd`-ing a bundled OS image onto the eMMC. `build-flasher.sh` downloads it
(checksum-pinned), then, without root and entirely with `debugfs`:

1. replays the flasher filesystem's pending journal (see below);
2. extracts the OS image it carries, adds the installer and first-boot service,
   and puts it back;
3. replaces `/init.sh` with [`flasher/init.sh`](flasher/init.sh), which does what
   the original did plus the settings copy;
4. runs `e2fsck` to fix the counters `debugfs` leaves stale;
5. appends the 64 MiB FAT partition `BOBCFG` to the disk image
   ([`tools/gpt_tool.py`](tools/gpt_tool.py) rewrites both GPT headers) and
   formats it with a README and the example file.

The first 16 MiB of the disk (bootloader area) and the flasher's root filesystem
contents other than those files are byte-for-byte what the community published.

**Why the journal matters:** the community flasher's filesystem was shipped with
an unreplayed journal. `debugfs` writes metadata directly, and a later replay
(by `e2fsck` or at mount) would overwrite those edits. The build replays it
first and refuses to edit any filesystem that still has one
(`assert_clean_journal`).

## Status
Built and checked in CI: partition tables (two independent tools), FAT contents
and label, mounting, the settings writer, the first-boot and flasher scripts'
logic. **Not yet done on hardware:** flashing a Bobcat with the flasher image and
watching a first boot. The part most worth watching is the settings copy: the
flasher's BusyBox environment has no kernel modules, so FAT is mounted with the
kernel's built-in `cp437` character table; the kernel's own default table is a
module and would fail. The script tries `cp437`, `utf8`, `ascii` and the default
in turn and logs which one worked.
