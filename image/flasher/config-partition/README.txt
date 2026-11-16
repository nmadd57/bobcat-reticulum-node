Bobcat Reticulum node: settings partition (BOBCFG)
==================================================

Put your settings here BEFORE you power the Bobcat on with this SD card.
While the Bobcat flashes its internal storage it copies the files below onto
it, and the first boot of the new system uses them to install itself. Nothing
secret is stored in the image itself.

  bobcat-install.conf          Wi-Fi, network, system and radio settings
                               (start from bobcat-install.conf.example)
  bobcat-netplan.yaml          optional: a complete netplan config
  bobcat-authorized_keys       optional: SSH public keys for root
  bobcat-reticulum.conf        optional: a complete Reticulum config

Rules
  * The file names must match exactly.
  * Use a plain text editor. Windows line endings are fine.
  * This partition is plain FAT: it works from Windows, macOS and Linux.
  * Your files stay on this SD card. Delete them if the card is shared.

No settings file? The Bobcat still installs, with defaults, and needs a wired
network connection to do so.
