# Bobcat Miner 300 (G290/G295) hardware notes

Facts established while bringing up the onboard LoRa radio. "Verified" means
observed on a running unit; "from the DTB" means read from the community image's
device tree but not otherwise checked.

## Platform
- SoC Rockchip RK3566, 2 GB RAM, 64 GB eMMC; board id `bobcat,29x`.
- Community image: Armbian bookworm, kernel 6.18.x (`rk3566-bobcat.dtb`). The
  kernel, DTB and U-Boot packages must stay held: upgrading them breaks boot.
- No battery-backed clock. `fake-hwclock` restores a stale time at boot and
  `chrony` corrects it, so anything using TLS at first boot must wait for sync.
- Wi-Fi: Broadcom BCM43430 over SDIO, **2.4 GHz only**. Network is managed by
  NetworkManager; netplan is installed and renders to it.
- `libgpiod` is v1.6.3 (no v2 in bookworm), so scripts must support both.

## LoRa radio (SX1302 + SX1250)
| Item | Value | Status |
|---|---|---|
| SPI device | `/dev/spidev5.0` | verified |
| What "spi5" is | a bit-banged `spi-gpio` bus (bus-num 5, 2 MHz max) already enabled in the stock DTB. No overlay is needed. | from the DTB; device node verified |
| SPI pins | SCK GPIO3_19, MOSI GPIO3_17, MISO GPIO3_18, CS0 GPIO3_1, CS1 GPIO3_2 | from the DTB |
| Reset | GPIO4_21 = gpio4 line 21 (global 149), **active high** | verified (chip answers after the pulse) |
| LoRa 3.3 V enable | GPIO3_25, already driven high | verified (live pin read) |
| Chip id | `0x10` (SX1302 v1.0) | verified |
| PA enable | unknown. A third party documents GPIO4_19 (147). It is not driven by anything here. | unverified |
| Temperature sensor | none on I2C; the HAL is patched to continue without it | verified |

`dmesg` shows `lora-3v3-regulator: deferred probe pending` (-517). The DTB's
`vin-supply` phandle points at a pinctrl node, so the regulator never
registers. It is harmless because the enable pin is already high.

## What the SX1302 can and cannot do
- It demodulates LoRa at **125/250/500 kHz** only. It cannot receive 62.5 kHz,
  so it cannot join networks that use 62.5 kHz (for example the common
  MeshCore US preset). RNode-style single-channel use at 125 kHz works.
- The shipped TX gain table is borrowed from a RAK2287 profile and capped at
  16 dBm. Measure real output before raising it.

## RNode interoperability
RNode firmware adds one header byte to every LoRa frame: the upper nibble is a
random sequence number, bit 0 is "split packet". The interface adds and strips
it (`sx1302_rns/sx1302_reticulum/rnode_framing.py`) and uses the private LoRa
sync word, which the HAL sets. Verified on air against a real node in both
directions with Reticulum announces.

## Bootloader (U-Boot)
Read from the packaged `u-boot.itb` and its defconfig:
- Has Ethernet (`DWC_ETH_QOS`, `GMAC_ROCKCHIP`), `dhcp`, `pxe`, `nfs`, `booti`,
  `source`.
- Boot order: `usb0 mmc1 nvme0 nvme1 mmc0 mtd2 mtd1 mtd0 pxe dhcp`. Network boot
  only happens when nothing earlier is bootable (or you run `bootcmd_pxe` by
  hand on the serial console).
- **`EFI_LOADER` is not set**: no `bootefi`, so UEFI/GRUB-EFI images cannot run.

## The community eMMC flasher
Downloaded and inspected (not run). It is an SD card image: a GPT disk with a
`uboot` partition (4 MiB at 8 MiB), `misc` (4 MiB), and a 3.1 GiB ext4 `rootfs`
(partition 6) that holds `/init.sh`, a static BusyBox and the full OS disk image.
`/init.sh` runs as PID 1, mounts proc/sys/dev, `dd`s the OS image to
`/dev/mmcblk0` (the eMMC), then blinks the LEDs (GPIOs 128-130) forever.
- No kernel and no modules are in its filesystem. It evidently boots the kernel
  already on the unit, so the kernel's built-in features are all it has.
- BusyBox applets present include `mount`, `cat`, `cmp`, `sed`, `grep`, `mkdir`,
  `losetup`, `partprobe`, `blockdev`, `sha256sum`, `tar`; there is **no `cp`**.
- The Bobcat kernel has FAT/VFAT built in, but its default `iso8859-1` character
  table is a module, so mounting FAT there needs `-o iocharset=cp437` (built in).
- The flasher's root filesystem was shipped with an **unreplayed ext4 journal**
  and the `orphan_present` flag.
- The OS image it carries is not byte-identical to the standalone community
  image: it differs in a handful of 1 MiB regions (boot partition scripts and a
  few root-filesystem blocks), so the flasher variant must patch the flasher's
  own copy.

## Verified / not verified
| Verified on hardware | Not verified |
|---|---|
| TX and RX with another node, through Reticulum | Flashing the built image to a unit and its first-boot run |
| `rnsd-sx1302` starts at boot and owns the radio | Wi-Fi shortcut against a new SSID (generation, validation and apply were tested separately) |
| Installer re-runs (idempotent), radio-setting flags | Auto-revert triggering from a real connectivity loss |
| netplan Wi-Fi (hidden SSID) and Ethernet | Running the new flasher on a unit: the settings copy in its BusyBox environment, then the first boot |
| netplan Wi-Fi (hidden SSID) and Ethernet | PXE / network install, MAAS (not built; the bootloader has no EFI) |
