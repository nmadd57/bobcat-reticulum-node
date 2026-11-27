# The node's web interface

A Bobcat node can run a small web interface for its Reticulum daemon ([rnsd-webui](https://github.com/nmadd57/rnsd-webui)). From any
browser on your network you can see the node's interfaces and traffic, browse the path table, watch announces arrive live, and
announce the node or request a path to a destination.

It is optional and off by default.

## Turning it on

In the [flasher](../), open **Set up the node**, then **Web interface**:

1. Tick **Install the rnsd web interface on the node**.
2. Type a password. It is hashed in your browser (PBKDF2-SHA256); only the hash goes into the settings, never the password.
3. Optionally choose a port. The default is **443**, the standard HTTPS port, and plain `http://` on port 80 is sent on to HTTPS.
4. Optionally get a [trusted certificate](#a-trusted-certificate-no-browser-warning) with a domain name and a Cloudflare token.

Flash as usual. On first boot the installer adds the web interface after Reticulum itself.

In a settings file the same thing is three keys (see the [settings reference](config-reference.md)):

```
WEBUI=yes
WEBUI_PASSWORD_HASH=pbkdf2-sha256$200000$<salt hex>$<hash hex>
WEBUI_PORT=443
WEBUI_DOMAIN=bobcat.example.com          # optional, for a trusted certificate
CLOUDFLARE_API_TOKEN=...                  # optional, with the domain
ACME_EMAIL=you@example.com                # optional
```

`tools/make-config.py` asks the same questions, and `--webui`, `--webui-password-hash` and `--webui-port` do it on the installer's
command line.

## Using it

Open `https://<hostname>/` (the hostname you set, or the node's address; the port is only part of the address if you chose one other
than 443) and sign in with the password you chose. Typing just the name, without `https://`, reaches the redirect on port 80 and
ends up in the same place.

**Without a domain and token, your browser will warn about the certificate.** The node makes its own certificate when it installs,
so no browser knows it. The connection is still encrypted, and the warning is only that nobody vouched for the certificate. Accept
it for this address once. If the node is ever reinstalled it makes a new certificate and the warning returns.

## A trusted certificate (no browser warning)

With a domain name and a Cloudflare API token the node gets a real [Let's Encrypt](https://letsencrypt.org/) certificate, so there is no
warning on any device. It is validated through DNS (the DNS-01 challenge): `certbot` adds a short-lived TXT record to your zone using
the token, so **nothing has to be reachable from the internet**, which suits a node on a home network.

What you need:

1. **A domain in a Cloudflare zone** on your account, and a name in it for the node, for example `bobcat.example.com`.
2. **A Cloudflare API token** with the permission **Zone, DNS, Edit**, limited to that zone (Cloudflare: My Profile, API Tokens,
   Create Token, "Edit zone DNS" template). It can change that zone's DNS records and nothing else.
3. **An `A` record** for the name pointing at the node's address on your network (a private address such as `192.168.1.50` is fine;
   the installer prints the node's address when it finishes). Give the node a fixed address or a DHCP reservation so the record stays right.

Enter the domain, the token and (optionally) a contact email in the flasher under **Web interface**, **A trusted certificate**.
By setting a domain you accept [Let's Encrypt's terms](https://letsencrypt.org/repository/).

What the node does with them:

- Installs `certbot` and its Cloudflare plugin from Debian, and asks for the certificate during the install.
- Keeps the token in `/etc/letsencrypt/cloudflare-rnsd-webui.ini`, readable only by root; it is blanked in the settings on the boot
  partition after the install.
- Renews the certificate by itself (certbot's timer runs twice a day and renews 30 days before expiry), then restarts the web
  interface so it picks the new one up.
- **If the certificate cannot be had** (wrong token, a name that is not in your account, no internet), the install carries on: it warns
  with certbot's own message, uses a self-signed certificate for that name instead, and the web interface still works. Fix the cause and
  run the installer again.

| Tab | What it shows |
|---|---|
| Dashboard | Transport ID, uptime, links, total traffic with live rates, and one card per interface: status, type, bitrate, bytes in and out, announce rates, IFAC |
| Paths | The path table: destination, hops, next hop, interface, time to expiry. Filter it, or refresh one path |
| Announces | A live feed of every announce the daemon sees, with the announce text when it is text |
| Tools | Announce the web interface's own destination, or request a path to a destination hash |

It is a client of the node's running `rnsd`. It does not change the daemon's configuration and cannot restart it; the radio
settings stay where they were, in `/etc/reticulum/config`.

## Managing it on the node

It is a systemd service, `rnsd-webui`, installed next to `rnsd-sx1302`:

```
systemctl status rnsd-webui
journalctl -u rnsd-webui -f
systemctl restart rnsd-webui
```

Change the password on the node:

```
/opt/bobcat-lora/venv/bin/rnsd-webui set-password --data-dir /var/lib/rnsd-webui
systemctl restart rnsd-webui
```

Its files are in `/var/lib/rnsd-webui`: the password hash (`auth.json`, readable only by root), its own Reticulum identity, and the
certificate in `tls/`.

## Security notes

- One administrator password, stored as a hash. Five wrong attempts in a minute from one address are refused.
- Sessions are random tokens in an `HttpOnly`, `SameSite=Strict`, `Secure` cookie; every change also needs a per-session token.
- It listens on all addresses of the node, over HTTPS (plus a plain HTTP redirect on port 80). Anyone who can reach the port can try
  to sign in, so use a long password and do not forward the port to the internet.
- The service runs as root (Reticulum's shared-instance key is only readable by root) with systemd hardening: a read-only
  system, no access to home directories, and write access only to `/etc/reticulum` and its own data directory.
- The interface can announce and request paths on the network the node is part of, and that is all it can do to it.
