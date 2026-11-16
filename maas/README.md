# MAAS: what is and is not possible

**Status: researched, not built or tested.** The findings below come from
reading this bootloader's build, not from trying MAAS against a Bobcat.

## Why stock MAAS deployment will not work as things stand
1. **No UEFI.** MAAS network-boots arm64 machines through UEFI (a GRUB EFI
   binary served over TFTP). The Bobcat's U-Boot is built without
   `EFI_LOADER`, so it has no `bootefi` and cannot run it. It only understands
   extlinux-style PXE and `boot.scr` scripts.
2. **No power control.** The unit has no BMC. MAAS could only use the manual
   power type, so someone has to power-cycle it.
3. **No cloud-init.** MAAS delivers user-data through cloud-init and curtin.
   The community image has neither.
4. **Boot order.** Network boot is the last target; a bootable SD card or
   eMMC wins (see `../netboot/README.md`).

## What could work
| Option | Notes |
|---|---|
| **MAAS as DHCP/DNS/IPAM only** | Let MAAS hand out leases and names, and run a separate TFTP/HTTP server for the netboot pieces in `../netboot/`. MAAS does not deploy the OS in this model. |
| **A U-Boot with EFI enabled** | Rebuild the bootloader with `CONFIG_EFI_LOADER` and install it on the eMMC. Then MAAS's normal arm64 flow becomes possible. This is risky (a bad bootloader bricks the unit until it is recovered through maskrom) and was not attempted. |
| **cloud-init in the image** | Add `cloud-init` to the image and read a NoCloud seed from the boot partition. The user-data would then be standard. Not done. |

## The "user-data" that does exist today
The self-installing images read `bobcat-install.conf` (plus optional
`bobcat-netplan.yaml`, `bobcat-authorized_keys`, `bobcat-reticulum.conf`) that you
place next to the image when flashing. It is the same idea as a cloud-init seed,
with a smaller vocabulary: Wi-Fi, Ethernet, hostname, timezone, SSH keys, root
password hash, radio and Reticulum settings. See `../image/README.md` and
`../docs/config-reference.md`.

[`user-data.example.yaml`](user-data.example.yaml) shows what the equivalent
cloud-init user-data would look like if cloud-init were added to the image.
It is a sketch of a possible future path and has not been run.
