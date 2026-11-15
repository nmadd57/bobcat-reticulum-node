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
# What it does (safe to re-run):
#   1. checks this really is a Bobcat 29x with /dev/spidev5.0
#   2. optionally sets up networking through netplan (Wi-Fi shortcut or your own config)
#   3. installs python3-venv, python3-pip, gcc, make, patch, gpiod if missing
#      (never runs apt upgrade; holds the kernel/u-boot packages like the image docs say)
#   4. unpacks the code to /opt/bobcat-lora, builds the HAL, makes a venv with rns
#   5. writes /etc/reticulum/config (kept if it already exists), links the interface
#   6. installs and starts the rnsd-sx1302 systemd service, then checks the radio is up
#
# Build: @BUILD_INFO@

set -euo pipefail

PREFIX="/opt/bobcat-lora"
CONFIGDIR="/etc/reticulum"
SERVICE="rnsd-sx1302"
PROFILE="$PREFIX/bobcat-g295/bobcat-g295-us915.conf"

OPT_FREQ="" OPT_BW="" OPT_SF="" OPT_CR="" OPT_TXP=""
OPT_TRANSPORT=1 OPT_AUTOIF=1 OPT_FORCE_CONFIG=0 OPT_START=1 OPT_HOLD=1
OPT_FORCE_BOARD=0 OPT_EXTRACT_ONLY=""
OPT_WIFI_SSID="" OPT_WIFI_PASS="${BOBCAT_WIFI_PASS:-}" OPT_WIFI_PASS_FILE=""
OPT_WIFI_HIDDEN=0 OPT_WIFI_OPEN=0 OPT_NETPLAN_FILE="" OPT_NO_APPLY=0
OPT_NETWORK_ONLY=0 OPT_REVERT_SECS=180
SERVICE_STARTED_AT=""

log()  { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<'EOF'
Usage: bobcat-g295-install.sh [options]

Radio settings (default: 915 MHz, 125 kHz, SF8, CR 4/5, 14 dBm - must match
the other nodes on your network):
  --frequency HZ        e.g. 915000000
  --bandwidth HZ        125000, 250000 or 500000 (the SX1302 cannot do 62.5 kHz)
  --spreadingfactor N   7-12
  --codingrate N        5-8 (4/5 .. 4/8)
  --txpower DBM         capped at 16 by the shipped TX gain table

Behaviour:
  --no-transport        do not forward/repeat other nodes' traffic
  --no-autointerface    do not enable the LAN AutoInterface
  --force-config        overwrite /etc/reticulum/config (a backup is kept)
  --no-start            install but do not enable/start the service
  --no-hold             do not apt-mark hold the kernel/u-boot packages
  --force-board         skip the "is this a Bobcat 29x" check
  --extract-only DIR    just unpack the code into DIR and stop
  -h, --help            this help

Networking (netplan, rendered by NetworkManager; applied BEFORE packages are
installed, so a node with no cable can get online first):
  --wifi-ssid SSID      join this Wi-Fi network (2.4 GHz only on this hardware)
  --wifi-pass PASS      its passphrase (visible in `ps`/history: prefer one of
                        the next two)
  --wifi-pass-file F    read the passphrase from the first line of file F
                        (or set BOBCAT_WIFI_PASS in the environment)
  --wifi-hidden         the SSID is hidden (not broadcast)
  --wifi-open           the network has no password
  --netplan-file F      install your own netplan YAML instead ("-" = read stdin).
                        Mutually exclusive with --wifi-ssid.
  --no-apply            write/validate the netplan file but do not apply it
                        (takes effect on the next boot or `netplan apply`)
  --network-only        stop after the networking step
  --revert-after SECS   auto-revert a netplan change that leaves no internet
                        after this long (default 180)
EOF
}

while [[ $# -gt 0 ]]; do
    need() { [[ $# -ge 2 ]] || fail "$1 needs a value"; }
    case "$1" in
        --frequency)       need "$@"; OPT_FREQ="$2"; shift 2 ;;
        --bandwidth)       need "$@"; OPT_BW="$2"; shift 2 ;;
        --spreadingfactor) need "$@"; OPT_SF="$2"; shift 2 ;;
        --codingrate)      need "$@"; OPT_CR="$2"; shift 2 ;;
        --txpower)         need "$@"; OPT_TXP="$2"; shift 2 ;;
        --no-transport)    OPT_TRANSPORT=0; shift ;;
        --no-autointerface) OPT_AUTOIF=0; shift ;;
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
        --netplan-file)    need "$@"; OPT_NETPLAN_FILE="$2"; shift 2 ;;
        --no-apply)        OPT_NO_APPLY=1; shift ;;
        --network-only)    OPT_NETWORK_ONLY=1; shift ;;
        --revert-after)    need "$@"; OPT_REVERT_SECS="$2"; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        *)                 fail "unknown option: $1 (try --help)" ;;
    esac
done

for pair in "frequency:$OPT_FREQ" "bandwidth:$OPT_BW" "spreadingfactor:$OPT_SF" \
            "codingrate:$OPT_CR" "txpower:$OPT_TXP"; do
    value="${pair#*:}"
    [[ -z "$value" || "$value" =~ ^[0-9]+$ ]] || fail "--${pair%%:*} must be a whole number"
done
[[ -z "$OPT_BW" || "$OPT_BW" =~ ^(125000|250000|500000)$ ]] ||
    fail "--bandwidth must be 125000, 250000 or 500000"
[[ -z "$OPT_SF" ]] || { ((OPT_SF >= 7 && OPT_SF <= 12)) || fail "--spreadingfactor must be 7-12"; }
[[ -z "$OPT_CR" ]] || { ((OPT_CR >= 5 && OPT_CR <= 8)) || fail "--codingrate must be 5-8"; }
[[ -z "$OPT_FREQ" ]] || { ((OPT_FREQ >= 150000000 && OPT_FREQ <= 960000000)) ||
    fail "--frequency must be between 150 MHz and 960 MHz (SX1250 range)"; }
[[ -z "$OPT_TXP" ]] || { ((OPT_TXP >= 12 && OPT_TXP <= 16)) ||
    fail "--txpower must be 12-16 dBm (limit of the shipped TX gain table)"; }

[[ "$OPT_REVERT_SECS" =~ ^[0-9]+$ ]] && ((OPT_REVERT_SECS >= 30)) ||
    fail "--revert-after must be a number of seconds, at least 30"

if [[ -n "$OPT_WIFI_SSID" && -n "$OPT_NETPLAN_FILE" ]]; then
    fail "--wifi-ssid and --netplan-file are mutually exclusive"
fi
if [[ -z "$OPT_WIFI_SSID" ]]; then
    [[ -z "$OPT_WIFI_PASS_FILE" && "$OPT_WIFI_HIDDEN$OPT_WIFI_OPEN" == "00" ]] ||
        fail "--wifi-pass-file/--wifi-hidden/--wifi-open need --wifi-ssid"
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
        [[ -z "$OPT_WIFI_PASS" ]] || fail "--wifi-open and a passphrase are contradictory"
    else
        [[ -n "$OPT_WIFI_PASS" ]] || fail "no passphrase given (use --wifi-pass-file, BOBCAT_WIFI_PASS, or --wifi-open)"
        pass_len="${#OPT_WIFI_PASS}"
        ((pass_len >= 8 && pass_len <= 64)) || fail "a WPA passphrase must be 8-63 characters (or 64 hex digits)"
    fi
fi
[[ -z "$OPT_NETPLAN_FILE" || "$OPT_NETPLAN_FILE" == "-" || -r "$OPT_NETPLAN_FILE" ]] ||
    fail "cannot read --netplan-file $OPT_NETPLAN_FILE"

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

mask_secrets() { sed -E 's/(password|psk|key)[^ ]*[:=].*/\1: <hidden>/I'; }

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

# Write a WPA/open Wi-Fi definition with PyYAML so any SSID/passphrase is quoted
# correctly. Secrets travel in the environment, never on a command line.
generate_wifi_yaml() {
    local out="$1" iface="$2"
    W_SSID="$OPT_WIFI_SSID" W_PASS="$OPT_WIFI_PASS" W_IFACE="$iface" \
    W_HIDDEN="$OPT_WIFI_HIDDEN" python3 - "$out" <<'PY'
import glob, os, sys
import yaml

ssid, pw, iface = os.environ["W_SSID"], os.environ["W_PASS"], os.environ["W_IFACE"]
hidden = os.environ["W_HIDDEN"] == "1"
out = sys.argv[1]
mine = os.path.basename(out)

for path in sorted(glob.glob("/etc/netplan/*.yaml")):
    if os.path.basename(path) == mine:
        continue
    try:
        doc = yaml.safe_load(open(path)) or {}
    except Exception as exc:
        sys.exit(f"cannot read {path}: {exc}")
    for dev in ((doc.get("network") or {}).get("wifis") or {}).values():
        aps = (dev or {}).get("access-points") or {}
        if ssid in {str(k) for k in aps}:
            sys.exit(
                f"this SSID is already defined in {path}; netplan rejects duplicate "
                "access points. Edit it there, or pass a complete config with --netplan-file"
            )

ap = {}
if hidden:
    ap["hidden"] = True
if pw:
    ap["password"] = pw
doc = {"network": {"version": 2, "renderer": "NetworkManager", "wifis": {
    iface: {"dhcp4": True, "optional": True, "access-points": {ssid: ap}}}}}
with open(out, "w") as fh:
    fh.write("# Generated by bobcat-g295-install.sh\n")
    yaml.safe_dump(doc, fh, sort_keys=False, allow_unicode=True)
PY
}

setup_network() {
    [[ -n "$OPT_WIFI_SSID" || -n "$OPT_NETPLAN_FILE" ]] || return 0
    log "Network configuration (netplan)"

    have netplan || fail "netplan is not installed (apt install netplan.io)"
    python3 -c 'import yaml' 2>/dev/null || fail "python3-yaml is missing (it normally comes with netplan)"
    systemctl is-active --quiet NetworkManager ||
        fail "NetworkManager is not running; this installer renders netplan through NetworkManager"

    local stage new name iface="" out backup revert
    stage="$(mktemp -d)"
    chmod 700 "$stage"

    # 1. Produce the file to install.
    if [[ -n "$OPT_WIFI_SSID" ]]; then
        iface="$(nmcli -t -f DEVICE,TYPE dev 2>/dev/null | awk -F: '$2=="wifi" { print $1; exit }')"
        [[ -n "$iface" ]] || fail "no Wi-Fi interface found on this machine"
        name="60-bobcat-wifi.yaml"
        new="$stage/$name"
        generate_wifi_yaml "$new" "$iface" || { rm -rf "$stage"; fail "could not build the Wi-Fi netplan file"; }
        note "Wi-Fi: SSID '$OPT_WIFI_SSID' on $iface$([[ $OPT_WIFI_HIDDEN -eq 1 ]] && echo ' (hidden)')"
    else
        name="60-bobcat-custom.yaml"
        new="$stage/$name"
        if [[ "$OPT_NETPLAN_FILE" == "-" ]]; then cat > "$new"; else cp "$OPT_NETPLAN_FILE" "$new"; fi
        grep -q '^network:' "$new" || { rm -rf "$stage"; fail "that file does not look like a netplan config (no top-level 'network:')"; }
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
    if [[ -n "$iface" ]]; then
        # Bring up just the new Wi-Fi profile; do not disturb other links.
        nmcli --wait 30 connection up "netplan-$iface-$OPT_WIFI_SSID" >/dev/null 2>&1 ||
            nmcli --wait 30 device connect "$iface" >/dev/null 2>&1 || true
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

    if [[ -n "$iface" ]]; then
        if wait_for 30 wifi_connected "$iface"; then
            note "Wi-Fi up: $(ip -br -4 addr show "$iface" | awk '{ print $3 }')"
        else
            warn "the network works (another link) but $iface did not join '$OPT_WIFI_SSID'"
            note "check the passphrase; hidden network? add --wifi-hidden; this chip is 2.4 GHz only"
            note "details: journalctl -u NetworkManager -n 40 --no-pager"
        fi
    fi
    OPT_WIFI_PASS=""
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

write_config() {
    log "Reticulum configuration"
    mkdir -p "$CONFIGDIR/interfaces"
    ln -sfn "$PREFIX/sx1302_rns/interfaces/SX1302.py" "$CONFIGDIR/interfaces/SX1302.py"

    if [[ -e "$CONFIGDIR/config" && "$OPT_FORCE_CONFIG" -eq 0 ]]; then
        note "keeping existing $CONFIGDIR/config (use --force-config to replace it)"
        grep -q 'type = SX1302' "$CONFIGDIR/config" ||
            warn "the existing config has no SX1302 interface; add the [[SX1302 LoRa]] stanza or use --force-config"
        return
    fi
    if [[ -e "$CONFIGDIR/config" ]]; then
        cp -a "$CONFIGDIR/config" "$CONFIGDIR/config.bak.$(date +%Y%m%d%H%M%S)"
        note "old config backed up"
    fi

    local transport="yes"
    [[ "$OPT_TRANSPORT" -eq 1 ]] || transport="no"

    {
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
    # RNode 1-byte framing is on by default; needed to talk to real RNodes.
    # rnode_framing = yes
EOF
        [[ -z "$OPT_FREQ" ]] || echo "    frequency = $OPT_FREQ"
        [[ -z "$OPT_BW"   ]] || echo "    bandwidth = $OPT_BW"
        [[ -z "$OPT_SF"   ]] || echo "    spreadingfactor = $OPT_SF"
        [[ -z "$OPT_CR"   ]] || echo "    codingrate = $OPT_CR"
        [[ -z "$OPT_TXP"  ]] || echo "    txpower = $OPT_TXP"
    } > "$CONFIGDIR/config"
    note "wrote $CONFIGDIR/config"
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

main() {
    preflight
    setup_network
    if [[ "$OPT_NETWORK_ONLY" -eq 1 ]]; then
        log "Network step finished (--network-only)"
        return 0
    fi
    install_packages
    install_code
    write_config
    install_service
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

  Never power the radio without the antenna attached. TX power is capped at 16 dBm
  until the TX gain table has been measured on your unit.
EOF
    return "$ok"
}

main
exit $?

__PAYLOAD_BELOW__
