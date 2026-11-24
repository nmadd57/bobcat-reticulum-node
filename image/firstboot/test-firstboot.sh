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
if [[ -n "${BOBCAT_LED_DIR:-}" ]]; then
    { printf 'trigger=%s on=%s off=%s\n' "$(cat "$BOBCAT_LED_DIR/led-status/trigger")" \
        "$(cat "$BOBCAT_LED_DIR/led-status/delay_on" 2>/dev/null)" "$(cat "$BOBCAT_LED_DIR/led-status/delay_off" 2>/dev/null)"; } > "$BOBCAT_TEST_LED_DURING"
fi
exit "${STUB_RC:-0}"
STUB
chmod +x "$T/stub"

reset_dirs() { rm -rf "${T:?}/led" "${T:?}/state" "${T:?}/seed" "${T:?}/boot" "${T:?}/hidden" "${T:?}/args" "${T:?}/conf"; mkdir -p "$T/boot"; }

run() {   # run [ENV=val ...]
    OUT="$(env BOBCAT_INSTALLER="$T/stub" BOBCAT_STATE="$T/state" BOBCAT_LOG="$T/log" \
        BOBCAT_SEED="$T/seed" BOBCAT_BOOT_DIR="$T/boot" BOBCAT_TEST_SKIP_SYSTEM=1 \
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

# 13. status LED: fast blink while installing, steady on when complete, slow blink on failure
mkled() {   # mkled <trigger file content>
    rm -rf "$T/led"; mkdir -p "$T/led/led-status"; printf '%s\n' "$1" > "$T/led/led-status/trigger"; : > "$T/led/led-status/brightness"
}
reset_dirs; mkled "none timer [heartbeat] default-on"
run BOBCAT_LED_DIR="$T/led" BOBCAT_TEST_LED_DURING="$T/led-during"
check "led: fast blink while the installer runs" "$(cat "$T/led-during")" "trigger=timer on=150 off=150"
check "led: complete is steady on (trigger none)" "$(cat "$T/led/led-status/trigger")" none
check "led: complete is steady on (brightness 1)" "$(cat "$T/led/led-status/brightness")" 1
reset_dirs; mkled "none timer [heartbeat] default-on"
run BOBCAT_LED_DIR="$T/led" BOBCAT_TEST_LED_DURING="$T/led-during" STUB_RC=1
check "led: failure is a slow blink (on)" "$(cat "$T/led/led-status/delay_on")" 1000
check "led: failure is a slow blink (off)" "$(cat "$T/led/led-status/delay_off")" 1000
# without the timer trigger (a module that may not load): heartbeat while installing, off when retrying
reset_dirs; mkled "none [heartbeat] default-on"
run BOBCAT_LED_DIR="$T/led" BOBCAT_TEST_LED_DURING="$T/led-during"
check "led, no timer trigger: heartbeat while installing" "$(cut -d' ' -f1 "$T/led-during")" "trigger=heartbeat"
reset_dirs; mkled "none [heartbeat] default-on"
run BOBCAT_LED_DIR="$T/led" BOBCAT_TEST_LED_DURING="$T/led-during" STUB_RC=1
check "led, no timer trigger: off while waiting to retry" "$(cat "$T/led/led-status/brightness")" 0
reset_dirs
run BOBCAT_LED_DIR="$T/no-such-led-dir"
check "led: a missing LED does not break the install" "$RC" 0

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[[ "$failed" -eq 0 ]]
