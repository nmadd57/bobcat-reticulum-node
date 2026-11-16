<p align="center"><img src="docs/logo.svg" width="240" alt="Cat ears over a hammer and sickle in one circle"></p>

<h1 align="center">bobcat-reticulum-node</h1>

<p align="center"><img src="docs/tagline.svg" width="300" alt="The People's RNode"></p>

Turn a retired **Helium hotspot (Bobcat Miner 300, G290/G295)** into a
[Reticulum](https://reticulum.network/) LoRa node. The board's onboard **SX1302**
radio becomes one RNode-compatible channel (default 915 MHz, 125 kHz, SF8, CR 4/5).
You write one SD card, drop in one settings file, and power on: the unit flashes
itself, installs the node and joins your Wi-Fi with nothing typed on the device.

> **Unofficial.** This project is not made by, affiliated with or endorsed by Bobcat,
> Bobber or Helium. It reuses hardware that is otherwise stranded.
>
> **Hardware at your own risk.** Never transmit without an antenna connected.
> TX power is capped at 16 dBm until you have measured your unit's real output.

## Convert a Helium node in five steps

Your Wi-Fi, network, system and radio settings go in a small file that you drop on
the SD card next to the image, so nothing secret is baked into it and no network cable
is needed.

1. Get `bobcat-g295-flasher.img.xz` from a release (or run **Actions → Build images**).
2. Make your settings file with the [**web config generator**](https://bobcat.galaxyone.space/)
   (it runs in your browser; nothing is sent anywhere), or with the questionnaire (or edit
   [`image/firstboot/bobcat-install.conf.example`](image/firstboot/bobcat-install.conf.example)
   by hand; [reference](docs/config-reference.md)):
   ```
   python3 tools/make-config.py          # asks questions, checks the answers, writes bobcat-install.conf
   ```
3. Write the image to an SD card like any other image:
   ```
   xz -dc bobcat-g295-flasher.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
   ```
   (or use any imaging tool). The card now has a small FAT partition, **BOBCFG**.
4. Copy `bobcat-install.conf` onto the card's **BOBCFG** drive (re-plug the card if
   it does not show up). Keep the exact file name.
5. Put the card in the Bobcat and power on. It flashes its internal storage, copying
   your settings across; when the LEDs flash quickly, power off and remove the card.
   Power on again: first boot installs the node by itself and joins your Wi-Fi.

What the settings file can carry: Wi-Fi (2.4 GHz only, hidden SSIDs supported) or a
full [netplan](https://netplan.io/) config, the radio and Reticulum options, and SSH
public keys for root, pasted in or pulled from a GitHub user.

**The Wi-Fi network needs internet access** for the install (packages, clock, optional
GitHub keys); a network that only reaches the local network cannot install a node, and
the installer says so before changing anything. A running node does not need internet.

**This erases the Bobcat's internal storage.** Details, the standalone SD variant and
how it works: [`image/README.md`](image/README.md).

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
| `tools/` | `make-config.py`: questionnaire that writes your `bobcat-install.conf` |
| `site/` | the web config generator (static page, published with GitHub Pages) |
| `bobcat-g295/` | board profile, reset script, announce test, netplan examples |
| `sx1302_rns/` | the Reticulum SX1302 interface (a modified copy of an MIT project) plus the vendored Semtech HAL |
| `netboot/`, `maas/` | PXE / MAAS design notes (experimental) |
| `docs/` | `config-reference.md` (all settings), `hardware-notes.md`, `development-notes.md` |
| `.github/workflows/` | CI and the image build |

## Building (CI)

Everything is built in GitHub Actions:

- **CI** (`ci.yml`): shellcheck, the Python test suite (including a HAL ABI
  check that compiles the vendored C code), the first-boot script tests, and the
  installer bundle (uploaded as an artifact).
- **Build image** (`build-image.yml`): downloads the community base image
  (checksum-pinned), patches it with `debugfs`, runs a filesystem check, and
  uploads or releases the result. Push a `v*` tag for a release.

Locally: `installer/build-installer.sh` and `image/build-image.sh` are what the
workflows run.

## Status

| | |
|---|---|
| Verified on a real unit | TX/RX with another node through Reticulum; service starts at boot; installer re-runs; radio-setting flags; Wi-Fi (hidden SSID) and Ethernet through netplan |
| Tested in CI / locally only | the settings parser and every validation (dry run); first-boot and flasher script logic (bash and dash); image and flasher patching, partition tables, FAT and mounts; the Wi-Fi shortcut's file generation and the auto-revert mechanism |
| **Not tested** | flashing a unit with the built flasher and its first boot (including the settings copy inside the flasher's BusyBox environment); the Wi-Fi shortcut joining a brand-new network; PXE / network install and MAAS (design only, with a blocker: the bootloader has no EFI) |

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
