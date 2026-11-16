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

# ----------------------------------------------------------------- rejections
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

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[[ "$failed" -eq 0 ]]
