<p align="center"><img src="docs/logo.svg" width="240" alt="Cat ears over a hammer and sickle in one circle"></p>

<h1 align="center">bobcat-reticulum-node</h1>

<p align="center"><img src="docs/tagline.svg" width="300" alt="The People's RNode"></p>

Turn a retired **Helium hotspot (Bobcat Miner 300, G290/G295)** into a
[Reticulum](https://reticulum.network/) LoRa node. The board's onboard **SX1302**
radio becomes one RNode-compatible channel (default 915 MHz, 125 kHz, SF8, CR 4/5).
Flash it from your browser over USB, with your settings in place, and the unit installs
the node itself and joins your network with nothing typed on the device.

> **Unofficial.** This project is not made by, affiliated with or endorsed by Bobcat,
> Bobber or Helium. It reuses hardware that is otherwise stranded.
>
> **Hardware at your own risk.** Never transmit without an antenna connected.
> TX power is capped at 16 dBm until you have measured your unit's real output.

## Convert a Helium node

### Web flasher (recommended): [bobcat.galaxyone.space](https://bobcat.galaxyone.space/)

One page makes your settings file and writes the OS image to the unit over USB. No SD card, no tools
to install. It runs in your browser (**Chrome or Edge**); your settings and the image never leave your
computer.

1. Open **[bobcat.galaxyone.space](https://bobcat.galaxyone.space/)** and fill in what you need: Wi-Fi
   (optional; Ethernet DHCP is the default), hostname, SSH keys for root or pasted in or pulled from GitHub,
   a root password (hashed in your browser), optionally a second user with sudo, and the radio settings.
   You can save the form in a cookie (passwords only if you tick the box).
2. Under **Flash over USB**, pick the image: the latest release of this project (the default), a file you
   already have, or a URL.
3. Connect the board's **OTG** USB port to your computer. Hold **Recovery**, press and release **Reset**,
   then let go of Recovery after about two seconds. Press *Connect* and choose *USB download gadget*.
4. The page writes the image's bootloader, the partition table and a small boot area, then restarts the board into fastboot. Press *Connect* again, choose the
   fastboot device, and press *Flash*. It writes the system, adds your settings file, and reboots.

First boot then installs the node by itself: the LED **blinks blue** while it installs, **turns steady red** if
there is no network (no address after about 20 seconds), **blinks red slowly** after a failed attempt, and turns
**green** when it is done and safe to power off.

Needs: Chrome, Edge or another Chromium browser. On Linux, a udev rule for the USB ids (the page shows
one); on Windows, the WinUSB driver for the two devices. How it works and its limits:
[`docs/usb-flashing.md`](docs/usb-flashing.md).

> **Status:** every step is tested against an emulated board and the underlying protocol was verified by
> hand on a real G295 and a G290, but the page itself has not yet flashed a unit end to end. A unit that
> still runs the factory firmware starts in Maskrom (not download mode); the page sends it a loader first
> (checked on a G290; see [`docs/usb-flashing.md`](docs/usb-flashing.md)).

### Alternative: an SD card

If you cannot use the web flasher: make the settings file on the same page (**Download**), or with the
questionnaire (`python3 tools/make-config.py`), or edit
[`image/firstboot/bobcat-install.conf.example`](image/firstboot/bobcat-install.conf.example) by hand
([reference](docs/config-reference.md)). Then:

1. Get `bobcat-g295-flasher.img.xz` from a release (or run **Actions → Build images**) and write it to an
   SD card:
   ```
   xz -dc bobcat-g295-flasher.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
   ```
   (or use any imaging tool). The card now has a small FAT partition, **BOBCFG**.
2. Copy `bobcat-install.conf` onto the card's **BOBCFG** drive, keeping the exact file name.
3. Put the card in the Bobcat and power on. It flashes its internal storage, copying your settings across.
   Three quick flashes mean it is done and the settings were copied (two slow flashes mean no settings were
   found); then power off and remove the card and power on again.

What the settings file can carry: Wi-Fi (2.4 GHz only, hidden SSIDs supported) or a
full [netplan](https://netplan.io/) config, the radio and Reticulum options, SSH public keys for root and
for an optional second user, pasted in or pulled from GitHub users, and the passwords as hashes.

**The network needs internet access** for the install (packages, clock, optional
GitHub keys); a network that only reaches the local network cannot install a node, and
the installer says so before changing anything. A running node does not need internet.

**This erases the Bobcat's internal storage.** Details, the standalone SD variant and
how the SD flasher works: [`image/README.md`](image/README.md).

Afterwards, on the unit:

```
/opt/bobcat-lora/venv/bin/rnstatus --config /etc/reticulum
/opt/bobcat-lora/venv/bin/rnpath --config /etc/reticulum -t
journalctl -u rnsd-sx1302 -f
/opt/bobcat-lora/venv/bin/python /opt/bobcat-lora/bobcat-g295/announce_test.py "hello" /etc/reticulum
```

## How it works

The SX1302 is a LoRaWAN gateway chip, normally used through a packet
forwarder. Here `sx1302_rns` drives it directly through Semtech's HAL as a single raw-LoRa
channel inside Reticulum. Because RNode firmware puts a one-byte header on every
frame, the interface adds and strips that byte so ordinary RNodes can
talk to it. The radio's SPI bus is the stock community kernel's bit-banged
`spi5`; the reset line is GPIO4_21. Details and evidence: `docs/hardware-notes.md`.

**Self-recovery** is on by default: logs survive a hard reset, a hardware watchdog resets
the board if it hangs, and a network watchdog restarts Wi-Fi and, as a last resort, reboots
when the network stays dead. See [`docs/self-recovery.md`](docs/self-recovery.md).

Limits you should know about: the SX1302 cannot receive 62.5 kHz LoRa, so it
cannot join networks that require it; and Wi-Fi on this board is 2.4 GHz only.

## Repository layout

| Path | What |
|---|---|
| `installer/` | the self-extracting installer (template + builder) |
| `image/` | first-boot service, flasher and image builders, partition tool |
| `site/` | the web page: config generator and WebUSB flasher (static, published with GitHub Pages) |
| `tools/` | `make-config.py` (questionnaire that writes your `bobcat-install.conf`) and `usb-flash/` (builds the temporary fastboot boot area) |
| `test/` | tests for the web page (generator, hashing, flasher modules) |
| `bobcat-g295/` | board profile, reset script, announce test, netplan examples |
| `sx1302_rns/` | the Reticulum SX1302 interface (a modified copy of an MIT project) plus the vendored Semtech HAL |
| `docs/` | `config-reference.md` (all settings), `usb-flashing.md`, `hardware-notes.md`, `self-recovery.md`, `maskrom-recovery.md`, `development-notes.md` |
| `.github/workflows/` | CI and the image build |

## Building (CI)

Everything is built in GitHub Actions:

- **CI** (`ci.yml`): shellcheck, the Python test suite (including a HAL ABI
  check that compiles the vendored C code), the first-boot script tests, the web page's tests
  (generator, password hashing, flasher modules against emulated boards) and the
  installer bundle (uploaded as an artifact).
- **Config generator** (`pages.yml`): tests the page, builds the fastboot boot area, copies the latest
  release image next to the page (GitHub's release downloads cannot be read by a web page) and publishes it.
- **Build images** (`build-image.yml`): downloads the community base image
  (checksum-pinned), patches it with `debugfs`, runs a filesystem check, and
  uploads or releases the result. Push a `v*` tag for a release.

Locally: `installer/build-installer.sh` and `image/build-image.sh` are what the
workflows run.

## Status

| | |
|---|---|
| Verified on a real unit | the USB protocol steps the web flasher uses (download mode write, fastboot write past 32 MiB, whole-image write and first boot); TX/RX with another node through Reticulum; service starts at boot; installer re-runs; radio-setting flags; Wi-Fi (hidden SSID) and Ethernet through netplan |
| Tested in CI / locally only | the web flasher's code against emulated boards; password hashing against openssl; the settings parser and every validation (dry run); first-boot and flasher script logic (bash and dash); image and flasher patching, partition tables, FAT and mounts; the Wi-Fi shortcut's file generation and the auto-revert mechanism |
| **Known problem** | the flasher card is not guaranteed to boot on a unit that already runs this system (it booted the eMMC and ignored the card); see [`image/README.md`](image/README.md#re-flashing-a-unit-that-already-runs-this-system-known-problem). Do not wipe the eMMC bootloader to force it: that left a unit in USB Maskrom mode; recovery notes: [`docs/maskrom-recovery.md`](docs/maskrom-recovery.md) |
| **Not tested** | the web flasher page on a real unit end to end; the flasher's settings copy inside its BusyBox environment (the first flash found no settings; the v0.2.2 scan and log are untested on hardware); the Wi-Fi shortcut joining a brand-new network; PXE / network install and MAAS (research only; the bootloader has no EFI) |

## Credits and licenses

MIT for this repository's own code. Includes a modified copy of
[shvelo/sx1302_rns](https://github.com/shvelo/sx1302_rns) (MIT) and an unmodified
copy of Semtech's [sx1302_hal](https://github.com/Lora-net/sx1302_hal) (BSD). The
Armbian image comes from [sicXnull/Bobcat-Armbian](https://github.com/sicXnull/Bobcat-Armbian)
and is downloaded at build time, never stored here. See [`NOTICE.md`](NOTICE.md).

---

## Footnote: a unit already running the community image

If a unit already runs the community Armbian image you do not need to reflash it. Get `bobcat-g295-install.sh` from the latest CI run (Actions → CI → artifact
`bobcat-g295-install`) or a release, then on the unit (as root, with internet):

```
scp bobcat-g295-install.sh root@<bobcat>:
ssh root@<bobcat> ./bobcat-g295-install.sh
```

It checks the board, installs a few packages (never `apt upgrade`; the kernel
and bootloader packages are held), builds the radio HAL, creates a Python
venv with Reticulum, writes `/etc/reticulum/config`, and installs and starts
the `rnsd-sx1302` service. Re-running is safe.

Everything can also come from one settings file (`--config FILE`, see
[`docs/config-reference.md`](docs/config-reference.md)); options override the
file. `--dry-run` validates it and shows the plan and generated configs without
changing anything:

```
./bobcat-g295-install.sh --dry-run --config my.conf
./bobcat-g295-install.sh --config my.conf
```

Common options (all in `--help`):

```
# match the other nodes on your network
./bobcat-g295-install.sh --frequency 915000000 --bandwidth 125000 --spreadingfactor 8 --codingrate 5

# join Wi-Fi (2.4 GHz only) first; prefer a file over putting the secret on the command line
./bobcat-g295-install.sh --wifi-ssid MyNet --wifi-pass-file /root/pw [--wifi-hidden]

# or your own netplan config
./bobcat-g295-install.sh --netplan-file my-netplan.yaml

# do not repeat other nodes' traffic
./bobcat-g295-install.sh --no-transport
```

Network changes are validated in a scratch directory first and applied under an
automatic revert timer, so a bad config cannot lock you out for good.

Afterwards:

```
/opt/bobcat-lora/venv/bin/rnstatus --config /etc/reticulum
/opt/bobcat-lora/venv/bin/rnpath --config /etc/reticulum -t
journalctl -u rnsd-sx1302 -f
/opt/bobcat-lora/venv/bin/python /opt/bobcat-lora/bobcat-g295/announce_test.py "hello" /etc/reticulum
```
