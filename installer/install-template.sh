#!/usr/bin/env bash
#
# Bobcat Miner 300 (G290/G295) -> Reticulum LoRa node, one-step installer.
#
# Turns a Bobcat running the community Armbian image (sicXnull/Bobcat-Armbian)
# into a Reticulum node that uses its onboard SX1302 radio as a single
# RNode-compatible LoRa channel. Self-extracting: the code is appended to this
# file, so copying this one file to the node is all that is needed.
#
#   scp bobcat-g295-install.sh root@<bobcat>:  &&  ssh root@<bobcat> ./bobcat-g295-install.sh
#
# Everything can be given as options or as a config file (--config FILE, see
# docs/config-reference.md). Options override the file. --dry-run shows the
# resulting plan without touching anything.
#
# What it does (safe to re-run):
#   1. checks this really is a Bobcat 29x with /dev/spidev5.0
#   2. optionally sets up networking through netplan (Wi-Fi, Ethernet, or your own file)
#   3. optionally applies OS settings (hostname, timezone, SSH keys, root password)
#   4. installs python3-venv, python3-pip, gcc, make, patch, gpiod if missing
#      (never runs apt upgrade; holds the kernel/u-boot packages like the image docs say)
#   5. unpacks the code to /opt/bobcat-lora, builds the HAL, makes a venv with rns
#   6. writes /etc/reticulum/config, links the interface
#   7. installs and starts the rnsd-sx1302 systemd service, then checks the radio is up
#   8. keeps a copy of the config file (and the files it points to) in /etc/bobcat-lora/
#
# Build: @BUILD_INFO@

set -euo pipefail

# Locations can be overridden through the environment (used by the tests).
PREFIX="${BOBCAT_PREFIX:-/opt/bobcat-lora}"
CONFIGDIR="${BOBCAT_RETICULUM_DIR:-/etc/reticulum}"
STATEDIR="${BOBCAT_STATE_DIR:-/etc/bobcat-lora}"
SERVICE="rnsd-sx1302"
PROFILE="$PREFIX/bobcat-g295/bobcat-g295-us915.conf"

# Radio
OPT_FREQ="" OPT_BW="" OPT_SF="" OPT_CR="" OPT_TXP="" OPT_PREAMBLE=""
# Reticulum
OPT_TRANSPORT=1 OPT_AUTOIF=1 OPT_RNODE_FRAMING=1 OPT_IFMODE=""
OPT_IFAC_NET="" OPT_IFAC_PASS="" OPT_IFAC_PASS_FILE=""
OPT_TCP_PORT="" OPT_TCP_CLIENTS=() OPT_RNS_CONFIG=""
# Behaviour
OPT_FORCE_CONFIG=0 OPT_START=1 OPT_HOLD=1 OPT_FORCE_BOARD=0 OPT_EXTRACT_ONLY=""
OPT_DRY_RUN=0 OPT_CONFIG=""
# Network
OPT_WIFI_SSID="" OPT_WIFI_PASS="${BOBCAT_WIFI_PASS:-}" OPT_WIFI_PASS_FILE=""
OPT_WIFI_HIDDEN=0 OPT_WIFI_OPEN=0 OPT_NETPLAN_FILE="" OPT_NO_APPLY=0
OPT_ETH_MODE="" OPT_ETH_ADDR="" OPT_ETH_GW="" OPT_ETH_DNS=""
OPT_NETWORK_ONLY=0 OPT_REVERT_SECS=180
# Operating system
OPT_HOSTNAME="" OPT_TIMEZONE="" OPT_SSH_KEYS="" OPT_SSH_KEYS_FILE=""
OPT_ROOT_HASH="" OPT_SKIP_WIZARD=0

SERVICE_STARTED_AT=""
CURRENT_CONFIG=""

log()  { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<'EOF'
Usage: bobcat-g295-install.sh [options]

Config file:
  --config FILE         read KEY=value settings from FILE (see docs/config-reference.md).
                        Options below override the file. A copy is kept in /etc/bobcat-lora/.
  --dry-run             validate everything and print the plan and the generated
                        configs (secrets masked); change nothing, needs no root

Radio settings (default: 915 MHz, 125 kHz, SF8, CR 4/5, 14 dBm - must match
the other nodes on your network):
  --frequency HZ        e.g. 915000000
  --bandwidth HZ        125000, 250000 or 500000 (the SX1302 cannot do 62.5 kHz)
  --spreadingfactor N   7-12
  --codingrate N        5-8 (4/5 .. 4/8)
  --txpower DBM         12-16 (limit of the shipped TX gain table)
  --preamble N          preamble symbols, 6-1000 (profile default 18, RNode's minimum)

Reticulum:
  --no-transport        do not forward/repeat other nodes' traffic
  --no-autointerface    do not enable the LAN AutoInterface
  --no-rnode-framing    send raw frames (only for talking to another raw node)
  --interface-mode M    full | gateway | access_point | roaming | boundary | pointtopoint
  --ifac-netname NAME   interface access control network name (must match peers)
  --ifac-passphrase-file F   IFAC passphrase, first line of F
  --tcp-server-port N   also listen for Reticulum TCP links on port N (opens a port)
  --tcp-client HOST:PORT  also connect to a Reticulum TCP server (repeatable)
  --reticulum-config F  use F as /etc/reticulum/config instead of generating one
  --force-config        overwrite /etc/reticulum/config even if it was edited by hand

Networking (netplan, rendered by NetworkManager; applied BEFORE packages are
installed, so a node with no cable can get online first):
  --wifi-ssid SSID      join this Wi-Fi network (2.4 GHz only on this hardware)
  --wifi-pass PASS      its passphrase (visible in `ps`/history: prefer one of
                        the next two)
  --wifi-pass-file F    read the passphrase from the first line of file F
                        (or set BOBCAT_WIFI_PASS in the environment)
  --wifi-hidden         the SSID is hidden (not broadcast)
  --wifi-open           the network has no password
  --eth-mode MODE       dhcp | static | keep (default keep: leave Ethernet alone)
  --eth-address CIDR    static address, e.g. 192.168.1.50/24 (with --eth-mode static)
  --eth-gateway IP      default gateway for static Ethernet
  --eth-dns A,B         DNS servers for static Ethernet
  --netplan-file F      install your own netplan YAML instead ("-" = read stdin).
                        Mutually exclusive with the Wi-Fi/Ethernet options.
  --no-apply            write/validate the netplan file but do not apply it
  --network-only        stop after the networking step
  --revert-after SECS   auto-revert a netplan change that leaves no internet
                        after this long (default 180)

Operating system:
  --hostname NAME       set the hostname
  --timezone ZONE       e.g. America/New_York
  --ssh-key-file F      add the public keys in F to root's authorized_keys
  --root-password-hash H   set root's password from a crypt(3) hash (mkpasswd -m sha-512)
  --skip-first-login-wizard   remove Armbian's interactive first-login prompt

Other:
  --no-start            install but do not enable/start the service
  --no-hold             do not apt-mark hold the kernel/u-boot packages
  --force-board         skip the "is this a Bobcat 29x" check
  --extract-only DIR    just unpack the code into DIR and stop
  -h, --help            this help
EOF
}

# ---------------------------------------------------------------------------
# Config file parsing. The file is parsed, never executed; only known keys count.
# ---------------------------------------------------------------------------

to_bool() {
    case "${1,,}" in
        1|yes|true|on)  echo 1 ;;
        0|no|false|off) echo 0 ;;
        *) fail "${CURRENT_CONFIG:+$CURRENT_CONFIG: }'$1' is not yes/no" ;;
    esac
}

abs_path() {   # abs_path <path> <base dir>: empty stays empty
    if [[ -z "$1" ]]; then echo ""
    elif [[ "$1" == /* ]]; then echo "$1"
    else echo "$2/$1"; fi
}

apply_config_key() {
    local key="$1" val="$2" base="$3"
    case "$key" in
        WIFI_SSID)            OPT_WIFI_SSID="$val" ;;
        WIFI_PASS)            OPT_WIFI_PASS="$val" ;;
        WIFI_HIDDEN)          OPT_WIFI_HIDDEN="$(to_bool "$val")" ;;
        WIFI_OPEN)            OPT_WIFI_OPEN="$(to_bool "$val")" ;;
        ETH_MODE)             OPT_ETH_MODE="${val,,}" ;;
        ETH_ADDRESS)          OPT_ETH_ADDR="$val" ;;
        ETH_GATEWAY)          OPT_ETH_GW="$val" ;;
        ETH_DNS)              OPT_ETH_DNS="${val// /}" ;;
        NETPLAN_FILE)         OPT_NETPLAN_FILE="$(abs_path "$val" "$base")" ;;
        HOSTNAME)             OPT_HOSTNAME="$val" ;;
        TIMEZONE)             OPT_TIMEZONE="$val" ;;
        SSH_AUTHORIZED_KEY)   [[ -z "$val" ]] || OPT_SSH_KEYS+="$val"$'\n' ;;
        SSH_AUTHORIZED_KEYS_FILE) OPT_SSH_KEYS_FILE="$(abs_path "$val" "$base")" ;;
        ROOT_PASSWORD_HASH)   OPT_ROOT_HASH="$val" ;;
        SKIP_FIRSTLOGIN_WIZARD) OPT_SKIP_WIZARD="$(to_bool "$val")" ;;
        FREQUENCY)            OPT_FREQ="$val" ;;
        BANDWIDTH)            OPT_BW="$val" ;;
        SPREADINGFACTOR)      OPT_SF="$val" ;;
        CODINGRATE)           OPT_CR="$val" ;;
        TXPOWER)              OPT_TXP="$val" ;;
        PREAMBLE)             OPT_PREAMBLE="$val" ;;
        RNODE_FRAMING)        OPT_RNODE_FRAMING="$(to_bool "$val")" ;;
        TRANSPORT)            OPT_TRANSPORT="$(to_bool "$val")" ;;
        AUTOINTERFACE)        OPT_AUTOIF="$(to_bool "$val")" ;;
        INTERFACE_MODE)       OPT_IFMODE="${val,,}" ;;
        IFAC_NETNAME)         OPT_IFAC_NET="$val" ;;
        IFAC_PASSPHRASE)      OPT_IFAC_PASS="$val" ;;
        TCP_SERVER_PORT)      OPT_TCP_PORT="$val" ;;
        TCP_CLIENT)           [[ -z "$val" ]] || OPT_TCP_CLIENTS+=("$val") ;;
        RETICULUM_CONFIG_FILE) OPT_RNS_CONFIG="$(abs_path "$val" "$base")" ;;
        SCRUB_BOOT_CONF)      : ;;   # used by the first-boot service only
        *)                    warn "$CURRENT_CONFIG: ignoring unknown key $key" ;;
    esac
}

load_config_file() {
    local file="$1" base line key val
    [[ -n "$file" && -r "$file" ]] || fail "cannot read config file '$file'"
    base="$(cd "$(dirname "$file")" && pwd)"
    CURRENT_CONFIG="$file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ "$line" =~ ^[[:space:]]*([A-Z0-9_]+)[[:space:]]*=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            val="${val#"${val%%[![:space:]]*}"}"
            if [[ "$val" =~ ^\"(.*)\"$ ]]; then val="${BASH_REMATCH[1]}"
            elif [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
            apply_config_key "$key" "$val" "$base"
        else
            warn "$file: ignoring a line that is not KEY=value (not shown: it may be a secret)"
        fi
    done < "$file"
    CURRENT_CONFIG=""
}

# The config file is loaded first so that options on the command line win.
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[i]}" == "--config" ]]; then
        OPT_CONFIG="${args[i + 1]:-}"
        [[ -n "$OPT_CONFIG" ]] || fail "--config needs a file"
        load_config_file "$OPT_CONFIG"
        OPT_CONFIG="$(cd "$(dirname "$OPT_CONFIG")" && pwd)/$(basename "$OPT_CONFIG")"
    fi
done

while [[ $# -gt 0 ]]; do
    need() { [[ $# -ge 2 ]] || fail "$1 needs a value"; }
    case "$1" in
        --config)          need "$@"; shift 2 ;;   # already loaded above
        --dry-run)         OPT_DRY_RUN=1; shift ;;
        --frequency)       need "$@"; OPT_FREQ="$2"; shift 2 ;;
        --bandwidth)       need "$@"; OPT_BW="$2"; shift 2 ;;
        --spreadingfactor) need "$@"; OPT_SF="$2"; shift 2 ;;
        --codingrate)      need "$@"; OPT_CR="$2"; shift 2 ;;
        --txpower)         need "$@"; OPT_TXP="$2"; shift 2 ;;
        --preamble)        need "$@"; OPT_PREAMBLE="$2"; shift 2 ;;
        --no-transport)    OPT_TRANSPORT=0; shift ;;
        --no-autointerface) OPT_AUTOIF=0; shift ;;
        --no-rnode-framing) OPT_RNODE_FRAMING=0; shift ;;
        --interface-mode)  need "$@"; OPT_IFMODE="${2,,}"; shift 2 ;;
        --ifac-netname)    need "$@"; OPT_IFAC_NET="$2"; shift 2 ;;
        --ifac-passphrase-file) need "$@"; OPT_IFAC_PASS_FILE="$2"; shift 2 ;;
        --tcp-server-port) need "$@"; OPT_TCP_PORT="$2"; shift 2 ;;
        --tcp-client)      need "$@"; OPT_TCP_CLIENTS+=("$2"); shift 2 ;;
        --reticulum-config) need "$@"; OPT_RNS_CONFIG="$2"; shift 2 ;;
        --force-config)    OPT_FORCE_CONFIG=1; shift ;;
        --no-start)        OPT_START=0; shift ;;
        --no-hold)         OPT_HOLD=0; shift ;;
        --force-board)     OPT_FORCE_BOARD=1; shift ;;
        --extract-only)    need "$@"; OPT_EXTRACT_ONLY="$2"; shift 2 ;;
        --wifi-ssid)       need "$@"; OPT_WIFI_SSID="$2"; shift 2 ;;
        --wifi-pass)       need "$@"; OPT_WIFI_PASS="$2"; shift 2 ;;
        --wifi-pass-file)  need "$@"; OPT_WIFI_PASS_FILE="$2"; shift 2 ;;
        --wifi-hidden)     OPT_WIFI_HIDDEN=1; shift ;;
        --wifi-open)       OPT_WIFI_OPEN=1; shift ;;
        --eth-mode)        need "$@"; OPT_ETH_MODE="${2,,}"; shift 2 ;;
        --eth-address)     need "$@"; OPT_ETH_ADDR="$2"; shift 2 ;;
        --eth-gateway)     need "$@"; OPT_ETH_GW="$2"; shift 2 ;;
        --eth-dns)         need "$@"; OPT_ETH_DNS="${2// /}"; shift 2 ;;
        --netplan-file)    need "$@"; OPT_NETPLAN_FILE="$2"; shift 2 ;;
        --no-apply)        OPT_NO_APPLY=1; shift ;;
        --network-only)    OPT_NETWORK_ONLY=1; shift ;;
        --revert-after)    need "$@"; OPT_REVERT_SECS="$2"; shift 2 ;;
        --hostname)        need "$@"; OPT_HOSTNAME="$2"; shift 2 ;;
        --timezone)        need "$@"; OPT_TIMEZONE="$2"; shift 2 ;;
        --ssh-key-file)    need "$@"; OPT_SSH_KEYS_FILE="$2"; shift 2 ;;
        --root-password-hash) need "$@"; OPT_ROOT_HASH="$2"; shift 2 ;;
        --skip-first-login-wizard) OPT_SKIP_WIZARD=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *)                 fail "unknown option: $1 (try --help)" ;;
    esac
done

# ---------------------------------------------------------------------------
# Validation (runs before anything is changed)
# ---------------------------------------------------------------------------

is_ipv4() {
    local ip="$1" o
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local IFS=.
    for o in $ip; do ((o <= 255)) || return 1; done
}

validate_options() {
    local pair value ssid_bytes pass_len key line

    for pair in "frequency:$OPT_FREQ" "bandwidth:$OPT_BW" "spreadingfactor:$OPT_SF" \
                "codingrate:$OPT_CR" "txpower:$OPT_TXP" "preamble:$OPT_PREAMBLE"; do
        value="${pair#*:}"
        [[ -z "$value" || "$value" =~ ^[0-9]+$ ]] || fail "${pair%%:*} must be a whole number"
    done
    [[ -z "$OPT_BW" || "$OPT_BW" =~ ^(125000|250000|500000)$ ]] ||
        fail "bandwidth must be 125000, 250000 or 500000"
    [[ -z "$OPT_SF" ]] || { ((OPT_SF >= 7 && OPT_SF <= 12)) || fail "spreadingfactor must be 7-12"; }
    [[ -z "$OPT_CR" ]] || { ((OPT_CR >= 5 && OPT_CR <= 8)) || fail "codingrate must be 5-8"; }
    [[ -z "$OPT_FREQ" ]] || { ((OPT_FREQ >= 150000000 && OPT_FREQ <= 960000000)) ||
        fail "frequency must be between 150 MHz and 960 MHz (SX1250 range)"; }
    [[ -z "$OPT_TXP" ]] || { ((OPT_TXP >= 12 && OPT_TXP <= 16)) ||
        fail "txpower must be 12-16 dBm (limit of the shipped TX gain table)"; }
    [[ -z "$OPT_PREAMBLE" ]] || { ((OPT_PREAMBLE >= 6 && OPT_PREAMBLE <= 1000)) ||
        fail "preamble must be 6-1000 symbols"; }

    [[ "$OPT_REVERT_SECS" =~ ^[0-9]+$ ]] && ((OPT_REVERT_SECS >= 30)) ||
        fail "--revert-after must be a number of seconds, at least 30"

    # --- Reticulum
    [[ -z "$OPT_IFMODE" || "$OPT_IFMODE" =~ ^(full|gateway|access_point|roaming|boundary|pointtopoint)$ ]] ||
        fail "interface mode must be full, gateway, access_point, roaming, boundary or pointtopoint"
    if [[ -n "$OPT_IFAC_PASS_FILE" ]]; then
        [[ -r "$OPT_IFAC_PASS_FILE" ]] || fail "cannot read --ifac-passphrase-file $OPT_IFAC_PASS_FILE"
        OPT_IFAC_PASS="$(head -n1 "$OPT_IFAC_PASS_FILE" | tr -d '\r')"
    fi
    for value in "$OPT_IFAC_NET" "$OPT_IFAC_PASS"; do
        [[ "$value" != *$'\n'* && "$value" != *'"'* && "$value" != *'\'* ]] ||
            fail "IFAC name/passphrase must not contain a newline, a double quote or a backslash"
    done
    if [[ -n "$OPT_TCP_PORT" ]]; then
        [[ "$OPT_TCP_PORT" =~ ^[0-9]+$ ]] && ((OPT_TCP_PORT >= 1 && OPT_TCP_PORT <= 65535)) ||
            fail "TCP server port must be 1-65535"
    fi
    for value in "${OPT_TCP_CLIENTS[@]+"${OPT_TCP_CLIENTS[@]}"}"; do
        [[ "$value" =~ ^[A-Za-z0-9._-]+:[0-9]{1,5}$ ]] || fail "TCP client '$value' must look like host:port"
        ((${value##*:} >= 1 && ${value##*:} <= 65535)) || fail "TCP client '$value': port out of range"
    done
    [[ -z "$OPT_RNS_CONFIG" || -r "$OPT_RNS_CONFIG" ]] || fail "cannot read Reticulum config '$OPT_RNS_CONFIG'"
    if [[ -n "$OPT_RNS_CONFIG" ]]; then
        if [[ -n "$OPT_FREQ$OPT_BW$OPT_SF$OPT_CR$OPT_TXP$OPT_PREAMBLE$OPT_IFMODE$OPT_IFAC_NET$OPT_IFAC_PASS$OPT_TCP_PORT" ||
              ${#OPT_TCP_CLIENTS[@]} -gt 0 ]]; then
            warn "a complete Reticulum config was given, so the radio, IFAC, mode and TCP settings are ignored"
        fi
    fi

    # --- network
    if [[ -n "$OPT_NETPLAN_FILE" && ( -n "$OPT_WIFI_SSID" || -n "$OPT_ETH_MODE" && "$OPT_ETH_MODE" != "keep" ) ]]; then
        fail "a complete netplan file cannot be combined with the Wi-Fi or Ethernet settings"
    fi
    if [[ -z "$OPT_WIFI_SSID" ]]; then
        [[ -z "$OPT_WIFI_PASS_FILE" && "$OPT_WIFI_HIDDEN$OPT_WIFI_OPEN" == "00" ]] ||
            fail "wifi pass file / hidden / open need a Wi-Fi SSID"
    fi
    if [[ -n "$OPT_WIFI_PASS_FILE" ]]; then
        [[ -r "$OPT_WIFI_PASS_FILE" ]] || fail "cannot read --wifi-pass-file $OPT_WIFI_PASS_FILE"
        OPT_WIFI_PASS="$(head -n1 "$OPT_WIFI_PASS_FILE" | tr -d '\r')"
    fi
    if [[ -n "$OPT_WIFI_SSID" ]]; then
        ssid_bytes="$(printf '%s' "$OPT_WIFI_SSID" | wc -c)"
        ((ssid_bytes >= 1 && ssid_bytes <= 32)) || fail "the SSID must be 1-32 bytes"
        [[ "$OPT_WIFI_SSID$OPT_WIFI_PASS" != *$'\n'* ]] || fail "the SSID/passphrase must not contain a newline"
        if [[ "$OPT_WIFI_OPEN" -eq 1 ]]; then
            [[ -z "$OPT_WIFI_PASS" ]] || fail "an open network and a passphrase are contradictory"
        else
            [[ -n "$OPT_WIFI_PASS" ]] || fail "no Wi-Fi passphrase given (use a pass file, BOBCAT_WIFI_PASS, WIFI_PASS, or open)"
            pass_len="${#OPT_WIFI_PASS}"
            ((pass_len >= 8 && pass_len <= 64)) || fail "a WPA passphrase must be 8-63 characters (or 64 hex digits)"
        fi
    fi
    [[ -z "$OPT_ETH_MODE" || "$OPT_ETH_MODE" =~ ^(dhcp|static|keep)$ ]] ||
        fail "Ethernet mode must be dhcp, static or keep"
    if [[ "$OPT_ETH_MODE" == "static" ]]; then
        [[ "$OPT_ETH_ADDR" =~ ^[0-9.]+/[0-9]{1,2}$ ]] && is_ipv4 "${OPT_ETH_ADDR%/*}" &&
            ((${OPT_ETH_ADDR#*/} >= 1 && ${OPT_ETH_ADDR#*/} <= 32)) ||
            fail "static Ethernet needs an address like 192.168.1.50/24"
        [[ -z "$OPT_ETH_GW" ]] || is_ipv4 "$OPT_ETH_GW" || fail "the Ethernet gateway must be an IPv4 address"
        if [[ -n "$OPT_ETH_DNS" ]]; then
            local IFS=','
            for value in $OPT_ETH_DNS; do is_ipv4 "$value" || fail "DNS server '$value' is not an IPv4 address"; done
        fi
    elif [[ -n "$OPT_ETH_ADDR$OPT_ETH_GW$OPT_ETH_DNS" ]]; then
        fail "Ethernet address/gateway/DNS need Ethernet mode 'static'"
    fi
    [[ -z "$OPT_NETPLAN_FILE" || "$OPT_NETPLAN_FILE" == "-" || -r "$OPT_NETPLAN_FILE" ]] ||
        fail "cannot read netplan file $OPT_NETPLAN_FILE"

    # --- operating system
    [[ -z "$OPT_HOSTNAME" || "$OPT_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] ||
        fail "hostname must be letters, digits and hyphens (1-63 characters, no leading/trailing hyphen)"
    [[ -z "$OPT_TIMEZONE" || ( "$OPT_TIMEZONE" =~ ^[A-Za-z0-9_+/-]+$ && "$OPT_TIMEZONE" != *..* ) ]] ||
        fail "timezone '$OPT_TIMEZONE' is not valid (example: America/New_York)"
    [[ -z "$OPT_ROOT_HASH" || "$OPT_ROOT_HASH" =~ ^\$[0-9a-z]+\$[^[:space:]:]+$ ]] ||
        fail "the root password must be given as a crypt(3) hash, e.g. from: mkpasswd -m sha-512"
    if [[ -n "$OPT_SSH_KEYS_FILE" ]]; then
        [[ -r "$OPT_SSH_KEYS_FILE" ]] || fail "cannot read SSH key file $OPT_SSH_KEYS_FILE"
        OPT_SSH_KEYS+="$(tr -d '\r' < "$OPT_SSH_KEYS_FILE")"$'\n'
    fi
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]] ||
            fail "an SSH key line is not a plain public key (options such as command= are not accepted)"
    done <<< "$OPT_SSH_KEYS"
}

validate_options

# ---------------------------------------------------------------------------
# Unpack the appended payload
# ---------------------------------------------------------------------------

extract_payload() {
    local dest="$1" start
    start="$(LC_ALL=C awk '/^__PAYLOAD_BELOW__$/ { print NR + 1; exit }' "$0")"
    [[ -n "$start" ]] || fail "no payload found in $0"
    mkdir -p "$dest"
    tail -n +"$start" "$0" | tar -xzf - -C "$dest"
}

if [[ -n "$OPT_EXTRACT_ONLY" ]]; then
    extract_payload "$OPT_EXTRACT_ONLY"
    log "Unpacked to $OPT_EXTRACT_ONLY"
    exit 0
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

preflight() {
    log "Checking this machine"
    [[ "$EUID" -eq 0 ]] || fail "run as root (the radio, GPIO and systemd all need it)"
    have apt-get || fail "apt-get not found; this installer supports Debian/Armbian only"
    have systemctl || fail "systemd is required"

    local model compat
    model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
    compat="$(tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null || true)"
    note "board: ${model:-unknown} (${compat:-unknown})"

    if [[ "$OPT_FORCE_BOARD" -eq 0 ]]; then
        [[ "$compat" == *"bobcat,29x"* ]] ||
            fail "this is not a Bobcat 29x (G290/G295). Use --force-board to override at your own risk"
    fi
    [[ -e /dev/spidev5.0 ]] ||
        fail "/dev/spidev5.0 is missing: this is not the community Bobcat-Armbian image (the radio's SPI bus is exposed by its device tree)"

    if pgrep -f '[b]in/rnsd' >/dev/null 2>&1 && ! systemctl is-active --quiet "$SERVICE"; then
        fail "an rnsd is already running outside the $SERVICE service; stop it first (it would hold the radio)"
    fi
    note "ok: Bobcat 29x with /dev/spidev5.0"
}

# ---------------------------------------------------------------------------
# Networking through netplan
# ---------------------------------------------------------------------------

mask_secrets() {
    sed -E 's/((password|passphrase|pass_phrase|psk|key|hash)[a-z_-]*[[:space:]]*[:=][[:space:]]*).*/\1<hidden>/I'
}

net_ok() {
    # A default route and a TCP connection to PyPI (needed by this installer).
    ip route show default 2>/dev/null | grep -q . &&
        timeout 5 bash -c 'exec 3<>/dev/tcp/pypi.org/443' 2>/dev/null
}

wait_for() {
    local seconds="$1" i
    shift
    for ((i = 0; i < seconds; i += 2)); do
        "$@" && return 0
        sleep 2
    done
    return 1
}

wifi_connected() {
    [[ "$(nmcli -g GENERAL.STATE dev show "$1" 2>/dev/null)" == 100* ]]
}

wants_generated_network() {
    [[ -n "$OPT_WIFI_SSID" || "$OPT_ETH_MODE" == "dhcp" || "$OPT_ETH_MODE" == "static" ]]
}

# Write the Wi-Fi and/or Ethernet definitions with PyYAML so any SSID or
# passphrase is quoted correctly. Secrets travel in the environment, never on
# a command line.
generate_network_yaml() {
    local out="$1" wifi_iface="$2" eth_iface="$3"
    W_SSID="$OPT_WIFI_SSID" W_PASS="$OPT_WIFI_PASS" W_IFACE="$wifi_iface" W_HIDDEN="$OPT_WIFI_HIDDEN" \
    E_IFACE="$eth_iface" E_MODE="$OPT_ETH_MODE" E_ADDR="$OPT_ETH_ADDR" E_GW="$OPT_ETH_GW" E_DNS="$OPT_ETH_DNS" \
    N_DIR="${BOBCAT_NETPLAN_DIR:-/etc/netplan}" \
    python3 - "$out" <<'PY'
import glob, ipaddress, os, sys
import yaml

env = os.environ
ssid, pw, hidden = env["W_SSID"], env["W_PASS"], env["W_HIDDEN"] == "1"
wifi_iface, eth_iface = env["W_IFACE"], env["E_IFACE"]
mode, addr, gw = env["E_MODE"], env["E_ADDR"], env["E_GW"]
dns = [d for d in env["E_DNS"].split(",") if d]
out = sys.argv[1]
mine = os.path.basename(out)

# Netplan rejects the same access point in two files, and a second definition of
# the same Ethernet interface would silently merge with this one.
for path in sorted(glob.glob(os.path.join(env["N_DIR"], "*.yaml"))):
    if os.path.basename(path) == mine:
        continue
    try:
        doc = yaml.safe_load(open(path)) or {}
    except PermissionError:
        # Only happens in a dry run as a normal user; a real install runs as root.
        print(f"note: cannot read {path} (permission denied); not checked for duplicates", file=sys.stderr)
        continue
    except Exception as exc:
        sys.exit(f"cannot read {path}: {exc}")
    net = doc.get("network") or {}
    if ssid:
        for dev in (net.get("wifis") or {}).values():
            if ssid in {str(k) for k in ((dev or {}).get("access-points") or {})}:
                sys.exit(
                    f"this SSID is already defined in {path}; netplan rejects duplicate "
                    "access points. Edit it there, or pass a complete config with --netplan-file"
                )
    if mode in ("dhcp", "static") and eth_iface in (net.get("ethernets") or {}):
        sys.exit(
            f"{eth_iface} is already defined in {path}. Remove it there first, "
            "or use Ethernet mode 'keep'"
        )

network = {"version": 2, "renderer": "NetworkManager"}

if mode == "dhcp":
    network["ethernets"] = {eth_iface: {"dhcp4": True}}
elif mode == "static":
    try:
        ipaddress.ip_interface(addr)
        if gw:
            ipaddress.ip_address(gw)
        for d in dns:
            ipaddress.ip_address(d)
    except ValueError as exc:
        sys.exit(f"bad Ethernet address settings: {exc}")
    eth = {"dhcp4": False, "addresses": [addr]}
    if gw:
        eth["routes"] = [{"to": "0.0.0.0/0", "via": gw}]
    if dns:
        eth["nameservers"] = {"addresses": dns}
    network["ethernets"] = {eth_iface: eth}

if ssid:
    ap = {}
    if hidden:
        ap["hidden"] = True
    if pw:
        ap["password"] = pw
    network["wifis"] = {
        wifi_iface: {"dhcp4": True, "optional": True, "access-points": {ssid: ap}}
    }

with open(out, "w") as fh:
    fh.write("# Generated by bobcat-g295-install.sh\n")
    yaml.safe_dump({"network": network}, fh, sort_keys=False, allow_unicode=True)
PY
}

setup_network() {
    wants_generated_network || [[ -n "$OPT_NETPLAN_FILE" ]] || return 0
    log "Network configuration (netplan)"

    have netplan || fail "netplan is not installed (apt install netplan.io)"
    python3 -c 'import yaml' 2>/dev/null || fail "python3-yaml is missing (it normally comes with netplan)"
    systemctl is-active --quiet NetworkManager ||
        fail "NetworkManager is not running; this installer renders netplan through NetworkManager"

    local stage new name wifi_iface="" eth_iface="" out backup revert eth_change=0
    stage="$(mktemp -d)"
    chmod 700 "$stage"

    # 1. Produce the file to install.
    if wants_generated_network; then
        wifi_iface="$(nmcli -t -f DEVICE,TYPE dev 2>/dev/null | awk -F: '$2=="wifi" { print $1; exit }')"
        eth_iface="$(nmcli -t -f DEVICE,TYPE dev 2>/dev/null | awk -F: '$2=="ethernet" { print $1; exit }')"
        if [[ -n "$OPT_WIFI_SSID" && -z "$wifi_iface" ]]; then rm -rf "$stage"; fail "no Wi-Fi interface found on this machine"; fi
        if [[ "$OPT_ETH_MODE" =~ ^(dhcp|static)$ && -z "$eth_iface" ]]; then rm -rf "$stage"; fail "no Ethernet interface found on this machine"; fi
        name="60-bobcat-network.yaml"
        new="$stage/$name"
        generate_network_yaml "$new" "${wifi_iface:-wlan0}" "${eth_iface:-end0}" ||
            { rm -rf "$stage"; fail "could not build the netplan file"; }
        [[ -z "$OPT_WIFI_SSID" ]] || note "Wi-Fi: SSID '$OPT_WIFI_SSID' on $wifi_iface$([[ $OPT_WIFI_HIDDEN -eq 1 ]] && echo ' (hidden)')"
        if [[ "$OPT_ETH_MODE" =~ ^(dhcp|static)$ ]]; then
            eth_change=1
            note "Ethernet: $eth_iface $OPT_ETH_MODE${OPT_ETH_ADDR:+ $OPT_ETH_ADDR}"
        fi
    else
        name="60-bobcat-custom.yaml"
        new="$stage/$name"
        if [[ "$OPT_NETPLAN_FILE" == "-" ]]; then cat > "$new"; else cp "$OPT_NETPLAN_FILE" "$new"; fi
        grep -q '^network:' "$new" || { rm -rf "$stage"; fail "that file does not look like a netplan config (no top-level 'network:')"; }
        eth_change=1
        note "custom netplan file -> /etc/netplan/$name"
    fi
    chmod 600 "$new"

    # 2. Already installed and identical? Nothing to do.
    if cmp -s "$new" "/etc/netplan/$name" 2>/dev/null; then
        note "/etc/netplan/$name is already up to date"
        rm -rf "$stage"
        return 0
    fi

    # 3. Validate in a scratch root so a bad file never touches the live config.
    mkdir -p "$stage/root/etc/netplan"
    cp -a /etc/netplan/. "$stage/root/etc/netplan/" 2>/dev/null || true
    install -m 600 "$new" "$stage/root/etc/netplan/$name"
    if ! out="$(netplan generate --root-dir "$stage/root" 2>&1)"; then
        printf '%s\n' "$out" | mask_secrets >&2
        rm -rf "$stage"
        fail "netplan rejected the configuration (nothing was changed)"
    fi
    note "validated"

    # 4. Back up, install, and (unless --no-apply) apply under an auto-revert.
    backup="/root/netplan-backup-$(date +%Y%m%d%H%M%S)"
    mkdir -m 700 "$backup"
    cp -a /etc/netplan/. "$backup/" 2>/dev/null || true
    install -m 600 "$new" "/etc/netplan/$name"
    rm -rf "$stage"
    note "previous netplan files saved to $backup (may contain secrets)"

    if [[ "$OPT_NO_APPLY" -eq 1 ]]; then
        note "--no-apply: written but not applied; run 'netplan apply' or reboot"
        return 0
    fi

    # Changing the Ethernet link can change this machine's address and end an
    # SSH session. Keep going without a terminal and log to a file instead.
    if [[ "$eth_change" -eq 1 && -n "${SSH_CONNECTION:-}" ]]; then
        warn "you are connected over SSH and the Ethernet settings are changing: this session may drop"
        note "the installer keeps running; follow /var/log/bobcat-install.log"
        note "the change is undone after ${OPT_REVERT_SECS}s unless internet is confirmed"
        trap '' HUP
        exec >>/var/log/bobcat-install.log 2>&1
    fi

    revert="/root/bobcat-netplan-revert.sh"
    cat > "$revert" <<EOF
#!/bin/bash
# Auto-revert: undo the netplan change if it left this node offline.
rm -f /etc/netplan/$name
cp -a "$backup"/. /etc/netplan/
netplan generate && netplan apply
# NetworkManager keeps an active profile in memory after its file is gone.
nmcli -t -f UUID,NAME con show | while IFS=: read -r u n; do
    case "\$n" in
        netplan-*)
            grep -qxF "id=\$n" /run/NetworkManager/system-connections/*.nmconnection 2>/dev/null ||
                nmcli connection delete uuid "\$u" >/dev/null 2>&1 ;;
    esac
done
EOF
    chmod 700 "$revert"
    systemctl stop bobcat-netplan-revert.timer >/dev/null 2>&1 || true
    systemd-run --quiet --unit=bobcat-netplan-revert --on-active="$OPT_REVERT_SECS" \
        --collect "$revert"
    note "auto-revert armed (${OPT_REVERT_SECS}s) in case this cuts the connection"

    netplan generate || { "$revert"; fail "netplan generate failed after install; reverted"; }
    nmcli connection reload
    if [[ "$eth_change" -eq 0 && -n "$wifi_iface" ]]; then
        # Wi-Fi only: bring up just the new profile; do not disturb other links.
        nmcli --wait 30 connection up "netplan-$wifi_iface-$OPT_WIFI_SSID" >/dev/null 2>&1 ||
            nmcli --wait 30 device connect "$wifi_iface" >/dev/null 2>&1 || true
    else
        netplan apply
    fi

    note "waiting for the network"
    if ! wait_for 60 net_ok; then
        warn "no internet after applying the new network config"
        note "it will revert by itself in about ${OPT_REVERT_SECS}s (backup: $backup)"
        fail "network check failed"
    fi
    systemctl stop bobcat-netplan-revert.timer >/dev/null 2>&1 || true
    rm -f "$revert"
    note "internet reachable; auto-revert cancelled"

    if [[ -n "$OPT_WIFI_SSID" && -n "$wifi_iface" ]]; then
        if wait_for 30 wifi_connected "$wifi_iface"; then
            note "Wi-Fi up: $(ip -br -4 addr show "$wifi_iface" | awk '{ print $3 }')"
        else
            warn "the network works (another link) but $wifi_iface did not join '$OPT_WIFI_SSID'"
            note "check the passphrase; hidden network? add --wifi-hidden; this chip is 2.4 GHz only"
            note "details: journalctl -u NetworkManager -n 40 --no-pager"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Operating system settings
# ---------------------------------------------------------------------------

wants_os_settings() {
    [[ -n "$OPT_HOSTNAME$OPT_TIMEZONE$OPT_SSH_KEYS$OPT_ROOT_HASH" || "$OPT_SKIP_WIZARD" -eq 1 ]]
}

setup_os() {
    wants_os_settings || return 0
    log "System settings"
    local key

    if [[ -n "$OPT_HOSTNAME" ]]; then
        if [[ "$(hostname)" != "$OPT_HOSTNAME" ]]; then
            hostnamectl set-hostname "$OPT_HOSTNAME"
            if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
                sed -i -E "s/^(127\.0\.1\.1[[:space:]]+).*/\1$OPT_HOSTNAME/" /etc/hosts
            else
                printf '127.0.1.1\t%s\n' "$OPT_HOSTNAME" >> /etc/hosts
            fi
        fi
        note "hostname: $OPT_HOSTNAME"
    fi

    if [[ -n "$OPT_TIMEZONE" ]]; then
        [[ -e "/usr/share/zoneinfo/$OPT_TIMEZONE" ]] || fail "unknown timezone '$OPT_TIMEZONE'"
        timedatectl set-timezone "$OPT_TIMEZONE"
        note "timezone: $OPT_TIMEZONE"
    fi

    if [[ -n "$OPT_SSH_KEYS" ]]; then
        install -d -m 700 /root/.ssh
        touch /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        local added=0
        while IFS= read -r key; do
            [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
            if ! grep -qxF -- "$key" /root/.ssh/authorized_keys; then
                printf '%s\n' "$key" >> /root/.ssh/authorized_keys
                added=$((added + 1))
            fi
        done <<< "$OPT_SSH_KEYS"
        note "SSH keys: $added added to root's authorized_keys"
    fi

    if [[ -n "$OPT_ROOT_HASH" ]]; then
        printf 'root:%s\n' "$OPT_ROOT_HASH" | chpasswd -e
        note "root password set"
    fi

    if [[ "$OPT_SKIP_WIZARD" -eq 1 ]]; then
        rm -f /root/.not_logged_in_yet
        note "Armbian first-login prompt disabled"
    fi
}

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------

install_packages() {
    local missing=() pkg
    have gcc     || missing+=(gcc)
    have make    || missing+=(make)
    have patch   || missing+=(patch)
    have gpioset || missing+=(gpiod)
    python3 -c 'import venv, ensurepip' >/dev/null 2>&1 || missing+=(python3-venv)
    python3 -m pip --version >/dev/null 2>&1 || missing+=(python3-pip)

    if [[ ${#missing[@]} -gt 0 ]]; then
        log "Installing packages: ${missing[*]}"
        export DEBIAN_FRONTEND=noninteractive
        if ! apt-get install -y --no-install-recommends "${missing[@]}"; then
            note "install failed, refreshing package lists and retrying"
            apt-get update
            apt-get install -y --no-install-recommends "${missing[@]}"
        fi
    else
        note "system packages already present"
    fi

    # The image docs warn that upgrading these breaks boot. Never upgrade; hold.
    if [[ "$OPT_HOLD" -eq 1 ]]; then
        for pkg in linux-image-current-rockchip64 linux-dtb-current-rockchip64 \
                   linux-u-boot-bobcat-29x-current; do
            if dpkg -s "$pkg" >/dev/null 2>&1; then
                apt-mark hold "$pkg" >/dev/null
            fi
        done
        note "kernel/u-boot packages held"
    fi
}

# ---------------------------------------------------------------------------
# Code, venv, HAL
# ---------------------------------------------------------------------------

install_code() {
    log "Installing code to $PREFIX"
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        note "stopping running $SERVICE"
        systemctl stop "$SERVICE"
    fi
    extract_payload "$PREFIX"
    chmod +x "$PREFIX/bobcat-g295/reset_bobcat_g295.sh" \
             "$PREFIX/bobcat-g295/announce_test.py" \
             "$PREFIX"/sx1302_rns/scripts/*.sh

    log "Python environment"
    [[ -x "$PREFIX/venv/bin/python" ]] || python3 -m venv "$PREFIX/venv"
    "$PREFIX/venv/bin/pip" install --quiet "rns>=1.5.7,<2"
    "$PREFIX/venv/bin/pip" install --quiet --no-deps -e "$PREFIX/sx1302_rns"
    "$PREFIX/venv/bin/python" -c 'import RNS, sx1302_reticulum; print("    RNS", RNS.__version__)'

    log "Building the SX1302 HAL (about a minute)"
    (cd "$PREFIX/sx1302_rns" && ./scripts/build_hal.sh >/tmp/bobcat-hal-build.log 2>&1) ||
        { tail -20 /tmp/bobcat-hal-build.log >&2; fail "HAL build failed (full log: /tmp/bobcat-hal-build.log)"; }
    note "built $PREFIX/sx1302_rns/build/libloragw.so"
}

# ---------------------------------------------------------------------------
# Reticulum config, interface shim, service
# ---------------------------------------------------------------------------

# Print the generated Reticulum config. Values that may hold spaces or '#' are
# double-quoted, which Reticulum's config parser understands.
render_reticulum_config() {
    local transport="yes" client host port
    [[ "$OPT_TRANSPORT" -eq 1 ]] || transport="no"

    cat <<EOF
# Reticulum config for a Bobcat G290/G295 node (SX1302 LoRa).
# Generated by bobcat-g295-install.sh. Radio defaults live in
# $PROFILE; values set in the stanza below override them.
[reticulum]
  enable_transport = $transport
  share_instance = yes
  instance_name = default

[logging]
  loglevel = 4

[interfaces]
EOF
    if [[ "$OPT_AUTOIF" -eq 1 ]]; then
        cat <<'EOF'

  [[Default Interface]]
    type = AutoInterface
    enabled = yes
EOF
    fi
    cat <<EOF

  [[SX1302 LoRa]]
    type = SX1302
    enabled = yes
    board_profile = $PROFILE
    library = $PREFIX/sx1302_rns/build/libloragw.so
EOF
    if [[ "$OPT_RNODE_FRAMING" -eq 1 ]]; then
        echo "    # RNode 1-byte framing is on by default; needed to talk to real RNodes."
        echo "    # rnode_framing = yes"
    else
        echo "    rnode_framing = no"
    fi
    [[ -z "$OPT_FREQ"     ]] || echo "    frequency = $OPT_FREQ"
    [[ -z "$OPT_BW"       ]] || echo "    bandwidth = $OPT_BW"
    [[ -z "$OPT_SF"       ]] || echo "    spreadingfactor = $OPT_SF"
    [[ -z "$OPT_CR"       ]] || echo "    codingrate = $OPT_CR"
    [[ -z "$OPT_TXP"      ]] || echo "    txpower = $OPT_TXP"
    [[ -z "$OPT_PREAMBLE" ]] || echo "    preamble = $OPT_PREAMBLE"
    [[ -z "$OPT_IFMODE"   ]] || echo "    mode = $OPT_IFMODE"
    [[ -z "$OPT_IFAC_NET" ]] || echo "    network_name = \"$OPT_IFAC_NET\""
    [[ -z "$OPT_IFAC_PASS" ]] || echo "    passphrase = \"$OPT_IFAC_PASS\""

    if [[ -n "$OPT_TCP_PORT" ]]; then
        cat <<EOF

  [[TCP Server]]
    type = TCPServerInterface
    enabled = yes
    listen_ip = 0.0.0.0
    listen_port = $OPT_TCP_PORT
EOF
    fi
    local n=0
    for client in "${OPT_TCP_CLIENTS[@]+"${OPT_TCP_CLIENTS[@]}"}"; do
        n=$((n + 1))
        host="${client%:*}"
        port="${client##*:}"
        cat <<EOF

  [[TCP Client $n]]
    type = TCPClientInterface
    enabled = yes
    target_host = $host
    target_port = $port
EOF
    done
}

write_config() {
    log "Reticulum configuration"
    mkdir -p "$CONFIGDIR/interfaces"
    ln -sfn "$PREFIX/sx1302_rns/interfaces/SX1302.py" "$CONFIGDIR/interfaces/SX1302.py"

    local cfg="$CONFIGDIR/config" stamp="$CONFIGDIR/.bobcat-config.sha256" replace=0
    if [[ -e "$cfg" ]]; then
        # Safe to regenerate when the file is still exactly what we wrote last
        # time. If someone edited it, keep their changes unless told otherwise.
        if [[ "$OPT_FORCE_CONFIG" -eq 1 || -n "$OPT_RNS_CONFIG" ]]; then
            replace=1
        elif [[ -r "$stamp" && "$(sha256sum "$cfg" | cut -d' ' -f1)" == "$(cat "$stamp")" ]]; then
            replace=1
        fi
        if [[ "$replace" -eq 0 ]]; then
            note "keeping $cfg (edited by hand; use --force-config to replace it)"
            grep -q 'type = SX1302' "$cfg" ||
                warn "the existing config has no SX1302 interface; add the [[SX1302 LoRa]] stanza or use --force-config"
            return
        fi
        cp -a "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)"
        note "old config backed up"
    fi

    if [[ -n "$OPT_RNS_CONFIG" ]]; then
        install -m 600 "$OPT_RNS_CONFIG" "$cfg"
        grep -q 'type = SX1302' "$cfg" ||
            warn "your Reticulum config has no 'type = SX1302' interface, so the LoRa radio will not be used"
        rm -f "$stamp"
        note "installed your Reticulum config as $cfg"
        return
    fi

    render_reticulum_config > "$cfg"
    chmod 600 "$cfg"
    sha256sum "$cfg" | cut -d' ' -f1 > "$stamp"
    note "wrote $cfg"
}

install_service() {
    log "systemd service"
    cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=Reticulum (rnsd) with the Bobcat SX1302 LoRa interface
Documentation=https://reticulum.network/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$PREFIX
Environment=PYTHONUNBUFFERED=1
Environment=SX1302_HAL_LIB=$PREFIX/sx1302_rns/build/libloragw.so
# The interface resets the radio (GPIO4_21) itself when it starts and stops.
ExecStart=$PREFIX/venv/bin/rnsd --config $CONFIGDIR
Restart=on-failure
RestartSec=10
SyslogIdentifier=$SERVICE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    if [[ "$OPT_START" -eq 1 ]]; then
        systemctl enable "$SERVICE" >/dev/null 2>&1
        SERVICE_STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
        systemctl restart "$SERVICE"
        note "$SERVICE enabled and started"
    else
        note "installed, not started (--no-start)"
    fi
}

verify() {
    [[ "$OPT_START" -eq 1 ]] || return 0
    log "Checking the radio came up"

    # Do NOT call rnstatus until the service itself reports the interface is
    # online. A Reticulum client started before rnsd owns the shared-instance
    # socket becomes the instance itself, grabs the radio, and leaves the real
    # service attached to it as a client.
    local i out log
    for i in $(seq 1 30); do
        log="$(journalctl -u "$SERVICE" --since "$SERVICE_STARTED_AT" --no-pager -o cat 2>/dev/null || true)"
        if grep -q 'connected to another shared local instance' <<<"$log"; then
            warn "another Reticulum instance already holds the radio/socket"
            note "stop it (systemctl stop $SERVICE; pgrep -af rns) and re-run"
            return 1
        fi
        if grep -q 'SX1302Interface.*is online' <<<"$log"; then
            out="$("$PREFIX/venv/bin/rnstatus" --config "$CONFIGDIR" 2>/dev/null || true)"
            grep -A5 'SX1302Interface' <<<"$out" | sed 's/^/    /'
            return 0
        fi
        sleep 2
    done
    warn "the SX1302 interface did not come online within a minute"
    note "look at: journalctl -u $SERVICE -n 50 --no-pager"
    return 1
}

# ---------------------------------------------------------------------------
# Keep a copy of the settings on the installed system
# ---------------------------------------------------------------------------

persist_config() {
    [[ -n "$OPT_CONFIG" ]] || return 0
    local src="$OPT_CONFIG" dst="$STATEDIR/install.conf" key path name

    # Already living in the state directory (first-boot install): nothing to copy.
    [[ "$(dirname "$src")" != "$STATEDIR" ]] || return 0

    install -d -m 700 "$STATEDIR" "$STATEDIR/files"
    tr -d '\r' < "$src" > "$dst"
    chmod 600 "$dst"

    # Files the config points to are copied too, and the copy's paths rewritten.
    for pair in "NETPLAN_FILE:$OPT_NETPLAN_FILE" "SSH_AUTHORIZED_KEYS_FILE:$OPT_SSH_KEYS_FILE" \
                "RETICULUM_CONFIG_FILE:$OPT_RNS_CONFIG"; do
        key="${pair%%:*}"
        path="${pair#*:}"
        [[ -n "$path" && "$path" != "-" && -r "$path" ]] || continue
        grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$dst" || continue
        name="$(basename "$path")"
        install -m 600 "$path" "$STATEDIR/files/$name"
        sed -i -E "s|^([[:space:]]*${key}[[:space:]]*=).*|\1${STATEDIR}/files/${name}|" "$dst"
    done
    note "settings saved to $dst"
}

# ---------------------------------------------------------------------------
# Dry run: show the plan without changing anything
# ---------------------------------------------------------------------------

print_plan() {
    local tmp client
    tmp="$(mktemp -d)"
    chmod 700 "$tmp"

    echo "== Plan (dry run: nothing is changed)"
    echo "config file:   ${OPT_CONFIG:-none}"
    echo
    echo "-- radio"
    echo "frequency:     ${OPT_FREQ:-profile default}"
    echo "bandwidth:     ${OPT_BW:-profile default}"
    echo "spreading:     ${OPT_SF:-profile default}"
    echo "coding rate:   ${OPT_CR:-profile default}"
    echo "tx power:      ${OPT_TXP:-profile default}"
    echo "preamble:      ${OPT_PREAMBLE:-profile default}"
    echo
    echo "-- reticulum"
    echo "transport:     $([[ $OPT_TRANSPORT -eq 1 ]] && echo yes || echo no)"
    echo "autointerface: $([[ $OPT_AUTOIF -eq 1 ]] && echo yes || echo no)"
    echo "rnode framing: $([[ $OPT_RNODE_FRAMING -eq 1 ]] && echo yes || echo no)"
    echo "interface mode: ${OPT_IFMODE:-default}"
    echo "IFAC:          ${OPT_IFAC_NET:+network name set }$([[ -n $OPT_IFAC_PASS ]] && echo 'passphrase set')$([[ -z $OPT_IFAC_NET$OPT_IFAC_PASS ]] && echo none)"
    echo "tcp server:    ${OPT_TCP_PORT:-none}"
    for client in "${OPT_TCP_CLIENTS[@]+"${OPT_TCP_CLIENTS[@]}"}"; do echo "tcp client:    $client"; done
    echo "own config:    ${OPT_RNS_CONFIG:-none (one is generated)}"
    echo
    echo "-- network"
    echo "wifi:          ${OPT_WIFI_SSID:-not configured}$([[ $OPT_WIFI_HIDDEN -eq 1 ]] && echo ' (hidden)')$([[ $OPT_WIFI_OPEN -eq 1 ]] && echo ' (open)')"
    echo "ethernet:      ${OPT_ETH_MODE:-keep}${OPT_ETH_ADDR:+ $OPT_ETH_ADDR}${OPT_ETH_GW:+ via $OPT_ETH_GW}${OPT_ETH_DNS:+ dns $OPT_ETH_DNS}"
    echo "netplan file:  ${OPT_NETPLAN_FILE:-none}"
    echo
    echo "-- operating system"
    echo "hostname:      ${OPT_HOSTNAME:-unchanged}"
    echo "timezone:      ${OPT_TIMEZONE:-unchanged}"
    echo "ssh keys:      $(printf '%s' "$OPT_SSH_KEYS" | grep -cvE '^[[:space:]]*(#|$)' || true)"
    echo "root password: $([[ -n $OPT_ROOT_HASH ]] && echo 'will be set from the hash' || echo unchanged)"
    echo "first-login wizard: $([[ $OPT_SKIP_WIZARD -eq 1 ]] && echo 'will be skipped' || echo untouched)"

    if wants_generated_network; then
        echo
        echo "-- generated netplan (secrets masked)"
        if generate_network_yaml "$tmp/net.yaml" wlan0 end0; then
            mask_secrets < "$tmp/net.yaml"
        else
            rm -rf "$tmp"
            fail "the network settings cannot be turned into a netplan file"
        fi
    fi
    if [[ -z "$OPT_RNS_CONFIG" ]]; then
        echo
        echo "-- generated Reticulum config (secrets masked)"
        render_reticulum_config | mask_secrets
    fi
    rm -rf "$tmp"
}

main() {
    if [[ "$OPT_DRY_RUN" -eq 1 ]]; then
        print_plan
        return 0
    fi

    preflight
    setup_network
    if [[ "$OPT_NETWORK_ONLY" -eq 1 ]]; then
        log "Network step finished (--network-only)"
        return 0
    fi
    setup_os
    install_packages
    install_code
    write_config
    install_service
    persist_config
    local ok=0
    verify || ok=1

    echo
    if [[ "$ok" -eq 0 ]]; then
        log "Done. This node is a Reticulum LoRa node."
    else
        log "Installed, but the radio check failed (see above)."
    fi
    cat <<EOF

  status:      $PREFIX/venv/bin/rnstatus --config $CONFIGDIR
  paths:       $PREFIX/venv/bin/rnpath --config $CONFIGDIR -t
  logs:        journalctl -u $SERVICE -f
  send test:   $PREFIX/venv/bin/python $PREFIX/bobcat-g295/announce_test.py "hello" $CONFIGDIR
  radio:       edit $CONFIGDIR/config (frequency, spreadingfactor, ...) then: systemctl restart $SERVICE
  settings:    $STATEDIR/install.conf (re-apply with: bobcat-g295-install.sh --config that file)

  Never power the radio without the antenna attached. TX power is capped at 16 dBm
  until the TX gain table has been measured on your unit.
EOF
    return "$ok"
}

# Tests source this file to call single functions without running the install.
if [[ -n "${BOBCAT_SOURCE_ONLY:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi

main
exit $?

__PAYLOAD_BELOW__
