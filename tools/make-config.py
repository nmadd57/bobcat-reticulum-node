#!/usr/bin/env python3
"""Create a bobcat-install.conf: the settings file for the Bobcat Reticulum node.

Run it with no options for an interactive questionnaire, or give settings on the
command line for a scripted run. The result is checked with the installer's own
validator (--dry-run) before it is written, so a file this tool writes is one the
install will accept.

  tools/make-config.py                          # ask questions
  tools/make-config.py --wifi-ssid Net --hostname bobcat-01
  tools/make-config.py --set FREQUENCY=868000000 --set TRANSPORT=no -o /media/me/BOBCFG/bobcat-install.conf

Then flash the image to the SD card as usual (dd, or any imaging tool) and copy the
file onto the card's BOBCFG partition. Works on Linux, macOS and Windows (Python 3.8+,
standard library only).

Secrets are never taken from the command line: the Wi-Fi passphrase comes from a
prompt, --wifi-pass-file, or the BOBCAT_WIFI_PASS environment variable.
"""

import argparse
import base64
import datetime
import getpass
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_OUT = "bobcat-install.conf"

# ---------------------------------------------------------------- validators
# The installer's --dry-run is the authority; these only give quick feedback
# while answering questions.


def v_int(lo, hi):
    def check(v):
        if not re.fullmatch(r"\d+", v) or not lo <= int(v) <= hi:
            return f"a whole number from {lo} to {hi}"
    return check


def v_choice(*options):
    def check(v):
        if v.lower() not in options:
            return "one of: " + ", ".join(options)
    return check


def v_hostname(v):
    if not re.fullmatch(r"[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?", v):
        return "letters, digits and hyphens (no leading or trailing hyphen)"


def v_ipv4(v):
    parts = v.split(".")
    if len(parts) != 4 or not all(p.isdigit() and int(p) <= 255 for p in parts):
        return "an IPv4 address like 192.168.1.1"


def v_cidr(v):
    addr, _, prefix = v.partition("/")
    if v_ipv4(addr) or not prefix.isdigit() or not 1 <= int(prefix) <= 32:
        return "an address with prefix, like 192.168.1.50/24"


def v_dns(v):
    for item in v.replace(" ", "").split(","):
        if v_ipv4(item):
            return "comma-separated IPv4 addresses"


def v_hostport(v):
    host, _, port = v.rpartition(":")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", host) or not port.isdigit() or not 1 <= int(port) <= 65535:
        return "host:port, like hub.example.org:4242"


def v_wifi_pass(v):
    if not 8 <= len(v) <= 63:
        return "8 to 63 characters"


def v_github(v):
    for user in v.replace(" ", "").split(","):
        if user and not (re.fullmatch(r"[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?", user) and "--" not in user):
            return f"'{user}' is not a GitHub username"


def v_ifac(v):
    if '"' in v or "\\" in v:
        return 'no " or \\ characters'


# ---------------------------------------------------------------- the answers


class Settings:
    """KEY=value pairs in file order; a key may repeat only where the installer allows."""

    REPEATABLE = {"SSH_AUTHORIZED_KEY", "SSH_GITHUB_USER", "TCP_CLIENT"}

    def __init__(self):
        self.items = []

    def set(self, key, value):
        key = key.upper()
        if "\n" in value or "\r" in value:
            raise ValueError(f"{key}: a value cannot contain a line break")
        if key not in self.REPEATABLE:
            self.items = [(k, v) for k, v in self.items if k != key]
        self.items.append((key, value))

    def get(self, key):
        for k, v in reversed(self.items):
            if k == key:
                return v
        return None


def literal(value):
    """The installer takes values literally and strips ONE pair of surrounding quotes
    and leading blanks, so wrap anything those rules would damage."""
    if value != value.strip() or (len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'"):
        return f'"{value}"'
    return value


SECTIONS = [
    ("Wi-Fi (this hardware: 2.4 GHz only)", ["WIFI_SSID", "WIFI_PASS", "WIFI_HIDDEN", "WIFI_OPEN"]),
    ("Ethernet", ["ETH_MODE", "ETH_ADDRESS", "ETH_GATEWAY", "ETH_DNS"]),
    ("Operating system", ["HOSTNAME", "TIMEZONE", "SSH_AUTHORIZED_KEY", "SSH_GITHUB_USER", "ROOT_PASSWORD_HASH",
                          "SKIP_FIRSTLOGIN_WIZARD"]),
    ("Radio (must match the other nodes)", ["FREQUENCY", "BANDWIDTH", "SPREADINGFACTOR", "CODINGRATE",
                                            "TXPOWER", "PREAMBLE"]),
    ("Reticulum", ["TRANSPORT", "AUTOINTERFACE", "RNODE_FRAMING", "INTERFACE_MODE", "IFAC_NETNAME",
                   "IFAC_PASSPHRASE", "TCP_SERVER_PORT", "TCP_CLIENT"]),
    ("First boot", ["SCRUB_BOOT_CONF"]),
]


def render(settings):
    lines = [
        "# bobcat-install.conf, made by tools/make-config.py on "
        + datetime.date.today().isoformat(),
        "# Put this file, with exactly this name, on the BOBCFG partition of the flasher",
        "# SD card before powering the Bobcat on. Reference: docs/config-reference.md",
        "",
    ]
    known = {k for _, keys in SECTIONS for k in keys}
    for title, keys in SECTIONS:
        block = [(k, v) for k, v in settings.items if k in keys]
        if not block:
            continue
        lines.append(f"# ===== {title}")
        lines += [f"{k}={literal(v)}" for k, v in block]
        lines.append("")
    extra = [(k, v) for k, v in settings.items if k not in known]
    if extra:
        lines.append("# ===== Other")
        lines += [f"{k}={literal(v)}" for k, v in extra]
        lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------- validation


def find_installer(explicit):
    candidates = [explicit] if explicit else [
        HERE.parent / "installer" / "install-template.sh",
        HERE.parent / "dist" / "bobcat-g295-install.sh",
        Path.cwd() / "bobcat-g295-install.sh",
    ]
    for c in candidates:
        if c and Path(c).is_file():
            return Path(c)
    return None


def validate(text, installer):
    """Run the installer's dry run on the text. Returns (ok, message)."""
    if installer is None:
        return None, "installer not found: the file could not be checked"
    bash = shutil.which("bash")
    if bash is None:
        return None, "bash not found: the file could not be checked"
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "check.conf"
        path.write_text(text, encoding="utf-8", newline="\n")
        proc = subprocess.run([bash, str(installer), "--dry-run", "--config", str(path)],
                              capture_output=True, text=True)
    err = (proc.stderr or "") + (proc.stdout if proc.returncode else "")
    if proc.returncode == 0:
        return True, ""
    if "No module named 'yaml'" in err or "No module named yaml" in err:
        return None, "PyYAML is not installed, so the network settings could not be checked"
    msgs = [ln for ln in err.splitlines() if ln.startswith("error:")] or err.strip().splitlines()[-2:]
    return False, "\n".join(msgs)


# ---------------------------------------------------------------- GitHub keys

KEY_RE = re.compile(r"^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|"
                    r"sk-ecdsa-sha2-nistp256@openssh\.com)\s+([A-Za-z0-9+/=]+)(\s.*)?$")


def fingerprint(blob_b64):
    try:
        digest = hashlib.sha256(base64.b64decode(blob_b64)).digest()
    except ValueError:
        return "?"
    return "SHA256:" + base64.b64encode(digest).decode().rstrip("=")


def github_keys(user):
    """Look up a user's public keys. Returns (status, keys): status is 'ok', 'notfound'
    or 'unreachable'; keys is a list of (type, fingerprint, comment).
    BOBCAT_GITHUB_URL overrides https://github.com (used by the tests)."""
    base = os.environ.get("BOBCAT_GITHUB_URL", "https://github.com")
    req = urllib.request.Request(f"{base}/{user}.keys", headers={"User-Agent": "bobcat-reticulum-node"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return ("notfound", []) if exc.code == 404 else ("unreachable", [])
    except Exception:
        return "unreachable", []
    keys = []
    for line in body.splitlines():
        m = KEY_RE.match(line.strip())
        if m:
            keys.append((m.group(1), fingerprint(m.group(4)), (m.group(5) or "").strip()))
    return "ok", keys


def check_github_user(user, out=print):
    """Report what GitHub has for `user`. Returns True if usable, False if it is certainly
    not (no such user, or no keys), None if GitHub could not be reached."""
    status, keys = github_keys(user)
    if status == "notfound":
        out(f"  GitHub has no user '{user}'")
        return False
    if status == "unreachable":
        out(f"  could not reach GitHub to check '{user}'; the node will fetch the keys when it installs")
        return None
    if not keys:
        out(f"  GitHub user '{user}' has no SSH public keys")
        return False
    out(f"  GitHub user '{user}': {len(keys)} key(s)")
    for kind, fp, comment in keys:
        out(f"    {kind}  {fp}  {comment}".rstrip())
    return True


# ---------------------------------------------------------------- prompting


class Asker:
    def __init__(self):
        self.tty = sys.stdin.isatty()

    def line(self, prompt):
        try:
            return input(prompt)
        except EOFError:
            sys.exit("\nno more input; nothing was written")

    def ask(self, prompt, default=None, check=None, allow_empty=True):
        shown = f" [{default}]" if default else ""
        while True:
            raw = self.line(f"{prompt}{shown}: ").strip()
            value = raw or (default or "")
            if not value and not allow_empty:
                print("  this one is required")
                continue
            if value and check and (problem := check(value)):
                print(f"  not valid: {problem}")
                continue
            return value

    def yes(self, prompt, default=False):
        hint = "Y/n" if default else "y/N"
        while True:
            raw = self.line(f"{prompt} [{hint}]: ").strip().lower()
            if not raw:
                return default
            if raw in ("y", "yes"):
                return True
            if raw in ("n", "no"):
                return False
            print("  please answer y or n")

    def secret(self, prompt, check=None, confirm=True):
        while True:
            value = getpass.getpass(f"{prompt}: ") if self.tty else self.line(f"{prompt}: ")
            if check and (problem := check(value)):
                print(f"  not valid: {problem}")
                continue
            if confirm and self.tty and getpass.getpass("  again to confirm: ") != value:
                print("  the two entries differ")
                continue
            return value


def default_timezone():
    try:
        tz = Path("/etc/timezone").read_text().strip()
        if tz:
            return tz
    except OSError:
        pass
    try:
        target = os.path.realpath("/etc/localtime")
        if "zoneinfo/" in target:
            return target.split("zoneinfo/", 1)[1]
    except OSError:
        pass
    return ""


def find_public_keys():
    ssh = Path.home() / ".ssh"
    return sorted(ssh.glob("*.pub")) if ssh.is_dir() else []


def hash_password(password):
    """crypt(3) SHA-512 hash through openssl (the password goes in on stdin)."""
    openssl = shutil.which("openssl")
    if not openssl:
        return None
    proc = subprocess.run([openssl, "passwd", "-6", "-stdin"], input=password + "\n",
                          capture_output=True, text=True)
    out = proc.stdout.strip()
    return out if proc.returncode == 0 and out.startswith("$6$") else None


def read_secret_file(path):
    return Path(path).read_text(encoding="utf-8").splitlines()[0].rstrip("\r")


def interview(a, s):
    print("\nBobcat Reticulum node: settings\n"
          "Press Enter to skip a question or keep the default shown in [brackets].\n")

    print("-- Network")
    if a.yes("Join a Wi-Fi network (needed if there is no network cable)?", default=True):
        s.set("WIFI_SSID", a.ask("  Network name (SSID)", allow_empty=False))
        if a.yes("  Is it a hidden network (name not broadcast)?"):
            s.set("WIFI_HIDDEN", "yes")
        if a.yes("  Open network, no password?"):
            s.set("WIFI_OPEN", "yes")
        else:
            s.set("WIFI_PASS", a.secret("  Wi-Fi passphrase (not shown)", v_wifi_pass))
        print("  note: this board's Wi-Fi is 2.4 GHz only")
    mode = a.ask("Ethernet: keep as is (DHCP), dhcp, or static?", "keep", v_choice("keep", "dhcp", "static")).lower()
    if mode != "keep":
        s.set("ETH_MODE", mode)
    if mode == "static":
        s.set("ETH_ADDRESS", a.ask("  Address with prefix (e.g. 192.168.1.50/24)", check=v_cidr, allow_empty=False))
        gw = a.ask("  Gateway", check=v_ipv4)
        if gw:
            s.set("ETH_GATEWAY", gw)
        dns = a.ask("  DNS servers, comma separated", check=v_dns)
        if dns:
            s.set("ETH_DNS", dns)

    print("\n-- System")
    host = a.ask("Hostname", check=v_hostname)
    if host:
        s.set("HOSTNAME", host)
    tz = a.ask("Timezone (e.g. America/New_York)", default_timezone() or None)
    if tz:
        s.set("TIMEZONE", tz)
    keys = find_public_keys()
    if keys:
        print("  SSH public keys found on this computer:")
        for i, k in enumerate(keys, 1):
            print(f"    {i}) {k}")
        pick = a.ask("  Allow which for root login? number(s) separated by commas, or Enter for none", "")
        for n in [x for x in pick.replace(" ", "").split(",") if x]:
            if n.isdigit() and 1 <= int(n) <= len(keys):
                s.set("SSH_AUTHORIZED_KEY", keys[int(n) - 1].read_text().strip().splitlines()[0])
    pasted = a.ask("  Paste another public key (or Enter to skip)")
    if pasted:
        s.set("SSH_AUTHORIZED_KEY", pasted)
    print("  The node can also fetch the public keys a GitHub user publishes (github.com/NAME.keys),")
    print("  once, when it installs. It needs internet then.")
    while True:
        gh = a.ask("  GitHub username(s) allowed to log in as root (comma separated, Enter for none)", check=v_github)
        users = [u for u in gh.replace(" ", "").split(",") if u]
        if not users:
            break
        results = [check_github_user(u) for u in users]
        if any(r is False for r in results):
            print("  Please try again.")
            continue
        for u in users:
            s.set("SSH_GITHUB_USER", u)
        break
    if a.yes("Set a root password (the image's default is 1234)?", default=not s.get("SSH_AUTHORIZED_KEY")):
        pw = a.secret("  New root password (not shown)", lambda v: "cannot be empty" if not v else None)
        h = hash_password(pw)
        if h:
            s.set("ROOT_PASSWORD_HASH", h)
        else:
            print("  openssl is not available here to make the hash.")
            h = a.ask("  Paste a hash (from: mkpasswd -m sha-512), or Enter to skip")
            if h:
                s.set("ROOT_PASSWORD_HASH", h)
    if a.yes("Skip the interactive first-login prompt (recommended for a headless node)?", default=True):
        s.set("SKIP_FIRSTLOGIN_WIZARD", "yes")

    print("\n-- Radio (defaults: 915 MHz, 125 kHz, SF8, CR 4/5; must match your other nodes)")
    if a.yes("Change the radio settings?"):
        for key, label, default, chk in [
            ("FREQUENCY", "  Frequency in Hz", "915000000", v_int(150_000_000, 960_000_000)),
            ("BANDWIDTH", "  Bandwidth (125000, 250000 or 500000)", "125000", v_choice("125000", "250000", "500000")),
            ("SPREADINGFACTOR", "  Spreading factor (7-12)", "8", v_int(7, 12)),
            ("CODINGRATE", "  Coding rate (5-8 means 4/5 to 4/8)", "5", v_int(5, 8)),
            ("TXPOWER", "  TX power in dBm (12-16)", "14", v_int(12, 16)),
        ]:
            val = a.ask(label, default, chk)
            if val != default:
                s.set(key, val)

    print("\n-- Reticulum")
    if a.yes("Do not repeat other nodes' traffic (turn transport off)?"):
        s.set("TRANSPORT", "no")
    if a.yes("Use interface access control (IFAC) so only peers with the same name/passphrase talk to you?"):
        s.set("IFAC_NETNAME", a.ask("  Network name", check=v_ifac, allow_empty=False))
        s.set("IFAC_PASSPHRASE", a.secret("  Passphrase (not shown)", v_ifac, confirm=True))
    mode = a.ask("Interface mode: full, gateway, access_point, roaming, boundary, pointtopoint", "full",
                 v_choice("full", "gateway", "access_point", "roaming", "boundary", "pointtopoint"))
    if mode != "full":
        s.set("INTERFACE_MODE", mode)
    if a.yes("Connect to a Reticulum TCP hub?"):
        while True:
            s.set("TCP_CLIENT", a.ask("  host:port", check=v_hostport, allow_empty=False))
            if not a.yes("  another?"):
                break
    port = a.ask("Accept Reticulum TCP connections on a port (opens that port; Enter for none)", check=v_int(1, 65535))
    if port:
        s.set("TCP_SERVER_PORT", port)


# ---------------------------------------------------------------- main


def parse_args():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--output", default=DEFAULT_OUT,
                    help=f"where to write (default ./{DEFAULT_OUT}); '-' prints to the screen")
    ap.add_argument("--force", action="store_true", help="overwrite an existing output file")
    ap.add_argument("--installer", help="installer to validate with (default: found automatically)")
    ap.add_argument("--no-validate", action="store_true", help="do not check the result with the installer")
    ap.add_argument("--non-interactive", action="store_true",
                    help="never ask questions (implied when any setting option is given)")
    ap.add_argument("--set", action="append", default=[], metavar="KEY=VALUE",
                    help="set any key from docs/config-reference.md (repeatable). Avoid for secrets")
    ap.add_argument("--wifi-ssid")
    ap.add_argument("--wifi-pass-file", help="file whose first line is the Wi-Fi passphrase")
    ap.add_argument("--wifi-hidden", action="store_true")
    ap.add_argument("--wifi-open", action="store_true")
    ap.add_argument("--hostname")
    ap.add_argument("--timezone")
    ap.add_argument("--ssh-key-file", action="append", default=[],
                    help="a public key file to allow (repeatable; a file may hold several keys)")
    ap.add_argument("--ssh-github-user", action="append", default=[], metavar="NAME",
                    help="allow the public keys GitHub publishes for NAME (repeatable); the node fetches "
                         "them once, at install time, and the name is checked here first")
    ap.add_argument("--no-github-check", action="store_true",
                    help="do not look the GitHub user up from this computer")
    return ap.parse_args()


def main():
    args = parse_args()
    s = Settings()

    scripted = bool(args.set or args.wifi_ssid or args.hostname or args.timezone or args.ssh_key_file
                    or args.ssh_github_user or args.wifi_hidden or args.wifi_open or args.non_interactive)

    try:
        if scripted:
            if args.wifi_ssid:
                s.set("WIFI_SSID", args.wifi_ssid)
                if args.wifi_open:
                    s.set("WIFI_OPEN", "yes")
                else:
                    pw = (read_secret_file(args.wifi_pass_file) if args.wifi_pass_file
                          else os.environ.get("BOBCAT_WIFI_PASS", ""))
                    if not pw and sys.stdin.isatty():
                        pw = getpass.getpass("Wi-Fi passphrase: ")
                    if pw:
                        s.set("WIFI_PASS", pw)
                if args.wifi_hidden:
                    s.set("WIFI_HIDDEN", "yes")
            elif args.wifi_hidden or args.wifi_open or args.wifi_pass_file:
                sys.exit("--wifi-hidden, --wifi-open and --wifi-pass-file need --wifi-ssid")
            if args.hostname:
                s.set("HOSTNAME", args.hostname)
            if args.timezone:
                s.set("TIMEZONE", args.timezone)
            for kf in args.ssh_key_file:
                for ln in Path(kf).read_text().splitlines():
                    if ln.strip() and not ln.lstrip().startswith("#"):
                        s.set("SSH_AUTHORIZED_KEY", ln.strip())
            for user in args.ssh_github_user:
                problem = v_github(user)
                if problem:
                    sys.exit(f"error: {problem}")
                if not args.no_github_check and check_github_user(user, lambda m: print(m, file=sys.stderr)) is False:
                    sys.exit(f"error: GitHub user '{user}' cannot be used; nothing was written")
                s.set("SSH_GITHUB_USER", user)
            for item in args.set:
                key, sep, value = item.partition("=")
                if not sep or not re.fullmatch(r"[A-Za-z0-9_]+", key):
                    sys.exit(f"--set needs KEY=VALUE, got {item!r}")
                s.set(key, value)
        else:
            if not sys.stdin.isatty():
                print("(reading answers from standard input)", file=sys.stderr)
            interview(Asker(), s)
    except (ValueError, OSError) as exc:
        sys.exit(f"error: {exc}")

    if not s.items:
        sys.exit("nothing to write: no settings given. (The install still works with defaults and a wired network.)")

    text = render(s)

    if not args.no_validate:
        ok, msg = validate(text, find_installer(args.installer))
        if ok is False:
            sys.exit(f"The settings are not valid; nothing was written:\n{msg}")
        print("Checked with the installer: " + ("settings are valid." if ok else f"skipped ({msg})."),
              file=sys.stderr)

    if args.output == "-":
        sys.stdout.write(text)
        return
    out = Path(args.output)
    if out.exists() and not args.force:
        sys.exit(f"{out} already exists; use --force to overwrite it")
    out.write_text(text, encoding="utf-8", newline="\n")
    try:
        out.chmod(0o600)
    except OSError:
        pass
    print(f"\nWrote {out}")
    print("Next: write the flasher image to an SD card (dd or any imaging tool), copy this file\n"
          "onto the card's BOBCFG partition with exactly the name bobcat-install.conf, and power on.")


if __name__ == "__main__":
    main()
