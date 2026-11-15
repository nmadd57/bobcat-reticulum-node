#!/usr/bin/env bash
#
# Tests for bobcat-firstboot: config parsing, option building, secrets handling.
# Runs the real script against a stub installer; touches nothing outside a
# temporary directory.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/bobcat-firstboot"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0 failed=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '     %s\n' "$2"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
has()   { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1" "missing [$2]"; fi; }
hasnt() { if grep -qF -- "$2" <<<"$3"; then bad "$1" "unexpected [$2]"; else ok "$1"; fi; }

# The stub records each argument on its own line and the pass file's mode/length.
cat > "$T/stub" <<'STUB'
#!/bin/bash
out="$BOBCAT_TEST_OUT"
: > "$out"
for a in "$@"; do printf 'ARG %s\n' "$a" >> "$out"; done
while [[ $# -gt 0 ]]; do
    if [[ "$1" == --wifi-pass-file ]]; then
        printf 'PASSFILE mode=%s content=%s\n' "$(stat -c %a "$2")" "$(cat "$2")" >> "$out"
    fi
    shift
done
exit "${STUB_RC:-0}"
STUB
chmod +x "$T/stub"

run() {   # run [ENV=val ...]; returns installer args in $T/out, script output in $OUT
    rm -rf "$T/state" "$T/out"
    OUT="$(env BOBCAT_INSTALLER="$T/stub" BOBCAT_STATE="$T/state" BOBCAT_LOG="$T/log" \
        BOBCAT_CONF_BAKED="$T/baked.conf" BOBCAT_CONF_BOOT="$T/boot.conf" \
        BOBCAT_NETPLAN_BOOT="$T/np.yaml" BOBCAT_TEST_SKIP_SYSTEM=1 \
        BOBCAT_TEST_OUT="$T/out" "$@" "$SCRIPT" 2>&1)"
    RC=$?
    ARGS="$(cat "$T/out" 2>/dev/null || true)"
}

: > "$T/baked.conf"; : > "$T/boot.conf"; rm -f "$T/np.yaml"

# 1. no configuration at all
run
check "no config: exit 0" "$RC" 0
check "no config: installer gets no arguments" "$ARGS" ""
[[ -e "$T/state/firstboot.done" ]] && ok "no config: done marker written" || bad "no config: done marker written"

# 2. Wi-Fi from the boot partition: quoting, CRLF, unknown keys, injection
printf 'WIFI_SSID="My Net"\r\nWIFI_PASS=pa ss"w$(touch %s/PWNED)rd\r\nWIFI_HIDDEN=1\nFREQUENCY=915000000\nTXPOWER=14\nTRANSPORT=no\nEVIL=1\n# comment\nlowercase=bad\n' "$T" > "$T/boot.conf"
run
check "wifi: exit 0" "$RC" 0
has   "wifi: ssid argument" "ARG My Net" "$ARGS"
has   "wifi: hidden flag" "ARG --wifi-hidden" "$ARGS"
has   "wifi: frequency" "ARG 915000000" "$ARGS"
has   "wifi: no-transport" "ARG --no-transport" "$ARGS"
has   "wifi: passphrase read from a file, mode 600" "PASSFILE mode=600" "$ARGS"
has   "wifi: passphrase survives quotes and \$()" 'content=pa ss"w$(touch '"$T"'/PWNED)rd' "$ARGS"
hasnt "wifi: passphrase never on the command line" "ARG pa ss" "$ARGS"
[[ ! -e "$T/PWNED" ]] && ok "wifi: no command injection" || bad "wifi: no command injection"
has   "wifi: unknown key reported" "ignoring unknown key EVIL" "$OUT"
hasnt "wifi: lowercase keys ignored silently" "ignoring unknown key lowercase" "$OUT"
check "wifi: passphrase scrubbed from boot conf" "$(tr -d '\r' < "$T/boot.conf" | grep -c 'WIFI_PASS=$')" 1

# 3. baked config + boot config override; open network; netplan file ignored
printf 'SPREADINGFACTOR=9\nWIFI_SSID=baked\nWIFI_PASS=bakedpass123\n' > "$T/baked.conf"
printf 'WIFI_SSID=fromboot\nWIFI_OPEN=1\n' > "$T/boot.conf"
echo 'network: {}' > "$T/np.yaml"
run
has   "override: boot conf wins" "ARG fromboot" "$ARGS"
has   "override: open network flag" "ARG --wifi-open" "$ARGS"
has   "override: baked-only setting kept" "ARG 9" "$ARGS"
hasnt "override: no pass file for an open network" "PASSFILE" "$ARGS"
hasnt "override: netplan file ignored when WIFI_SSID is set" "--netplan-file" "$ARGS"

# 4. complete netplan file only
: > "$T/baked.conf"; : > "$T/boot.conf"
run
has   "netplan: file passed through" "ARG --netplan-file" "$ARGS"

# 5. installer failure: non-zero exit, no done marker (systemd retries)
rm -f "$T/np.yaml"
run STUB_RC=1
check "failure: exit 1" "$RC" 1
[[ ! -e "$T/state/firstboot.done" ]] && ok "failure: no done marker" || bad "failure: no done marker"

# 6. already done: does nothing
mkdir -p "$T/state"; touch "$T/state/firstboot.done"; rm -f "$T/out"
OUT="$(env BOBCAT_INSTALLER="$T/stub" BOBCAT_STATE="$T/state" BOBCAT_LOG="$T/log" BOBCAT_TEST_SKIP_SYSTEM=1 BOBCAT_TEST_OUT="$T/out" "$SCRIPT" 2>&1)"
[[ ! -e "$T/out" ]] && ok "done: installer not run again" || bad "done: installer not run again"

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[[ "$failed" -eq 0 ]]
