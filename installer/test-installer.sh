#!/usr/bin/env bash
#
# Tests for the installer's settings handling, using --dry-run: no root, no
# Bobcat, nothing is changed. Needs python3 with PyYAML (for the netplan preview).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$HERE/install-template.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
# Do not depend on (or be confused by) the host's own netplan files.
mkdir -p "$T/netplan"
export BOBCAT_NETPLAN_DIR="$T/netplan"

pass=0 failed=0
ok()    { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '     %s\n' "$2"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
has()   { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1" "missing [$2]"; fi; }
hasnt() { if grep -qF -- "$2" <<<"$3"; then bad "$1" "unexpected [$2]"; else ok "$1"; fi; }

plan() { OUT="$(bash "$INSTALLER" --dry-run "$@" 2>&1)"; RC=$?; }
plan_ok()   { plan "${@:2}"; if [[ $RC -eq 0 ]]; then ok "$1"; else bad "$1" "exit $RC: $(head -3 <<<"$OUT" | tr '\n' ' ')"; fi; }
plan_fail() {   # plan_fail <name> <expected message part> args...
    local name="$1" msg="$2"; shift 2
    plan "$@"
    if [[ $RC -ne 0 && "$OUT" == *"$msg"* ]]; then ok "$name"; else bad "$name" "exit $RC, wanted [$msg], got: $(head -2 <<<"$OUT" | tr '\n' ' ')"; fi
}

section() { sed -n "/^$1\$/,/^-- /p" <<<"$OUT"; }

# ---------------------------------------------------------------- defaults
plan_ok "defaults: dry run succeeds without root"
has   "defaults: announces itself as a dry run" "dry run: nothing is changed" "$OUT"
has   "defaults: transport on" "transport:     yes" "$OUT"
has   "defaults: LoRa interface stanza generated" "[[SX1302 LoRa]]" "$OUT"
hasnt "defaults: no radio overrides written" "frequency =" "$OUT"
hasnt "defaults: no netplan generated when no network is configured" "generated netplan" "$OUT"

# ------------------------------------------------------------- config file
cat > "$T/a.conf" <<CONF
# a comment
WIFI_SSID=My "Net"
WIFI_PASS=pa ss"w\$(touch $T/PWNED)rd
WIFI_HIDDEN=yes
FREQUENCY=915000000
SPREADINGFACTOR = 9
TRANSPORT=no
EVIL_KEY=1
lowercase=bad
not a setting line
CONF
printf 'CODINGRATE=6\r\nTXPOWER=15\r\n' > "$T/crlf.conf"
plan_ok "config: parses (quotes, spaces around =, CRLF)" --config "$T/a.conf" --config "$T/crlf.conf"
[[ ! -e "$T/PWNED" ]] && ok "config: nothing in the file is executed" || bad "config: nothing in the file is executed"
has   "config: SSID with quotes" 'wifi:          My "Net" (hidden)' "$OUT"
has   "config: bool yes/no accepted" "transport:     no" "$OUT"
has   "config: second file's CRLF values read" "coding rate:   6" "$OUT"
has   "config: unknown key warned" "ignoring unknown key EVIL_KEY" "$OUT"
has   "config: junk line warned without echoing it" "ignoring a line that is not KEY=value" "$OUT"
hasnt "config: junk line content not echoed (could be a secret)" "not a setting line" "$OUT"
hasnt "config: passphrase never printed" "pa ss" "$OUT"
has   "config: spreading factor with spaces around =" "spreading:     9" "$OUT"

# ---------------------------------------------------------------- precedence
plan --config "$T/a.conf" --spreadingfactor 7
has   "precedence: command line wins" "spreading:     7" "$OUT"
plan --config "$T/a.conf" --no-transport
has   "precedence: flags work with a file" "transport:     no" "$OUT"

# -------------------------------------------------------------- relative paths
mkdir -p "$T/d"
printf 'network: {version: 2}\n' > "$T/d/np.yaml"
printf 'NETPLAN_FILE=np.yaml\n' > "$T/d/rel.conf"
plan --config "$T/d/rel.conf"
has   "paths: relative to the config file's directory" "netplan file:  $T/d/np.yaml" "$OUT"

# ------------------------------------------------------- generated RNS config
printf 'x' > "$T/ifacpass"
plan --preamble 18 --no-rnode-framing --interface-mode gateway --ifac-netname "my net" \
     --ifac-passphrase-file "$T/ifacpass" --tcp-server-port 4242 --tcp-client hub.example.org:4242 --tcp-client 192.0.2.7:4965 \
     --frequency 868000000 --bandwidth 250000 --spreadingfactor 10 --codingrate 6 --txpower 14
RNS="$(sed -n '/generated Reticulum config/,$p' <<<"$OUT")"
has   "rns: framing off written" "rnode_framing = no" "$RNS"
has   "rns: radio overrides" "frequency = 868000000" "$RNS"
has   "rns: bandwidth" "bandwidth = 250000" "$RNS"
has   "rns: preamble" "preamble = 18" "$RNS"
has   "rns: interface mode" "mode = gateway" "$RNS"
has   "rns: IFAC name quoted" 'network_name = "my net"' "$RNS"
has   "rns: IFAC passphrase present but masked" "passphrase = <hidden>" "$RNS"
hasnt "rns: IFAC passphrase value not shown" 'passphrase = "x"' "$RNS"
has   "rns: TCP server" "listen_port = 4242" "$RNS"
has   "rns: first TCP client" "target_host = hub.example.org" "$RNS"
has   "rns: second TCP client numbered" "[[TCP Client 2]]" "$RNS"
has   "rns: second TCP client port" "target_port = 4965" "$RNS"
plan --no-autointerface --no-transport
RNS="$(sed -n '/generated Reticulum config/,$p' <<<"$OUT")"
has   "rns: transport off" "enable_transport = no" "$RNS"
hasnt "rns: AutoInterface removed" "AutoInterface" "$RNS"
printf '[reticulum]\n' > "$T/own.conf"
plan --reticulum-config "$T/own.conf" --frequency 915000000
has   "rns: own config makes other radio options moot (warned)" "are ignored" "$OUT"
hasnt "rns: no generated config shown when you bring your own" "generated Reticulum config" "$OUT"

# ------------------------------------------------------------ netplan preview
plan --wifi-ssid 'Cafe "Net"' --wifi-pass 'p"a\ss: word#1 ' --wifi-hidden \
     --eth-mode static --eth-address 192.0.2.10/24 --eth-gateway 192.0.2.1 --eth-dns 192.0.2.1,192.0.2.2
NP="$(sed -n '/generated netplan/,/generated Reticulum config/p' <<<"$OUT" | sed '1d;$d')"
has   "netplan: password masked in the preview" "password: <hidden>" "$NP"
hasnt "netplan: password value never shown" 'p"a' "$NP"
python3 - "$NP" <<'PY' && ok "netplan: preview is valid YAML with the right structure" || bad "netplan: preview structure"
import sys, yaml
d = yaml.safe_load(sys.argv[1])["network"]
eth = d["ethernets"]["end0"]
ap = d["wifis"]["wlan0"]["access-points"]
assert d["renderer"] == "NetworkManager" and d["version"] == 2
assert eth["addresses"] == ["192.0.2.10/24"] and eth["dhcp4"] is False
assert eth["routes"] == [{"to": "0.0.0.0/0", "via": "192.0.2.1"}]
assert eth["nameservers"]["addresses"] == ["192.0.2.1", "192.0.2.2"]
assert list(ap) == ['Cafe "Net"'] and ap['Cafe "Net"']["hidden"] is True
PY
plan --eth-mode dhcp
has   "netplan: DHCP Ethernet" "dhcp4: true" "$OUT"
plan --wifi-ssid OpenCafe --wifi-open
has   "netplan: open network has no password key" "OpenCafe: {}" "$OUT"

# --------------------------------------------- duplicate definitions are refused
printf 'network:\n  version: 2\n  wifis:\n    wlan0:\n      access-points:\n        "Taken":\n          password: "whatever123"\n' > "$T/netplan/10-existing.yaml"
plan_fail "guard: an SSID already defined elsewhere" "already defined in" --wifi-ssid Taken --wifi-pass password123
plan_ok   "guard: a different SSID is fine" --wifi-ssid Different --wifi-pass password123
printf 'network:\n  version: 2\n  ethernets:\n    end0:\n      dhcp4: true\n' > "$T/netplan/20-eth.yaml"
plan_fail "guard: Ethernet interface already defined elsewhere" "end0 is already defined in" --eth-mode dhcp
plan_ok   "guard: Ethernet mode keep ignores that" --eth-mode keep --hostname still-fine
if [[ "$EUID" -ne 0 ]]; then
    printf 'network: {}\n' > "$T/netplan/30-secret.yaml"; chmod 000 "$T/netplan/30-secret.yaml"
    plan --eth-mode static --eth-address 192.0.2.5/24 --wifi-ssid Another --wifi-pass password123
    rm -f "$T/netplan/20-eth.yaml"
    plan --wifi-ssid Another --wifi-pass password123
    if [[ $RC -eq 0 && "$OUT" == *"not checked for duplicates"* ]]; then ok "guard: an unreadable file is skipped with a note (dry run as a normal user)"; else bad "guard: unreadable file" "$OUT"; fi
    chmod 600 "$T/netplan/30-secret.yaml"
fi
rm -f "$T/netplan/"*.yaml

# ------------------------------------------------------------- OS settings
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest user@host\n# comment\n\nssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7 other@host\n' > "$T/keys"
plan --hostname bobcat-1 --timezone America/New_York --ssh-key-file "$T/keys" \
     --root-password-hash '$6$salt$abcdefghijklmnop' --skip-first-login-wizard
has   "os: hostname" "hostname:      bobcat-1" "$OUT"
has   "os: timezone" "timezone:      America/New_York" "$OUT"
has   "os: two keys counted (comments and blanks ignored)" "ssh keys:      2" "$OUT"
has   "os: root password announced without the hash" "will be set from the hash" "$OUT"
hasnt "os: hash never printed" 'abcdefghijklmnop' "$OUT"
has   "os: wizard" "will be skipped" "$OUT"

plan --user alice --user-password-hash '$6$salt$abcdefghijklmnop' --user-sudo
has   "user: announced with sudo" "extra user:    alice (with sudo" "$OUT"
hasnt "user: hash never printed" 'abcdefghijklmnop' "$OUT"
plan --user bob --user-password-hash '$6$salt$abcdefghijklmnop'
has   "user: without sudo by default" "extra user:    bob (no sudo" "$OUT"
printf 'USER_NAME=carol\nUSER_PASSWORD_HASH=$6$s$h\nUSER_SUDO=yes\n' > "$T/user.conf"
plan --config "$T/user.conf"
has   "user: the settings file keys work" "extra user:    carol (with sudo" "$OUT"
plan --user dave --user-ssh-key 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest a@b' --user-ssh-key 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7 c@d'
has   "user: key-only user, two keys counted" "extra user:    dave (no sudo, password none, ssh keys: 2, github keys: 0)" "$OUT"
plan --user erin --user-ssh-github-user octocat
has   "user: a GitHub-keys-only user is accepted" "extra user:    erin (no sudo, password none, ssh keys: 0, github keys: 1)" "$OUT"
plan --hostname x
has   "user: none by default" "extra user:    none" "$OUT"


# ---------------------------------------------------------------- web interface
WH='pbkdf2-sha256$200000$00112233445566778899aabbccddeeff$aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899'
plan --webui --webui-password-hash "$WH"
has   "webui: announced with the release and the default port" "web interface: yes (rnsd-webui v" "$OUT"
has   "webui: default port 8443" "https on port 8443" "$OUT"
hasnt "webui: the hash is never printed" "aabbccddeeff00112233" "$OUT"
plan --webui --webui-password-hash "$WH" --webui-port 9443
has   "webui: a chosen port" "https on port 9443" "$OUT"
printf 'WEBUI=yes\nWEBUI_PASSWORD_HASH=%s\nWEBUI_PORT=8444\n' "$WH" > "$T/webui.conf"
plan --config "$T/webui.conf"
has   "webui: the settings file keys work" "https on port 8444" "$OUT"
plan --hostname x
has   "webui: off by default" "web interface: no" "$OUT"
plan_ok "webui: scrypt hashes are accepted too" --webui --webui-password-hash 'scrypt$16384$8$1$00ff$aabb'
plan_fail "reject: webui without a password hash" "needs WEBUI_PASSWORD_HASH" --webui
plan_fail "reject: webui password given as plain text" "not a password" --webui --webui-password-hash hunter2
plan_fail "reject: a webui hash without the webui" "needs WEBUI=yes" --webui-password-hash "$WH"
plan_fail "reject: webui port out of range" "WEBUI_PORT must be" --webui --webui-password-hash "$WH" --webui-port 70000
plan_fail "reject: webui port equal to the Reticulum TCP port" "must differ" --webui --webui-password-hash "$WH" --webui-port 4242 --tcp-server-port 4242


# ----------------------------------------------------------------- rejections
plan_fail "reject: user without a password hash or key" "needs USER_PASSWORD_HASH" --user alice
plan_fail "reject: user password as plain text" "crypt(3) hash" --user alice --user-password-hash hunter2
plan_fail "reject: user named root" "second user" --user root --user-password-hash '$6$s$h'
plan_fail "reject: bad user name" "user name must be" --user 'Bad Name' --user-password-hash '$6$s$h'
plan_fail "reject: user password without a name" "need USER_NAME" --user-password-hash '$6$s$h'
plan_fail "reject: a user key with options" "USER_SSH_KEY is not a plain public key" --user alice --user-ssh-key 'command="id" ssh-ed25519 AAAAC3Nza x'
plan_fail "reject: sudo for a key-only user" "USER_SUDO needs" --user alice --user-ssh-key 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest a@b' --user-sudo
plan_fail "reject: bad GitHub name for the user" "not a valid GitHub username" --user erin --user-ssh-github-user 'bad--name'
plan_fail "reject: GitHub keys without a user name" "need USER_NAME" --user-ssh-github-user octocat
plan_fail "reject: sudo without a name" "need USER_NAME" --user-sudo
plan_fail "reject: spreading factor" "spreadingfactor must be 7-12" --spreadingfactor 13
plan_fail "reject: bandwidth 62.5 kHz" "bandwidth must be 125000" --bandwidth 62500
plan_fail "reject: tx power above the table" "txpower must be 12-16" --txpower 27
plan_fail "reject: frequency out of range" "frequency must be between" --frequency 100000000
plan_fail "reject: preamble" "preamble must be 6-1000" --preamble 2
plan_fail "reject: not a number" "must be a whole number" --codingrate five
plan_fail "reject: interface mode" "interface mode must be" --interface-mode turbo
plan_fail "reject: IFAC name with a quote" "must not contain a newline, a double quote" --ifac-netname 'a"b'
plan_fail "reject: TCP port" "TCP server port must be 1-65535" --tcp-server-port 70000
plan_fail "reject: TCP client format" "must look like host:port" --tcp-client nohostport
plan_fail "reject: TCP client port range" "port out of range" --tcp-client host:99999
plan_fail "reject: missing Reticulum config" "cannot read Reticulum config" --reticulum-config /nonexistent
plan_fail "reject: wifi without passphrase" "no Wi-Fi passphrase" --wifi-ssid Net
plan_fail "reject: short passphrase" "8-63 characters" --wifi-ssid Net --wifi-pass short
plan_fail "reject: open network with passphrase" "contradictory" --wifi-ssid Net --wifi-open --wifi-pass longenough1
plan_fail "reject: SSID too long" "SSID must be 1-32 bytes" --wifi-ssid "$(printf 'x%.0s' {1..33})" --wifi-pass longenough1
plan_fail "reject: wifi options without an SSID" "need a Wi-Fi SSID" --wifi-hidden
plan_fail "reject: static Ethernet without an address" "needs an address like" --eth-mode static
plan_fail "reject: bad static address" "needs an address like" --eth-mode static --eth-address 300.1.1.1/24
plan_fail "reject: bad gateway" "gateway must be an IPv4" --eth-mode static --eth-address 192.0.2.10/24 --eth-gateway nope
plan_fail "reject: bad DNS" "is not an IPv4 address" --eth-mode static --eth-address 192.0.2.10/24 --eth-dns 192.0.2.1,x
plan_fail "reject: Ethernet details without static mode" "need Ethernet mode 'static'" --eth-address 192.0.2.10/24
plan_fail "reject: unknown Ethernet mode" "must be dhcp, static or keep" --eth-mode magic
plan_fail "reject: netplan file plus Wi-Fi" "cannot be combined" --netplan-file "$T/d/np.yaml" --wifi-ssid Net --wifi-open
plan_fail "reject: netplan file plus static Ethernet" "cannot be combined" --netplan-file "$T/d/np.yaml" --eth-mode dhcp
plan_fail "reject: missing netplan file" "cannot read netplan file" --netplan-file /nonexistent
plan_fail "reject: hostname" "hostname must be" --hostname "-bad-"
plan_fail "reject: timezone traversal" "is not valid" --timezone "../../etc/passwd"
plan_fail "reject: root password given as plain text" "crypt(3) hash" --root-password-hash hunter2
printf 'command="rm -rf /" ssh-ed25519 AAAAC3Nza evil\n' > "$T/badkey"
plan_fail "reject: SSH key with options" "not a plain public key" --ssh-key-file "$T/badkey"
plan_fail "reject: missing config file" "cannot read config file" --config /nonexistent
plan_fail "reject: missing option value" "needs a value" --frequency
plan_fail "reject: unknown option" "unknown option" --bogus
printf 'WIFI_HIDDEN=maybe\n' > "$T/badbool.conf"
plan_fail "reject: bad yes/no in a config file" "is not yes/no" --config "$T/badbool.conf"
plan_fail "reject: revert timeout too short" "at least 30" --revert-after 5

# ---------------------------------------------------- an existing file in the way
mkdir -p "$T/np-guard"
plan_ok "accepts a valid full set of options together" --hostname b1 --frequency 915000000 --eth-mode dhcp --wifi-ssid N1 --wifi-open

# ---------------------------------------------------------------- stateful parts
# Source the installer and call single functions against temporary directories.
call() {   # call <body> [installer args...]: runs <body> in a fresh shell with the functions loaded
    local body="$1"; shift
    env BOBCAT_SOURCE_ONLY=1 BOBCAT_PREFIX="$T/prefix" BOBCAT_RETICULUM_DIR="$T/rns" BOBCAT_STATE_DIR="$T/state" \
        BASH_ENV=/dev/null bash -c 'src="$1"; shift; body="$1"; shift; . "$src" "$@"; eval "$body"' _ "$INSTALLER" "$body" "$@" 2>&1
}
mkdir -p "$T/prefix/sx1302_rns/interfaces"

# web interface unit file
WH='pbkdf2-sha256$200000$00112233445566778899aabbccddeeff$aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899'
out="$(call 'render_webui_unit' --webui --webui-password-hash "$WH" --webui-port 9443)"
has   "webui unit: runs the venv's rnsd-webui on the chosen port with TLS" "rnsd-webui --listen 0.0.0.0:9443" "$out"
has   "webui unit: uses the generated certificate" "--tls-cert /var/lib/rnsd-webui/tls/cert.pem" "$out"
has   "webui unit: starts after the radio service" "rnsd-sx1302.service" "$out"
has   "webui unit: hardened" "ProtectSystem=strict" "$out"
hasnt "webui unit: no password or hash in the unit" "pbkdf2" "$out"


# Clock wait: returns at once when synced, gives up (not fatal) when it never does
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "${STUB_NTP:-yes}"\n' > "$T/bin/timedatectl"; chmod +x "$T/bin/timedatectl"
out="$(PATH="$T/bin:$PATH" STUB_NTP=yes call 'wait_for_clock')"; rc=$?
check "clock: already synced returns at once and quietly" "$rc:$out" "0:"
out="$(PATH="$T/bin:$PATH" STUB_NTP=no BOBCAT_CLOCK_WAIT=2 call 'wait_for_clock')"; rc=$?
has   "clock: an unsynced clock is waited for, then reported, not fatal" "did not sync within 2s" "$out"
check "clock: giving up still returns success" "$rc" 0

# Reticulum config: written, regenerated while untouched, kept once edited.
out="$(call 'write_config' --frequency 915000000)"
[[ -f "$T/rns/config" && -f "$T/rns/.bobcat-config.sha256" ]] && ok "rns config: written with a checksum stamp" || bad "rns config: written with a checksum stamp" "$out"
check_mode="$(stat -c %a "$T/rns/config")"; [[ "$check_mode" == 600 ]] && ok "rns config: root-only (it can hold IFAC secrets)" || bad "rns config: root-only" "$check_mode"
has   "rns config: contains the radio setting" "frequency = 915000000" "$(cat "$T/rns/config")"
out="$(call 'write_config' --frequency 868000000)"
has   "rns config: untouched file is rewritten when settings change" "frequency = 868000000" "$(cat "$T/rns/config")"
has   "rns config: the old one is backed up" "old config backed up" "$out"
echo "# my hand edit" >> "$T/rns/config"
out="$(call 'write_config' --frequency 915000000)"
has   "rns config: edited file is kept" "edited by hand" "$out"
has   "rns config: edit survives" "my hand edit" "$(cat "$T/rns/config")"
out="$(call 'write_config' --frequency 915000000 --force-config)"
: > "$T/rns/config"; : > "$T/rns/.bobcat-config.sha256"     # what a reset before the flush leaves behind
out="$(call 'write_config' --frequency 915000000)"
has   "rns config: an empty file (left by a reset) is replaced, not kept" "frequency = 915000000" "$(cat "$T/rns/config")"
hasnt "rns config: an empty file is not called hand-edited" "edited by hand" "$out"
out="$(call 'write_config' --frequency 915000000 --force-config)"
hasnt "rns config: --force-config replaces it" "my hand edit" "$(cat "$T/rns/config")"
printf '[reticulum]\n  enable_transport = no\n  [[Other]]\n    type = AutoInterface\n' > "$T/own.conf"
out="$(call 'write_config' --reticulum-config "$T/own.conf")"
has   "rns config: your own file is installed as given" "[[Other]]" "$(cat "$T/rns/config")"
has   "rns config: warns when it has no SX1302 interface" "no 'type = SX1302' interface" "$out"

# Saved settings: copied next to the system, paths rewritten, side files kept.
mkdir -p "$T/src"
printf 'ssh-ed25519 AAAAC3Nza one@host\n' > "$T/src/keys.pub"
printf '[reticulum]\n' > "$T/src/my-reticulum.conf"
printf 'FREQUENCY=915000000\r\nSSH_AUTHORIZED_KEYS_FILE=keys.pub\nRETICULUM_CONFIG_FILE=my-reticulum.conf\n' > "$T/src/my.conf"
out="$(call 'persist_config' --config "$T/src/my.conf")"
saved="$(cat "$T/state/install.conf" 2>/dev/null)"
has   "saved settings: copied to the state directory" "FREQUENCY=915000000" "$saved"
hasnt "saved settings: CRLF removed" $'\r' "$saved"
has   "saved settings: key file path rewritten to the copy" "SSH_AUTHORIZED_KEYS_FILE=$T/state/files/keys.pub" "$saved"
has   "saved settings: Reticulum config path rewritten" "RETICULUM_CONFIG_FILE=$T/state/files/my-reticulum.conf" "$saved"
[[ -f "$T/state/files/keys.pub" && -f "$T/state/files/my-reticulum.conf" ]] && ok "saved settings: referenced files copied" || bad "saved settings: referenced files copied" "$out"
check_mode="$(stat -c %a "$T/state/install.conf") $(stat -c %a "$T/state/files/keys.pub") $(stat -c %a "$T/state")"
[[ "$check_mode" == "600 600 700" ]] && ok "saved settings: everything root-only" || bad "saved settings: everything root-only" "$check_mode"
out="$(call 'persist_config' --config "$T/state/install.conf")"
[[ "$(cat "$T/state/install.conf")" == "$saved" ]] && ok "saved settings: a file already in the state directory is left alone" || bad "saved settings: re-run leaves it alone"

# ------------------------------------------------------------- self-recovery
plan_ok "recovery: on by default (dry run)"
has   "recovery: plan says so" "self-recovery: on" "$OUT"
has   "recovery: default reboot threshold" "reboot after 20 minutes" "$OUT"
plan --netwatch-target 192.0.2.1 --netwatch-reboot-minutes 0
has   "recovery: options show in the plan" "pings 192.0.2.1; reboot after never" "$OUT"
plan --no-resilience
has   "recovery: can be turned off" "self-recovery: off" "$OUT"
printf 'RESILIENCE=no\nNETWATCH_REBOOT_MINUTES=45\nNETWATCH_TARGET=router.lan\n' > "$T/res.conf"
plan --config "$T/res.conf"
has   "recovery: settings file can turn it off" "self-recovery: off" "$OUT"
printf 'NETWATCH_REBOOT_MINUTES=45\nNETWATCH_TARGET=router.lan\n' > "$T/res2.conf"
plan --config "$T/res2.conf"
has   "recovery: settings file sets minutes and target" "pings router.lan; reboot after 45 minutes" "$OUT"
plan_fail "reject: reboot minutes too small" "must be 0 (never) or 5-1440" --netwatch-reboot-minutes 2
plan_fail "reject: reboot minutes too large" "must be 0 (never) or 5-1440" --netwatch-reboot-minutes 5000
plan_fail "reject: reboot minutes not a number" "must be 0 (never) or 5-1440" --netwatch-reboot-minutes soon
plan_fail "reject: target with a space" "host name or IP address" --netwatch-target "a b"
plan_fail "reject: target that is a command" "host name or IP address" --netwatch-target '$(id)'
plan_fail "reject: log days out of range" "log keep days must be 1-365" --log-keep-days 0
plan_fail "reject: log days not a number" "log keep days must be 1-365" --log-keep-days forever
plan_fail "reject: log cap out of range" "log size cap must be 20-2000 MB" --log-max-mb 5
plan --log-keep-days 7 --log-max-mb 200
has   "recovery: log settings show in the plan" "kept 7 days, rotated archives capped at 200 MB" "$OUT"

# Real file placement, against temporary directories with recording stubs.
mkdir -p "$T/stubbin" "$T/prefix/bobcat-g295"
cp -r "$HERE/../bobcat-g295/resilience" "$T/prefix/bobcat-g295/"
for c in systemctl sysctl journalctl; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/syscalls"\n' "$c" "$T" > "$T/stubbin/$c"
done
chmod +x "$T/stubbin/"*
export BOBCAT_SYSTEMD_DIR="$T/etc-systemd" BOBCAT_SBIN_DIR="$T/sbin" BOBCAT_SYSCTL_DIR="$T/sysctl.d" BOBCAT_WATCHDOG_DEV="$T/watchdog0"
: > "$T/watchdog0"
callr() { : > "$T/syscalls"; PATH="$T/stubbin:$PATH" call "$@"; }
sysc() { cat "$T/syscalls"; }

out="$(callr setup_resilience)"; rc=$?
check "recovery install: succeeds" "$rc" 0
check "recovery install: watcher and pruner scripts are executable" "$(stat -c %a "$T/sbin/bobcat-netwatch") $(stat -c %a "$T/sbin/bobcat-logprune")" "755 755"
for f in bobcat-netwatch.service bobcat-netwatch.timer bobcat-logflush.service bobcat-logflush.timer bobcat-logprune.service bobcat-logprune.timer; do
    [[ -f "$T/etc-systemd/system/$f" ]] && ok "recovery install: $f in place" || bad "recovery install: $f in place"
done
[[ -f "$T/etc-systemd/journald.conf.d/10-bobcat-journal.conf" ]] && ok "recovery install: persistent journal setting" || bad "recovery install: persistent journal setting"
has   "recovery install: journal is set to persistent" "Storage=persistent" "$(cat "$T/etc-systemd/journald.conf.d/10-bobcat-journal.conf")"
[[ -f "$T/sysctl.d/10-bobcat-panic.conf" ]] && ok "recovery install: panic setting" || bad "recovery install: panic setting"
[[ -f "$T/etc-systemd/system.conf.d/10-bobcat-watchdog.conf" ]] && ok "recovery install: hardware watchdog armed when the device exists" || bad "recovery install: watchdog drop-in"
has   "recovery install: watchdog drop-in content" "RuntimeWatchdogSec=30s" "$(cat "$T/etc-systemd/system.conf.d/10-bobcat-watchdog.conf")"
check "recovery install: netwatch settings written" "$(cat "$T/state/netwatch.conf" | grep -v '^#')" "REBOOT_MINUTES=20"
has   "recovery install: systemd reloaded then re-executed" "systemctl daemon-reexec" "$(sysc)"
has   "recovery install: journald restarted" "systemctl restart systemd-journald" "$(sysc)"
has   "recovery install: journal flushed" "journalctl --flush" "$(sysc)"
has   "recovery install: panic sysctl applied" "sysctl -q -p $T/sysctl.d/10-bobcat-panic.conf" "$(sysc)"
has   "recovery install: all three timers enabled and started" "systemctl enable --now bobcat-netwatch.timer bobcat-logflush.timer bobcat-logprune.timer" "$(sysc)"
has   "recovery install: journal retention follows the keep-days setting" "MaxRetentionSec=14day" "$(cat "$T/etc-systemd/journald.conf.d/10-bobcat-journal.conf")"
hasnt "recovery install: no placeholder left in the journal setting" "@KEEP_DAYS@" "$(cat "$T/etc-systemd/journald.conf.d/10-bobcat-journal.conf")"
has   "recovery install: firm journal limits" "SystemKeepFree=1G" "$(cat "$T/etc-systemd/journald.conf.d/10-bobcat-journal.conf")"
check "recovery install: log settings written" "$(grep -v '^#' "$T/state/logs.conf" | paste -sd' ')" "LOG_KEEP_DAYS=14 LOG_MAX_MB=100"
order="$(grep -nE 'daemon-reload|daemon-reexec|enable' "$T/syscalls" | cut -d: -f2- | tr '\n' ';')"
has   "recovery install: reload before re-exec before enabling" "systemctl daemon-reload;systemctl daemon-reexec;" "$order"

out="$(callr setup_resilience --netwatch-target 198.51.100.1 --netwatch-reboot-minutes 0 --log-keep-days 3 --log-max-mb 50)"
check "recovery install: custom settings" "$(grep -v '^#' "$T/state/netwatch.conf" | paste -sd' ')" "REBOOT_MINUTES=0 TARGET=198.51.100.1"
check "recovery install: custom log settings" "$(grep -v '^#' "$T/state/logs.conf" | paste -sd' ') $(grep -c 'MaxRetentionSec=3day' "$T/etc-systemd/journald.conf.d/10-bobcat-journal.conf")" "LOG_KEEP_DAYS=3 LOG_MAX_MB=50 1"
out="$(callr setup_resilience)"
check "recovery install: re-run is clean and resets to defaults" "$(grep -v '^#' "$T/state/netwatch.conf")" "REBOOT_MINUTES=20"

rm -f "$T/watchdog0"; rm -f "$T/etc-systemd/system.conf.d/10-bobcat-watchdog.conf"
out="$(callr setup_resilience)"
[[ ! -e "$T/etc-systemd/system.conf.d/10-bobcat-watchdog.conf" ]] && ok "recovery install: no watchdog drop-in without the device" || bad "recovery install: watchdog without device"
has   "recovery install: and says why" "no hardware watchdog device" "$out"
: > "$T/watchdog0"

out="$(callr setup_resilience --no-start)"
has   "recovery install: --no-start enables without starting" "systemctl enable bobcat-netwatch.timer bobcat-logflush.timer bobcat-logprune.timer" "$(sysc)"
hasnt "recovery install: --no-start does not start them" "enable --now" "$(sysc)"

out="$(callr setup_resilience --no-resilience)"
left=0; for f in "$T"/sbin/bobcat-* "$T"/etc-systemd/system/bobcat-* "$T"/etc-systemd/journald.conf.d/10-bobcat-* "$T"/sysctl.d/10-bobcat-* "$T/state/netwatch.conf" "$T/state/logs.conf"; do [[ -e "$f" ]] && left=$((left + 1)); done
check "recovery removal: files gone" "$left" 0
has   "recovery removal: timers disabled" "systemctl disable --now bobcat-netwatch.timer" "$(sysc)"
out="$(callr setup_resilience --no-resilience)"
has   "recovery removal: removing twice is harmless" "nothing to remove" "$out"

mv "$T/prefix/bobcat-g295/resilience" "$T/prefix/resilience.away"
out="$(callr setup_resilience)"; rc=$?
[[ "$rc" -ne 0 && "$out" == *"missing from the bundle"* ]] && ok "recovery install: a bundle without the files fails clearly" || bad "recovery install: missing files" "$out"
mv "$T/prefix/resilience.away" "$T/prefix/bobcat-g295/resilience"
unset BOBCAT_SYSTEMD_DIR BOBCAT_SBIN_DIR BOBCAT_SYSCTL_DIR BOBCAT_WATCHDOG_DEV

# ------------------------------------------------- internet needed? checked first
# Stubs stand in for the system state: what is installed, and whether the net answers.
inet() {   # inet <body>: run <body> with net_ok/missing_packages/venv overridable
    call 'wait_for() { shift; "$@"; }; '"$1" "${@:2}"
}
mkdir -p "$T/prefix/venv/bin"
out="$(inet 'missing_packages() { :; }; net_ok() { return 1; }; internet_needs() { :; }; precheck_internet')"; rc=$?
check "internet: not needed -> no check, no failure" "$rc" 0
has   "internet: says so" "nothing here needs the internet" "$out"
out="$(inet 'missing_packages() { echo gcc; }; net_ok() { return 1; }; internet_needs() { echo "installing system packages"; }; precheck_internet')"; rc=$?
[[ "$rc" -ne 0 && "$out" == *"needs internet access for: installing system packages"* ]] && ok "internet: needed but absent stops the install before any change" || bad "internet: needed but absent" "$out"
has   "internet: and explains a gateway that answers is not enough" "a gateway that answers is not enough" "$out"
has   "internet: and says nothing was changed" "nothing was changed" "$out"
out="$(inet 'net_ok() { return 0; }; internet_needs() { echo "installing Reticulum from PyPI"; }; precheck_internet')"; rc=$?
check "internet: needed and present passes" "$rc" 0
out="$(inet 'missing_packages() { :; }; net_ok() { return 1; }; precheck_internet' --ssh-github-user alice)"; rc=$?
[[ "$rc" -ne 0 && "$out" == *"fetching SSH keys from GitHub"* ]] && ok "internet: GitHub keys count as needing it" || bad "internet: GitHub keys" "$out"
out="$(inet 'missing_packages() { :; }; internet_needs')"
has   "internet: a venv without Reticulum needs PyPI" "installing Reticulum from PyPI" "$out"
# a stand-in interpreter: exit status 0 = "Reticulum importable and registered here"
printf '#!/bin/sh\nexit 0\n' > "$T/prefix/venv/bin/python"; chmod +x "$T/prefix/venv/bin/python"
out="$(inet 'missing_packages() { :; }; internet_needs')"
check "internet: an installed, registered venv needs nothing" "$out" ""
printf '#!/bin/sh\nexit 1\n' > "$T/prefix/venv/bin/python"
out="$(inet 'missing_packages() { :; }; internet_needs')"
has   "internet: registered somewhere else counts as needing a reinstall" "installing Reticulum from PyPI" "$out"
rm -f "$T/prefix/venv/bin/python"

# ------------------------------------------------------- GitHub public keys
# A fake GitHub on localhost serves /<user>.keys; anything else is a 404.
KEYA='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIalice1 alice@laptop'
KEYB='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCalice2 alice@desktop'
KEYC='ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbob1 bob@host'
mkdir -p "$T/gh"
printf '%s\n%s\n' "$KEYA" "$KEYB" > "$T/gh/alice.keys"
printf '%s\n' "$KEYC" > "$T/gh/bob.keys"
: > "$T/gh/empty.keys"
printf 'not a key at all\ncommand="rm -rf /" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIevil evil@x\n%s\n' "$KEYC" > "$T/gh/junk.keys"
printf 'ssh-dss AAAAB3NzaC1kc3MAAACBAold old@x\n' > "$T/gh/onlyjunk.keys"
cat > "$T/ghserver.py" <<'PY'
import functools, http.server, socketserver, sys
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
srv = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(H, directory=sys.argv[1]))
open(sys.argv[2], "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$T/ghserver.py" "$T/gh" "$T/ghport" &
GH_PID=$!
trap 'kill "$GH_PID" 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 1 50); do [[ -s "$T/ghport" ]] && break; sleep 0.1; done
GH_PORT="$(cat "$T/ghport" 2>/dev/null)"

if [[ -z "$GH_PORT" ]]; then
    bad "github: could not start the fake GitHub"
else
    export BOBCAT_GITHUB_URL="http://127.0.0.1:$GH_PORT" BOBCAT_SSH_DIR="$T/ssh" BOBCAT_GITHUB_RETRY_DELAY=0
    keys_in() { grep -vE '^(#|$)' "$T/ssh/authorized_keys" 2>/dev/null | wc -l | tr -d ' '; }

    out="$(call 'setup_os' --ssh-github-user alice)"; rc=$?
    check "github: fetch succeeds" "$rc" 0
    check "github: both of alice's keys were added" "$(keys_in)" 2
    has   "github: the first key is in authorized_keys" "$KEYA" "$(cat "$T/ssh/authorized_keys")"
    has   "github: the second key is in authorized_keys" "$KEYB" "$(cat "$T/ssh/authorized_keys")"
    has   "github: where the keys came from is noted" "# keys published by GitHub user alice" "$(cat "$T/ssh/authorized_keys")"
    check "github: file is root-only" "$(stat -c %a "$T/ssh/authorized_keys") $(stat -c %a "$T/ssh")" "600 700"
    out="$(call 'setup_os' --ssh-github-user alice)"; rc=$?
    check "github: a re-run adds nothing" "$(keys_in)" 2
    has   "github: and says so" "0 added (2 found)" "$out"

    rm -rf "$T/ssh"
    printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAImine mine@here' > "$T/mine.pub"
    out="$(call 'setup_os' --ssh-key-file "$T/mine.pub" --ssh-github-user alice --ssh-github-user bob)"; rc=$?
    check "github: several users plus your own key" "$rc $(keys_in)" "0 4"
    has   "github: your own key is kept" "mine@here" "$(cat "$T/ssh/authorized_keys")"
    has   "github: the second user's key is there" "$KEYC" "$(cat "$T/ssh/authorized_keys")"

    rm -rf "$T/ssh"
    out="$(call 'setup_os' --ssh-github-user nosuchuser)"; rc=$?
    [[ "$rc" -ne 0 ]] && ok "github: an unknown user stops the install" || bad "github: an unknown user stops the install" "$out"
    has   "github: with a clear message" "'nosuchuser' was not found" "$out"
    check "github: nothing half-written" "$(keys_in)" 0

    out="$(call 'setup_os' --ssh-github-user empty)"; rc=$?
    [[ "$rc" -ne 0 && "$out" == *"has no usable SSH public keys"* ]] && ok "github: a user with no keys stops the install" || bad "github: a user with no keys stops the install" "$out"
    out="$(call 'setup_os' --ssh-github-user onlyjunk)"; rc=$?
    [[ "$rc" -ne 0 && "$out" == *"has no usable SSH public keys"* ]] && ok "github: only unusable key types stops the install" || bad "github: only unusable key types" "$out"

    rm -rf "$T/ssh"
    out="$(call 'setup_os' --ssh-github-user junk)"; rc=$?
    check "github: junk lines are skipped when a real key exists" "$rc $(keys_in)" "0 1"
    hasnt "github: option-prefixed keys never reach authorized_keys" "rm -rf" "$(cat "$T/ssh/authorized_keys")"
    has   "github: junk is reported" "not a plain public key" "$out"

    rm -rf "$T/ssh"
    out="$(BOBCAT_GITHUB_URL="http://127.0.0.1:1" call 'setup_os' --ssh-github-user alice)"; rc=$?
    [[ "$rc" -ne 0 && "$out" == *"could not reach GitHub"* ]] && ok "github: an unreachable GitHub stops the install (it retries on the next boot attempt)" || bad "github: unreachable" "$out"

    printf 'SSH_GITHUB_USER=alice\nSSH_GITHUB_USER=bob\n' > "$T/gh.conf"
    plan --config "$T/gh.conf" --ssh-github-user carol
    has   "github: config keys and options combine (dry run)" "github keys:   alice bob carol" "$OUT"
    has   "github: the dry run does not fetch" "(fetched at install time)" "$OUT"
    unset BOBCAT_GITHUB_URL BOBCAT_SSH_DIR BOBCAT_GITHUB_RETRY_DELAY
fi
plan_fail "reject: GitHub name starting with a hyphen" "not a valid GitHub username" --ssh-github-user -bad
plan_fail "reject: GitHub name ending with a hyphen" "not a valid GitHub username" --ssh-github-user bad-
plan_fail "reject: GitHub name with a double hyphen" "not a valid GitHub username" --ssh-github-user a--b
plan_fail "reject: GitHub name with a path" "not a valid GitHub username" --ssh-github-user "../etc"
plan_fail "reject: GitHub name too long" "not a valid GitHub username" --ssh-github-user "$(printf 'a%.0s' {1..40})"

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[[ "$failed" -eq 0 ]]
