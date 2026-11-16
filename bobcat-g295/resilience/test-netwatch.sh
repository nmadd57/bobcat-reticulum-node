#!/usr/bin/env bash
#
# Tests for bobcat-netwatch: escalation, recovery, reboot cooldown, and the cases
# where it must do nothing. Network commands are stubs; nothing real is touched.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/bobcat-netwatch"
pass=0 failed=0
ok()    { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '     %s\n' "$2"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

new_world() {   # fresh state: stubs, config, healthy network
    T="$(mktemp -d)"
    mkdir -p "$T/bin" "$T/state" "$T/persist"
    : > "$T/calls"
    echo 0 > "$T/ping_rc"
    echo "default via 192.0.2.1 dev wlan0 proto dhcp" > "$T/route"
    printf '802-11-wireless:yes\n802-3-ethernet:yes\n' > "$T/nm_conns"
    printf 'wlan0:wifi\nend0:ethernet\nlo:loopback\n' > "$T/nm_devices"
    printf 'brcmfmac_wcc  12288  0\nbrcmfmac  372736  1 brcmfmac_wcc\nbrcmutil  16384  1 brcmfmac\n' > "$T/lsmod"
    for c in systemctl modprobe logger sleep; do
        printf '#!/bin/sh\necho "%s $*" >> "$T/calls"\n' "$c" > "$T/bin/$c"
    done
    printf '#!/bin/sh\n:\n' > "$T/bin/sleep"
    printf '#!/bin/sh\ncat "$T/lsmod"\n' > "$T/bin/lsmod"
    printf '#!/bin/sh\ncase "$*" in\n  *"show"*) cat "$T/nm_conns";;\n  *"device"*"disconnect"*|*"device"*"connect"*) echo "nmcli $*" >> "$T/calls";;\n  *device*) cat "$T/nm_devices";;\nesac\n' > "$T/bin/nmcli"
    printf '#!/bin/sh\n[ "$1 $2 $3" = "route show default" ] && cat "$T/route"\n' > "$T/bin/ip"
    printf '#!/bin/sh\necho "ping $*" >> "$T/calls"\nexit $(cat "$T/ping_rc")\n' > "$T/bin/ping"
    chmod +x "$T/bin/"*
    printf 'REBOOT_MINUTES=12\n' > "$T/conf"
}

run_once() {
    OUT="$(env -i PATH="$T/bin:/usr/bin:/bin" T="$T" NETWATCH_CONF="$T/conf" NETWATCH_STATE_DIR="$T/state" \
        NETWATCH_PERSIST_DIR="$T/persist" BASH_ENV=/dev/null bash "$SCRIPT" 2>&1)"
    RC=$?
}
run_n() { local i; for ((i = 0; i < $1; i++)); do run_once; done; }
calls() { cat "$T/calls"; }
count() { grep -c -- "$1" "$T/calls" || true; }
fails() { cat "$T/state/fails" 2>/dev/null || echo "-"; }

# 1. healthy network: no actions
new_world; run_n 5
check "healthy: counter stays 0" "$(fails)" 0
check "healthy: no recovery actions at all" "$(count -E 'nmcli|systemctl|modprobe')" 0
check "healthy: exit 0" "$RC" 0

# 2. escalation, minute by minute
new_world; echo 1 > "$T/ping_rc"
run_n 2
check "fail 1-2: nothing yet" "$(count -E 'nmcli|systemctl|modprobe')" 0
run_n 1
check "minute 3: Wi-Fi is reconnected" "$(count 'device disconnect wlan0')/$(count 'device connect wlan0')" "1/1"
run_n 2
check "minute 5: still just that" "$(count -E 'systemctl|modprobe')" 0
run_n 1
check "minute 6: NetworkManager restarted" "$(count 'systemctl restart NetworkManager')" 1
run_n 2
check "minute 8: nothing more" "$(count 'modprobe')" 0
run_n 1
check "minute 9: the Wi-Fi driver is unloaded and reloaded" "$(count 'modprobe -r brcmfmac_wcc brcmfmac brcmutil')/$(count 'modprobe brcmfmac$')" "1/1"
check "minute 9: and NetworkManager restarted again" "$(count 'systemctl restart NetworkManager')" 2
run_n 2
check "minute 11: no reboot yet" "$(count 'systemctl reboot')" 0
run_n 1
check "minute 12: reboot" "$(count 'systemctl reboot')" 1
[[ -s "$T/persist/netwatch-last-reboot" ]] && ok "reboot time is recorded" || bad "reboot time is recorded"
run_n 3
check "after the reboot call: the cooldown stops a second one" "$(count 'systemctl reboot')" 1
[[ "$OUT" == *"not rebooting again"* ]] && ok "cooldown is explained in the log" || bad "cooldown is explained in the log" "$OUT"

# 3. recovery resets everything
new_world; echo 1 > "$T/ping_rc"; run_n 7
echo 0 > "$T/ping_rc"; run_once
check "recovery: counter reset" "$(fails)" 0
[[ "$OUT" == *"network is back after 7 minute(s)"* ]] && ok "recovery: reported" || bad "recovery: reported" "$OUT"
echo 1 > "$T/ping_rc"; : > "$T/calls"; run_n 2
check "recovery: escalation starts over from minute 1" "$(count 'device ')" 0

# 4. a recent reboot blocks another
new_world; echo 1 > "$T/ping_rc"; date +%s > "$T/persist/netwatch-last-reboot"; run_n 15
check "cooldown: no reboot within 3 hours of the last" "$(count 'systemctl reboot')" 0
echo $(( $(date +%s) - 20000 )) > "$T/persist/netwatch-last-reboot"; run_once
check "cooldown: allowed again after 3 hours" "$(count 'systemctl reboot')" 1

# 5. REBOOT_MINUTES=0 never reboots
new_world; echo 1 > "$T/ping_rc"; printf 'REBOOT_MINUTES=0\n' > "$T/conf"; run_n 40
check "REBOOT_MINUTES=0: never reboots" "$(count 'systemctl reboot')" 0
check "REBOOT_MINUTES=0: still tries the soft steps" "$(count 'device connect wlan0')" 1

# 6. nothing to watch: no connection profiles
new_world; echo 1 > "$T/ping_rc"; : > "$T/nm_conns"; run_n 30
check "no network profile: no actions" "$(count -E 'nmcli device|systemctl|modprobe')" 0
check "no network profile: counter stays 0" "$(fails)" 0
new_world; echo 1 > "$T/ping_rc"; printf '802-11-wireless:no\n' > "$T/nm_conns"; run_n 30
check "profile without autoconnect: no actions" "$(count -E 'systemctl|modprobe')" 0

# 7. gateway handling
new_world; echo 1 > "$T/ping_rc"; : > "$T/route"; run_n 3
check "no default route counts as failure" "$(fails)" 3
check "no default route: ping is not even attempted" "$(count '^ping')" 0
new_world; printf 'TARGET=198.51.100.9\nREBOOT_MINUTES=12\n' > "$T/conf"; run_once
check "TARGET is pinged instead of the gateway" "$(count 'ping -c 2 -W 3 198.51.100.9')" 1
new_world; run_once
check "default: the gateway is pinged" "$(count 'ping -c 2 -W 3 192.0.2.1')" 1

# 8. missing pieces are tolerated
new_world; echo 1 > "$T/ping_rc"; printf 'end0:ethernet\n' > "$T/nm_devices"; run_n 3
[[ "$OUT" == *"no Wi-Fi device"* ]] && ok "no Wi-Fi device: said so and carried on" || bad "no Wi-Fi device" "$OUT"
new_world; echo 1 > "$T/ping_rc"; : > "$T/lsmod"; run_n 9
check "driver built in: no modprobe" "$(count modprobe)" 0
[[ "$OUT" == *"not a loadable module"* ]] && ok "driver built in: explained" || bad "driver built in: explained" "$OUT"

# 9. config parsing is strict
new_world; echo 1 > "$T/ping_rc"; printf 'REBOOT_MINUTES=abc\nTARGET=bad target!\nEVIL=1\n' > "$T/conf"; run_once
check "bad settings are ignored (default gateway still pinged)" "$(count 'ping -c 2 -W 3 192.0.2.1')" 1
new_world; echo 1 > "$T/ping_rc"; printf 'REBOOT_MINUTES=20\r\nTARGET=198.51.100.7\r\n' > "$T/conf"; run_once
check "CRLF config is read" "$(count 'ping -c 2 -W 3 198.51.100.7')" 1
new_world; rm -f "$T/conf"; run_once
check "missing config: defaults apply" "$RC" 0

# 10. corrupt state file does not break it
new_world; echo 1 > "$T/ping_rc"; echo "garbage" > "$T/state/fails"; run_once
check "corrupt counter file: restarts from 1" "$(fails)" 1

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[[ "$failed" -eq 0 ]]
