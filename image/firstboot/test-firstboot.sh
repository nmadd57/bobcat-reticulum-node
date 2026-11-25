#!/usr/bin/env bash
#
# Tests for bobcat-firstboot: seeding the settings into the installed system,
# merging, side files, secret handling. Runs the real script against a stub
# installer; touches nothing outside a temporary directory.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/bobcat-firstboot"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0 failed=0
ok()    { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '     %s\n' "$2"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
has()   { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1" "missing [$2]"; fi; }
hasnt() { if grep -qF -- "$2" <<<"$3"; then bad "$1" "unexpected [$2]"; else ok "$1"; fi; }

# The stub records its arguments and a copy of the config file it was given.
cat > "$T/stub" <<'STUB'
#!/bin/bash
: > "$BOBCAT_TEST_ARGS"
for a in "$@"; do printf '%s\n' "$a" >> "$BOBCAT_TEST_ARGS"; done
[[ "$1" == --config && -r "$2" ]] && cat "$2" > "$BOBCAT_TEST_CONF_COPY"
if [[ -n "${BOBCAT_GPIO_DIR:-}" ]]; then
    : > "$BOBCAT_TEST_LED_DURING"
    : > "${BOBCAT_TEST_RED_DURING:-/dev/null}"
    for _ in $(seq 1 "${BOBCAT_TEST_STUB_LOOPS:-12}"); do
        cat "$BOBCAT_GPIO_DIR/gpio128/value" >> "$BOBCAT_TEST_LED_DURING"
        cat "$BOBCAT_GPIO_DIR/gpio130/value" >> "${BOBCAT_TEST_RED_DURING:-/dev/null}"; sleep 0.05
    done
fi
exit "${STUB_RC:-0}"
STUB
chmod +x "$T/stub"

reset_dirs() { rm -rf "${T:?}/gpio" "${T:?}/state" "${T:?}/seed" "${T:?}/boot" "${T:?}/hidden" "${T:?}/args" "${T:?}/conf"; mkdir -p "$T/boot"; }

run() {   # run [ENV=val ...]
    OUT="$(env BOBCAT_INSTALLER="$T/stub" BOBCAT_STATE="$T/state" BOBCAT_LOG="$T/log" \
        BOBCAT_SEED="$T/seed" BOBCAT_BOOT_DIR="$T/boot" BOBCAT_TEST_SKIP_SYSTEM=1 BOBCAT_RETRY_WAIT=0 \
        BOBCAT_TEST_ARGS="$T/args" BOBCAT_TEST_CONF_COPY="$T/conf" "$@" "$SCRIPT" 2>&1)"
    RC=$?
    ARGS="$(cat "$T/args" 2>/dev/null || true)"
    CONF="$(cat "$T/conf" 2>/dev/null || true)"
}

# 1. nothing on the boot partition
reset_dirs
run
check "no settings: exit 0" "$RC" 0
check "no settings: installer is given --config <effective file>" "$ARGS" "--config
$T/seed/effective.conf"
has   "no settings: says it will use defaults" "installing with defaults" "$OUT"
[[ -e "$T/state/firstboot.done" ]] && ok "no settings: done marker written" || bad "no settings: done marker written"
check "no settings: effective file is root-only" "$(stat -c %a "$T/seed/effective.conf")" 600
check "no settings: seed directory is root-only" "$(stat -c %a "$T/seed")" 700

# 2. settings with CRLF line endings, quotes, and a hostile passphrase
reset_dirs
printf 'WIFI_SSID="My Net"\r\nWIFI_PASS=pa ss"w$(touch %s/PWNED)rd\r\nFREQUENCY=915000000\r\n' "$T" > "$T/boot/bobcat-install.conf"
run
check "settings: exit 0" "$RC" 0
has   "settings: SSID reaches the installer's config" 'WIFI_SSID="My Net"' "$CONF"
has   "settings: passphrase line is carried verbatim" 'WIFI_PASS=pa ss"w$(touch' "$CONF"
hasnt "settings: CRLF is stripped" $'\r' "$CONF"
[[ ! -e "$T/PWNED" ]] && ok "settings: nothing is executed" || bad "settings: nothing is executed"
hasnt "settings: secrets never appear on the command line" "pa ss" "$ARGS"
check "settings: passphrase blanked on the FAT partition" "$(grep -c '^WIFI_PASS=$' "$T/boot/bobcat-install.conf")" 1
check "settings: other FAT lines untouched" "$(tr -d '\r' < "$T/boot/bobcat-install.conf" | grep -c '^FREQUENCY=915000000$')" 1
has   "settings: root-only copy keeps the passphrase for re-runs" 'WIFI_PASS=pa ss"w$(touch' "$(cat "$T/seed/effective.conf")"

# 3. IFAC passphrase is scrubbed too; SCRUB_BOOT_CONF=no keeps everything
reset_dirs
printf 'IFAC_NETNAME=net\nIFAC_PASSPHRASE=secret-one\nWIFI_PASS=secret-two\n' > "$T/boot/bobcat-install.conf"
run
check "scrub: IFAC passphrase blanked" "$(grep -c '^IFAC_PASSPHRASE=$' "$T/boot/bobcat-install.conf")" 1
check "scrub: IFAC network name kept" "$(grep -c '^IFAC_NETNAME=net$' "$T/boot/bobcat-install.conf")" 1
reset_dirs
printf 'SCRUB_BOOT_CONF=no\nWIFI_PASS=keepme123\n' > "$T/boot/bobcat-install.conf"
run
check "scrub: SCRUB_BOOT_CONF=no keeps the passphrase" "$(grep -c '^WIFI_PASS=keepme123$' "$T/boot/bobcat-install.conf")" 1

# 4. baked settings plus boot settings: boot wins (it comes later in the file)
reset_dirs
mkdir -p "$T/seed"; printf 'SPREADINGFACTOR=9\nFREQUENCY=868000000\n' > "$T/seed/install.conf"
printf 'FREQUENCY=915000000\n' > "$T/boot/bobcat-install.conf"
run
has   "merge: baked setting present" "SPREADINGFACTOR=9" "$CONF"
check "merge: boot setting comes after the baked one" \
      "$(grep -n 'FREQUENCY=' "$T/seed/effective.conf" | tail -1 | cut -d: -f2)" "FREQUENCY=915000000"

# 5. side files are copied into the system and referenced
reset_dirs
printf 'HOSTNAME=bobcat1\n' > "$T/boot/bobcat-install.conf"
printf 'ssh-ed25519 AAAAC3Nza test@host\n' > "$T/boot/bobcat-authorized_keys"
printf '[reticulum]\n' > "$T/boot/bobcat-reticulum.conf"
printf 'network: {}\n' > "$T/boot/bobcat-netplan.yaml"
run
has   "side files: authorized keys referenced" "SSH_AUTHORIZED_KEYS_FILE=$T/seed/files/authorized_keys" "$CONF"
has   "side files: Reticulum config referenced" "RETICULUM_CONFIG_FILE=$T/seed/files/reticulum.conf" "$CONF"
has   "side files: netplan file referenced when nothing else sets the network" "NETPLAN_FILE=$T/seed/files/netplan.yaml" "$CONF"
check "side files: copies are root-only" "$(stat -c %a "$T/seed/files/authorized_keys")" 600
cmp -s "$T/boot/bobcat-authorized_keys" "$T/seed/files/authorized_keys" && ok "side files: content preserved" || bad "side files: content preserved"

# 6. a netplan file is not combined with Wi-Fi/Ethernet settings; explicit keys win
reset_dirs
printf 'WIFI_SSID=Net\nWIFI_PASS=password123\n' > "$T/boot/bobcat-install.conf"
printf 'network: {}\n' > "$T/boot/bobcat-netplan.yaml"
run
hasnt "conflict: netplan file ignored when Wi-Fi is configured" "NETPLAN_FILE" "$CONF"
has   "conflict: and the log says so" "bobcat-netplan.yaml: not used" "$OUT"
reset_dirs
printf 'ETH_MODE=static\nETH_ADDRESS=192.0.2.9/24\n' > "$T/boot/bobcat-install.conf"
printf 'network: {}\n' > "$T/boot/bobcat-netplan.yaml"
run
hasnt "conflict: netplan file ignored when static Ethernet is configured" "NETPLAN_FILE" "$CONF"
reset_dirs
printf 'ETH_MODE=keep\n' > "$T/boot/bobcat-install.conf"
printf 'network: {}\n' > "$T/boot/bobcat-netplan.yaml"
run
has   "conflict: ETH_MODE=keep does not block a netplan file" "NETPLAN_FILE" "$CONF"
reset_dirs
printf 'RETICULUM_CONFIG_FILE=/somewhere/else.conf\n' > "$T/boot/bobcat-install.conf"
printf '[reticulum]\n' > "$T/boot/bobcat-reticulum.conf"
run
check "explicit key: not overridden by the side file" "$(grep -c 'RETICULUM_CONFIG_FILE' "$T/seed/effective.conf")" 1
[[ ! -e "$T/seed/files/reticulum.conf" ]] && ok "explicit key: side file is not copied" || bad "explicit key: side file is not copied"

# 7. retries do not pile up duplicate lines
reset_dirs
printf 'FREQUENCY=915000000\n' > "$T/boot/bobcat-install.conf"
run STUB_RC=1
check "failure: exit 1" "$RC" 1
[[ ! -e "$T/state/firstboot.done" ]] && ok "failure: no done marker (systemd retries)" || bad "failure: no done marker"
check "failure: FAT partition not scrubbed" "$(grep -c '^FREQUENCY=915000000$' "$T/boot/bobcat-install.conf")" 1
run
check "retry: effective file is rebuilt, not appended to" "$(grep -c '^FREQUENCY=915000000$' "$T/seed/effective.conf")" 1

# 8. already done: does nothing
rm -f "$T/args"
mkdir -p "$T/state"; touch "$T/state/firstboot.done"
OUT="$(env BOBCAT_INSTALLER="$T/stub" BOBCAT_STATE="$T/state" BOBCAT_LOG="$T/log" BOBCAT_SEED="$T/seed" \
    BOBCAT_BOOT_DIR="$T/boot" BOBCAT_TEST_SKIP_SYSTEM=1 BOBCAT_TEST_ARGS="$T/args" "$SCRIPT" 2>&1)"
[[ ! -e "$T/args" ]] && ok "done: installer not run again" || bad "done: installer not run again"

# 9. the settings are in the root filesystem's own /boot folder (hidden under the FAT mount)
reset_dirs
mkdir -p "$T/hidden"
printf 'WIFI_SSID=HiddenDirNet\nWIFI_PASS=secretsecret\nHOSTNAME=from-root-boot\n' > "$T/hidden/bobcat-install.conf"
run BOBCAT_HIDDEN_BOOT_DIR="$T/hidden"
check "hidden /boot: exit 0" "$RC" 0
has   "hidden /boot: settings are read" 'HOSTNAME=from-root-boot' "$CONF"
has   "hidden /boot: says where it found them" "root filesystem's /boot folder" "$OUT"
hasnt "hidden /boot: not treated as missing" "installing with defaults" "$OUT"
check "hidden /boot: passphrase cleared in that file after success" "$(grep -c '^WIFI_PASS=$' "$T/hidden/bobcat-install.conf")" 1

# 10. the FAT partition wins when both have a file
reset_dirs
mkdir -p "$T/hidden"
printf 'HOSTNAME=from-fat\n' > "$T/boot/bobcat-install.conf"
printf 'HOSTNAME=from-root-boot\n' > "$T/hidden/bobcat-install.conf"
run BOBCAT_HIDDEN_BOOT_DIR="$T/hidden"
has   "both: the FAT partition's file is used" 'HOSTNAME=from-fat' "$CONF"
hasnt "both: the other file is ignored" 'from-root-boot' "$CONF"

# 11. side files are found in the hidden folder too
reset_dirs
mkdir -p "$T/hidden"
printf 'ssh-ed25519 AAAA key\n' > "$T/hidden/bobcat-authorized_keys"
run BOBCAT_HIDDEN_BOOT_DIR="$T/hidden"
[[ -f "$T/seed/files/authorized_keys" ]] && ok "hidden /boot: side file is copied" || bad "hidden /boot: side file is copied"

# 12. nothing anywhere: the message names both places
reset_dirs
mkdir -p "$T/hidden"
run BOBCAT_HIDDEN_BOOT_DIR="$T/hidden"
has   "nothing found: defaults message names both folders" "$T/boot or $T/hidden" "$OUT"

# 13. RGB LED on GPIO lines 128 (blue), 129 (green), 130 (red): blue blink while installing,
#     red steady after a failed attempt, green steady when complete
mkgpio() { rm -rf "$T/gpio"; mkdir -p "$T/gpio"; : > "$T/gpio/export"; local g; for g in 128 129 130; do mkdir -p "$T/gpio/gpio$g"; : > "$T/gpio/gpio$g/direction"; echo 0 > "$T/gpio/gpio$g/value"; done; }
val() { cat "$T/gpio/gpio$1/value"; }
reset_dirs; mkgpio
run BOBCAT_GPIO_DIR="$T/gpio" BOBCAT_TEST_LED_DURING="$T/led-during"
SEEN="$(tr -d '\n' < "$T/led-during")"
[[ "$SEEN" == *0* && "$SEEN" == *1* ]] && ok "led: blue blinks while the installer runs (saw $SEEN)" || bad "led: blue blinks while the installer runs" "saw [$SEEN]"
check "led: complete is green (blue off)"  "$(val 128)" 0
check "led: complete is green (green on)"  "$(val 129)" 1
check "led: complete is green (red off)"   "$(val 130)" 0
check "led: lines are outputs" "$(cat "$T/gpio/gpio129/direction")" out
# failure: red blinks slowly during the wait, then the script exits 1 so systemd retries
reset_dirs; mkgpio
env BOBCAT_INSTALLER="$T/stub" BOBCAT_STATE="$T/state" BOBCAT_LOG="$T/log" BOBCAT_SEED="$T/seed" BOBCAT_BOOT_DIR="$T/boot" \
    BOBCAT_TEST_SKIP_SYSTEM=1 BOBCAT_TEST_ARGS="$T/args" BOBCAT_TEST_CONF_COPY="$T/conf" BOBCAT_GPIO_DIR="$T/gpio" \
    BOBCAT_RETRY_WAIT=2.5 STUB_RC=1 "$SCRIPT" >"$T/fail.out" 2>&1 &
FAILPID=$!
sleep 0.3; : > "$T/red-seen"
for _ in $(seq 1 40); do cat "$T/gpio/gpio130/value" >> "$T/red-seen"; sleep 0.05; done
SEEN="$(tr -d '\n' < "$T/red-seen")"
[[ "$SEEN" == *0* && "$SEEN" == *1* ]] && ok "failure: red blinks while waiting to retry" || bad "failure: red blinks while waiting to retry" "saw [$SEEN]"
check "failure: blue and green stay off" "$(cat "$T/gpio/gpio128/value")$(cat "$T/gpio/gpio129/value")" 00
wait "$FAILPID"; FRC=$?
check "failure: exit 1 after the wait" "$FRC" 1
[[ ! -e "$T/state/firstboot.done" ]] && ok "failure: no done marker" || bad "failure: no done marker"
reset_dirs
run BOBCAT_GPIO_DIR="$T/no-such-gpio-dir"
check "led: a missing GPIO interface does not break the install" "$RC" 0

# 14. no network: red steady while there is no address (after the grace period) WITHOUT holding the install back,
#     blue again once one appears, never a red left over after the install
reset_dirs; mkgpio
run BOBCAT_GPIO_DIR="$T/gpio" BOBCAT_TEST_LED_DURING="$T/led-during" BOBCAT_TEST_RED_DURING="$T/red-during" BOBCAT_TEST_STUB_LOOPS=60 \
    BOBCAT_NET_FLAG="$T/nonet" BOBCAT_NET_POLL=0.05 BOBCAT_NET_GRACE=6 BOBCAT_NET_CHECK=false
check "no network: the installer still runs and the script completes" "$RC" 0
RED="$(tr -d '\n' < "$T/red-during")"; BLUE="$(tr -d '\n' < "$T/led-during")"
[[ "$RED" == *1111* ]] && ok "no network: red goes steady during the install (saw ${RED:0:40}...)" || bad "no network: red goes steady during the install" "saw [$RED]"
has "no network: the log says so" "no network address" "$OUT"
check "no network: the install ends green, red off" "$(val 129)$(val 130)" 10
[[ ! -e "$T/nonet" ]] && ok "no network: the flag is cleaned up" || bad "no network: the flag is cleaned up"
# the network comes up part-way through: red, then blue blinking again
reset_dirs; mkgpio; rm -f "$T/net-up"
( sleep 0.6; touch "$T/net-up" ) &
run BOBCAT_GPIO_DIR="$T/gpio" BOBCAT_TEST_LED_DURING="$T/led-during" BOBCAT_TEST_RED_DURING="$T/red-during" BOBCAT_TEST_STUB_LOOPS=40 \
    BOBCAT_NET_FLAG="$T/nonet" BOBCAT_NET_POLL=0.05 BOBCAT_NET_GRACE=4 BOBCAT_NET_CHECK="[ -e $T/net-up ]"
wait
RED="$(tr -d '\n' < "$T/red-during")"; BLUE="$(tr -d '\n' < "$T/led-during")"
[[ "$RED" == *1111* && "$BLUE" == *1* && "${RED: -6}" != *1111* ]] && ok "network appears: red first, then it stops and blue blinks again" || bad "network appears: red then blue" "red=[$RED] blue=[$BLUE]"
has "network appears: the log says it is up" "network is up" "$OUT"
# a network that is up straight away never shows red
reset_dirs; mkgpio
run BOBCAT_GPIO_DIR="$T/gpio" BOBCAT_TEST_LED_DURING="$T/led-during" BOBCAT_TEST_RED_DURING="$T/red-during" BOBCAT_TEST_STUB_LOOPS=20 \
    BOBCAT_NET_FLAG="$T/nonet" BOBCAT_NET_POLL=0.05 BOBCAT_NET_GRACE=3 BOBCAT_NET_CHECK=true
hasnt "network up at once: no red message" "no network address" "$OUT"
[[ "$(tr -d '\n' < "$T/red-during")" != *1* ]] && ok "network up at once: red never lit" || bad "network up at once: red never lit"
printf '\n%d passed, %d failed\n' "$pass" "$failed"
[[ "$failed" -eq 0 ]]
