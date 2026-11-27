# Settings reference

The same settings can be given three ways. They all end up in the installer,
which does the parsing and validation:

| How | When |
|---|---|
| `bobcat-install.conf` on the **BOBCFG** partition of the flasher SD card | recommended: the file travels with the SD card, nothing is baked into the image |
| `bobcat-install.conf` on the FAT boot partition of the standalone image | same idea for the SD-boot image |
| `bobcat-g295-install.sh --config FILE`, or the options below | on a running unit |

**Making the file:** the web config generator in `site/` (published with GitHub Pages) fills in a form and lets you download it. Or `python3 tools/make-config.py` asks questions and writes it
(`--help` for scripted use, e.g. `--set KEY=VALUE`); it works on Linux, macOS and
Windows with plain Python 3. Its result is checked by the installer's own
validator before it is written. You can also edit
`image/firstboot/bobcat-install.conf.example` by hand.

Options on the command line override the file. `--dry-run` shows the plan and
the generated configs (secrets masked) without changing anything and without
needing root. It is the quickest way to check a file.

## File format

`KEY=value`, one per line. `#` starts a comment line. Values are literal: there
is no escaping, and one pair of surrounding single or double quotes is removed.
The file is parsed, never executed; unknown keys produce a warning and are
ignored. Windows line endings are fine. Keys marked *repeatable* may appear more
than once.

## Keys

### Wi-Fi
| Key | Option | Meaning |
|---|---|---|
| `WIFI_SSID` | `--wifi-ssid` | network to join. 2.4 GHz only (the board's chip) |
| `WIFI_PASS` | `--wifi-pass-file` | WPA passphrase, 8-63 characters |
| `WIFI_HIDDEN` | `--wifi-hidden` | the SSID is not broadcast |
| `WIFI_OPEN` | `--wifi-open` | no password |

### Ethernet
| Key | Option | Meaning |
|---|---|---|
| `ETH_MODE` | `--eth-mode` | `keep` (default, untouched), `dhcp`, or `static` |
| `ETH_ADDRESS` | `--eth-address` | `192.168.1.50/24` (static only) |
| `ETH_GATEWAY` | `--eth-gateway` | default route (static only) |
| `ETH_DNS` | `--eth-dns` | comma-separated DNS servers (static only) |
| `NETPLAN_FILE` | `--netplan-file` | a complete netplan file instead of the settings above |

The Wi-Fi and Ethernet settings are written as one netplan file,
`/etc/netplan/60-bobcat-network.yaml`, validated first and applied under an
automatic revert timer. A definition of the same SSID or interface in another
netplan file is refused (netplan would reject it or silently merge it).

### Operating system
| Key | Option | Meaning |
|---|---|---|
| `HOSTNAME` | `--hostname` | letters, digits, hyphens |
| `TIMEZONE` | `--timezone` | e.g. `Europe/Berlin` |
| `SSH_AUTHORIZED_KEY` | | a public key line (*repeatable*) |
| `SSH_AUTHORIZED_KEYS_FILE` | `--ssh-key-file` | a file of public keys, added to root's `authorized_keys` without duplicates |
| `SSH_GITHUB_USER` | `--ssh-github-user` | add the public keys GitHub publishes for this user (`https://github.com/NAME.keys`); *repeatable* |
| `ROOT_PASSWORD_HASH` | `--root-password-hash` | a crypt(3) hash (`mkpasswd -m sha-512`); plain text is refused |
| `USER_NAME` | `--user` | also create this (second) user: lowercase letters, digits, `-` and `_`; not `root`. Needs `USER_PASSWORD_HASH`, `USER_SSH_KEY` or `USER_SSH_GITHUB_USER` |
| `USER_PASSWORD_HASH` | `--user-password-hash` | the user's crypt(3) hash; plain text is refused |
| `USER_SSH_KEY` | `--user-ssh-key` | a public key line for the user's `~/.ssh/authorized_keys` (*repeatable*) |
| `USER_SSH_GITHUB_USER` | `--user-ssh-github-user` | add the public keys GitHub publishes for this account to the user's `authorized_keys`; *repeatable* |
| `USER_SUDO` | `--user-sudo` | add the user to the `sudo` group (needs `USER_PASSWORD_HASH`, since sudo asks for it) |
| `SKIP_FIRSTLOGIN_WIZARD` | `--skip-first-login-wizard` | removes Armbian's interactive first-login prompt |

The community image ships with root password `1234` and the first-login prompt,
so for an unattended node set a password hash or SSH key.

**Keys from GitHub.** With `SSH_GITHUB_USER=alice` the installer downloads
`https://github.com/alice.keys` once, while installing, and adds every plain public key
in it to root's `authorized_keys` (duplicates are skipped; keys with options such as
`command=` are ignored). Things to know:
- It needs internet at install time, and a correct clock (the first boot waits for time sync).
- It is a one-time copy: adding or removing a key on GitHub later does not change the
  node. Re-run the installer to refresh.
- If the user does not exist, has no usable keys, or GitHub cannot be reached, **the install
  stops** (and, on first boot, tries again) instead of carrying on without the access you
  asked for. A typo is therefore found early: `tools/make-config.py` looks the name up
  on your computer before writing the file and shows each key's fingerprint, so you can
  check they are yours.
- The names are validated as GitHub usernames; anything else is rejected.

### Radio
| Key | Option | Meaning |
|---|---|---|
| `FREQUENCY` | `--frequency` | Hz, 150-960 MHz (default 915 MHz) |
| `BANDWIDTH` | `--bandwidth` | 125000, 250000 or 500000. **Not 62500**: the SX1302 cannot receive it |
| `SPREADINGFACTOR` | `--spreadingfactor` | 7-12 (default 8) |
| `CODINGRATE` | `--codingrate` | 5-8, meaning 4/5 to 4/8 (default 5) |
| `TXPOWER` | `--txpower` | 12-16 dBm, the limit of the shipped TX gain table |
| `PREAMBLE` | `--preamble` | symbols, 6-1000 (default 18, RNode's minimum) |

These must match the other nodes on the network.

### Reticulum
| Key | Option | Meaning |
|---|---|---|
| `TRANSPORT` | `--no-transport` | repeat other nodes' traffic (default yes) |
| `AUTOINTERFACE` | `--no-autointerface` | LAN discovery (default yes) |
| `RNODE_FRAMING` | `--no-rnode-framing` | the one-byte RNode header (default yes; needed to talk to RNodes) |
| `INTERFACE_MODE` | `--interface-mode` | `full`, `gateway`, `access_point`, `roaming`, `boundary`, `pointtopoint` |
| `IFAC_NETNAME` | `--ifac-netname` | interface access control network name |
| `IFAC_PASSPHRASE` | `--ifac-passphrase-file` | interface access control passphrase (no `"` or `\`) |
| `TCP_SERVER_PORT` | `--tcp-server-port` | also accept Reticulum TCP links on this port. **Opens a port** |
| `TCP_CLIENT` | `--tcp-client` | `host:port` of a Reticulum TCP server (*repeatable*) |
| `RETICULUM_CONFIG_FILE` | `--reticulum-config` | use this file as `/etc/reticulum/config`; the radio, IFAC, mode and TCP settings are then ignored |

A generated `/etc/reticulum/config` is rewritten when settings change, as long
as nobody edited it by hand; an edited file is kept (use `--force-config` to
replace it).

### Self-recovery
Installed by default; details in [`self-recovery.md`](self-recovery.md).

| Key | Option | Meaning |
|---|---|---|
| `WEBUI` | `--webui` | `yes` also installs the rnsd web interface (rnsd-webui) as a service, over HTTPS (port 443, with plain HTTP on 80 redirecting to it). Needs `WEBUI_PASSWORD_HASH`. See [the web interface](web-interface.md) |
| `WEBUI_PASSWORD_HASH` | `--webui-password-hash` | its login password as a hash: `pbkdf2-sha256$<iterations>$<salt hex>$<hash hex>` (the flasher and `tools/make-config.py` make one) or `scrypt$...`; plain text is refused |
| `WEBUI_PORT` | `--webui-port` | its HTTPS port (default `443`); must differ from `TCP_SERVER_PORT`. Only port 443 also redirects plain HTTP |
| `WEBUI_DOMAIN` | `--webui-domain` | a full domain name (for example `bobcat.example.com`): the web interface then gets a trusted Let's Encrypt certificate for it, validated through DNS. Needs `CLOUDFLARE_API_TOKEN` |
| `CLOUDFLARE_API_TOKEN` | `--cloudflare-token-file` | a Cloudflare API token with the permission Zone, DNS, Edit for that zone. Kept root-only on the node and blanked on the boot partition after the install |
| `ACME_EMAIL` | `--acme-email` | contact address for Let's Encrypt expiry notices (optional) |
| `WIREGUARD_CONFIG_B64` | | a WireGuard config (`wg-quick` format, no script hooks), base64 on one line; the node connects to it at every boot. See [WireGuard](wireguard.md) |
| `WIREGUARD_CONFIG_FILE` | `--wireguard-config` | the same config as a file (on the boot partition: `bobcat-wireguard.conf`). Not together with `WIREGUARD_CONFIG_B64` |
| `WIREGUARD_INTERFACE` | `--wireguard-interface` | its interface name (default `wg0`) |
| `RESILIENCE` | `--no-resilience` | `no` removes persistent logs, the watchdogs and the network watchdog |
| `NETWATCH_TARGET` | `--netwatch-target` | host or IP to ping instead of the default gateway |
| `NETWATCH_REBOOT_MINUTES` | `--netwatch-reboot-minutes` | reboot after this many minutes without network; `0` never, otherwise 5-1440 (default 20) |
| `LOG_KEEP_DAYS` | `--log-keep-days` | keep the journal and rotated logs this long, 1-365 (default 14) |
| `LOG_MAX_MB` | `--log-max-mb` | cap on rotated logs kept on disk, 20-2000 (default 100) |

### First boot only
| Key | Meaning |
|---|---|
| `SCRUB_BOOT_CONF` | `no` keeps `WIFI_PASS` and `IFAC_PASSPHRASE` on the FAT partition after the install. Default `yes` clears them there. A root-only copy always stays under `/etc/bobcat-lora/` |

## Extra files next to `bobcat-install.conf`

Exact file names, same folder:

| File | Same as |
|---|---|
| `bobcat-authorized_keys` | `SSH_AUTHORIZED_KEYS_FILE` |
| `bobcat-reticulum.conf` | `RETICULUM_CONFIG_FILE` |
| `bobcat-netplan.yaml` | `NETPLAN_FILE`; ignored when the settings file configures Wi-Fi or static/DHCP Ethernet |

If `bobcat-install.conf` names the file itself (the key is set), the side file is
not used.

## Where the settings end up

The first boot copies everything into `/etc/bobcat-lora/` (mode 700, files 600):
`effective.conf` is what the installer ran with, and `files/` holds the side
files. Re-apply later with
`bobcat-g295-install.sh --config /etc/bobcat-lora/effective.conf`.

## Examples

Wi-Fi node, no cable:
```
WIFI_SSID=HomeNet
WIFI_PASS=correct horse battery
HOSTNAME=bobcat-attic
SSH_AUTHORIZED_KEY=ssh-ed25519 AAAAC3Nza... me@laptop
SSH_GITHUB_USER=my-github-name
SKIP_FIRSTLOGIN_WIZARD=yes
```

Fixed-address gateway bridging to a TCP hub, with IFAC:
```
ETH_MODE=static
ETH_ADDRESS=10.0.0.20/24
ETH_GATEWAY=10.0.0.1
ETH_DNS=10.0.0.1
INTERFACE_MODE=gateway
IFAC_NETNAME=meshnet
IFAC_PASSPHRASE=shared secret
TCP_CLIENT=hub.example.org:4242
```
