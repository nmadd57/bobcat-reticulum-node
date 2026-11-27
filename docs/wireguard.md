# Connecting the node to a WireGuard VPN

The node can connect to a [WireGuard](https://www.wireguard.com/) VPN every time it boots. You give it the config file your VPN
provides (the `wg-quick` format); the installer checks it, stores it on the node, and starts the tunnel as a normal system service.

It is optional and off by default.

## Turning it on

In the [flasher](../), open **Set up the node**, then **VPN**:

1. Paste the config into the box, or press **Load from a file** and pick the `.conf` file.
2. Optionally change the interface name (default `wg0`).

The page checks the config as you go and tells you what is wrong. In a settings file the same thing is one or two keys (see the
[settings reference](config-reference.md)):

```
WIREGUARD_CONFIG_B64=<the config, base64 encoded on one line>
WIREGUARD_INTERFACE=wg0
```

or, when writing an SD card by hand, put the config on the boot partition as `bobcat-wireguard.conf` (the installer is given it as
`WIREGUARD_CONFIG_FILE`). `tools/make-config.py` asks for the file, and `--wireguard-config FILE` does it on the installer's
command line.

## What the node does

- Installs `wireguard-tools` if it is missing, and checks the kernel can create WireGuard interfaces (it warns if not).
- Writes the config to `/etc/wireguard/wg0.conf`, readable only by root.
- Enables and starts `wg-quick@wg0`, so the tunnel comes up at every boot, after the network, and waits up to 15 seconds for the
  first handshake with the peer. A handshake happens when traffic first flows, so a quiet tunnel may show none yet; set
  `PersistentKeepalive = 25` in the peer section if the node should keep the tunnel open by itself.

The tunnel is set up as the last step of the install, so it cannot get in the way of the install itself.

## What is accepted

Only plain WireGuard settings:

| Section | Settings |
|---|---|
| `[Interface]` | `PrivateKey`, `Address`, `ListenPort`, `DNS`, `MTU`, `Table`, `FwMark` |
| `[Peer]` | `PublicKey`, `PresharedKey`, `AllowedIPs`, `Endpoint`, `PersistentKeepalive` |

The config needs an `[Interface]` with a `PrivateKey` and an `Address`, and at least one `[Peer]` with a `PublicKey` and `AllowedIPs`.
Keys are checked for the right shape, addresses and ports for the right range.

**Script hooks are refused.** `PreUp`, `PostUp`, `PreDown`, `PostDown` and `SaveConfig` make `wg-quick` run shell commands as root,
and a settings file is data: it is never run as code. If your config needs a hook, set the tunnel up by hand on the node instead.

Two things to know:

- **All traffic through the VPN.** With `AllowedIPs = 0.0.0.0/0` every packet the node sends goes through the tunnel. If the VPN
  endpoint is unreachable, so is the node. The installer warns about this, and the settings page does too.
- **DNS.** A `DNS =` line is applied through `resolvconf`. Armbian's network manager does not use it, so when `resolvconf` is not
  installed the installer leaves that line out (commented, with a warning) rather than let `wg-quick` fail.

## Your private key

The config holds your private key (and a preshared key, if you use one).

- On the **settings page** it is hidden in the preview, and kept in the cookie only if you tick the box for passwords.
- In the **settings file** it is base64 text. It is not encrypted, so treat that file like a password.
- After a successful install it is **blanked on the boot partition**: the `WIREGUARD_CONFIG_B64` line is emptied, and a
  `bobcat-wireguard.conf` side file is replaced by a one-line note. The copy on the node is `/etc/wireguard/wg0.conf`, root only, and
  `/etc/bobcat-lora/` keeps a root-only copy of the settings so the install can be repeated.
- Settings with `SCRUB_BOOT_CONF=no` keep everything as written.

## Managing it on the node

```
wg show                                  # peers, last handshake, traffic
systemctl status wg-quick@wg0
journalctl -u wg-quick@wg0 -n 30
systemctl restart wg-quick@wg0
```

To change the config, edit `/etc/wireguard/wg0.conf` and restart the service, or run the installer again with new settings.

## If it does not connect

- **No handshake.** Check the endpoint address and port, that the peer has this node's public key (`wg show` prints it), and that the
  peer's firewall allows the UDP port.
- **The service fails to start.** `journalctl -u wg-quick@wg0` has the reason; "Unknown device type" means the kernel has no WireGuard
  support (the installer warns about that at install time).
- **The node became unreachable after the install.** The config probably sends all traffic through the tunnel and the endpoint is not
  reachable; fix the config or flash again without it.
