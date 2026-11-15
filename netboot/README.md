# Network boot (PXE): experimental design

**Status: not built, not tested.** This documents what the Bobcat's bootloader
can do and what is still missing. Nothing here has been run.

## What the bootloader supports
From the packaged U-Boot (see `docs/hardware-notes.md`): Ethernet, `dhcp`,
`pxe` (extlinux-style, served over TFTP), `booti`, and `source` for boot
scripts. There is no EFI loader.

Boot order is `usb0 mmc1 nvme0 nvme1 mmc0 mtd2 mtd1 mtd0 pxe dhcp`, so a unit
that has a bootable SD card or eMMC never reaches the network. To netboot:

- use a unit with a blank or non-bootable eMMC and no SD card, or
- interrupt U-Boot on the serial console (UART, 1,500,000 baud) and run
  `run bootcmd_pxe`.

## How U-Boot's PXE works
`bootcmd_pxe` runs `dhcp`, then `pxe get`, then `pxe boot`. It fetches
`pxelinux.cfg/<file>` over TFTP from the DHCP `next-server`, trying in order
the client UUID, `01-<mac-with-dashes>`, the IP in hex (shortening one digit at
a time) and finally `default`. The file is extlinux syntax, and `kernel`,
`fdt` and `initrd` are then fetched over TFTP. `bootcmd_dhcp` is the other
option: it downloads `boot.scr.uimg` and sources it.

Starting points:
[`dnsmasq.conf.example`](dnsmasq.conf.example) and
[`pxelinux.cfg/default.example`](pxelinux.cfg/default.example).

## What is missing for an unattended install
A kernel that boots from the network alone is not enough. For a blank unit to
end up with the Reticulum node you also need a **net-install initramfs** that:
brings up Ethernet (the `rk_gmac` driver must be built in or in the initramfs),
fetches the image over HTTP, writes it to the eMMC (`xz -dc | dd`), and
reboots. The kernel, DTB and initrd can be taken from the community image. That
initramfs does not exist yet and is the main piece of work.

## Hazards
- Writing the eMMC from the network installer destroys the factory OS and
  anything else on the unit. Test on one unit you can reflash by other means
  (rkdeveloptool / maskrom) before relying on it.
- Anyone on the same network segment who can answer DHCP/TFTP can supply a
  kernel to a netbooting unit. Use an isolated provisioning VLAN.
