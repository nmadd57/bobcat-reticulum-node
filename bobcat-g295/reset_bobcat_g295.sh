#!/usr/bin/env bash
#
# Reset the onboard SX1302 on a Bobcat Miner 300 (G290/G295, RK3566).
#
# The reset line is GPIO4_C5: line offset 21 on the controller at 0xfe770000
# (labelled "gpio4"). That is global GPIO 149 in the old sysfs numbering and is
# named "lora-rst" in rk3566-bobcat.dtb. The kernel numbers gpiochips in probe
# order, so this script finds the right one by label or address instead of
# assuming gpiochipN.
#
# The SX1302 reset input is active high: low -> high pulse -> low, ending in
# the run state. If the Bobcat wiring turns out to be inverted, set
# SX1302_RESET_ACTIVE_LOW=1 (UNVERIFIED either way; the DTB has no polarity).
#
# Not touched on purpose:
#   * the LoRa 3V3 rail (GPIO3_25): an always-on kernel regulator owns it;
#   * the PA enable line: not in the DTB and unconfirmed (see the profile).
#
# Works with libgpiod v1 (Armbian bookworm ships 1.6.3) and v2. Check with:
# gpioset --version
#
# Usage:
#   ./reset_bobcat_g295.sh start
#   ./reset_bobcat_g295.sh stop
#
# Environment overrides:
#   SX1302_RESET_GPIO         line offset within the controller (default 21)
#   SX1302_GPIO_CHIP          gpiochip name, e.g. gpiochip4 (skips auto-detect)
#   SX1302_GPIO_CHIP_LABEL    label to look for (default gpio4)
#   SX1302_GPIO_CHIP_ADDR     controller address to look for (default fe770000)
#   SX1302_RESET_ACTIVE_LOW   1 = pulse low instead of high (default 0)
#   SX1302_RESET_WAIT         seconds to hold each level (default 0.1)

set -euo pipefail

ACTION="${1:-start}"
GPIO="${SX1302_RESET_GPIO:-21}"
GPIO_CHIP="${SX1302_GPIO_CHIP:-}"
CHIP_LABEL="${SX1302_GPIO_CHIP_LABEL:-gpio4}"
CHIP_ADDR="${SX1302_GPIO_CHIP_ADDR:-fe770000}"
ACTIVE_LOW="${SX1302_RESET_ACTIVE_LOW:-0}"
WAIT="${SX1302_RESET_WAIT:-0.1}"

usage() {
    printf 'usage: %s {start|stop}\n' "$(basename "$0")" >&2
}

if [[ "$ACTION" == "-h" || "$ACTION" == "--help" ]]; then
    usage
    exit 0
fi

if [[ "$ACTION" != "start" && "$ACTION" != "stop" ]]; then
    usage
    exit 2
fi

if ! [[ "$GPIO" =~ ^[0-9]+$ ]]; then
    printf 'error: SX1302_RESET_GPIO must be a numeric line offset\n' >&2
    exit 2
fi

if [[ "$ACTIVE_LOW" != "0" && "$ACTIVE_LOW" != "1" ]]; then
    printf 'error: SX1302_RESET_ACTIVE_LOW must be 0 or 1\n' >&2
    exit 2
fi

if ! [[ "$WAIT" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf 'error: SX1302_RESET_WAIT must be a non-negative number of seconds\n' >&2
    exit 2
fi

# gpioset v2 takes an integer hold period in milliseconds, so convert.
wait_whole="${WAIT%%.*}"
wait_frac=""
if [[ "$WAIT" == *.* ]]; then
    wait_frac="${WAIT#*.}"
fi
wait_frac="${wait_frac}000"
wait_frac="${wait_frac:0:3}"
WAIT_MS=$((10#${wait_whole:-0} * 1000 + 10#${wait_frac}))
if ((WAIT_MS < 1)); then
    WAIT_MS=1
fi

if ! command -v gpioset >/dev/null 2>&1; then
    printf 'error: gpioset not found; install libgpiod v2 (apt install gpiod)\n' >&2
    exit 1
fi

# libgpiod v2 takes "-c CHIP"; v1 takes the chip as a positional argument.
if gpioset --help 2>&1 | grep -q -- '--chip'; then
    GPIOD_V=2
else
    GPIOD_V=1
fi

# Find the gpiochip for the RK3566 "gpio4" bank.
find_chip() {
    local name

    # 1. By label, from gpiodetect: "gpiochip4 [gpio4] (32 lines)".
    if command -v gpiodetect >/dev/null 2>&1; then
        name="$(gpiodetect 2>/dev/null |
            awk -v want="[${CHIP_LABEL}]" '$2 == want { print $1; exit }')"
        if [[ -n "$name" ]]; then
            printf '%s\n' "$name"
            return 0
        fi
    fi

    # 2. By controller address through sysfs: .../fe770000.gpio/gpiochip*.
    local dev
    for dev in /sys/bus/platform/devices/"${CHIP_ADDR}".gpio*; do
        [[ -d "$dev" ]] || continue
        for name in "$dev"/gpio/gpiochip* "$dev"/gpiochip*; do
            [[ -e "$name" ]] || continue
            printf '%s\n' "$(basename "$name")"
            return 0
        done
    done

    return 1
}

if [[ -z "$GPIO_CHIP" ]]; then
    if ! GPIO_CHIP="$(find_chip)"; then
        printf 'error: could not find the gpio4 controller (label %s, address %s)\n' \
            "$CHIP_LABEL" "$CHIP_ADDR" >&2
        printf 'hint: run "gpiodetect" and set SX1302_GPIO_CHIP, e.g. gpiochip4\n' >&2
        exit 1
    fi
fi

if [[ ! -e "/dev/${GPIO_CHIP}" ]]; then
    printf 'error: /dev/%s does not exist\n' "$GPIO_CHIP" >&2
    exit 1
fi

printf 'reset %s: %s line %s (active-%s), hold %s ms\n' \
    "$ACTION" "$GPIO_CHIP" "$GPIO" "$([[ $ACTIVE_LOW == 1 ]] && echo low || echo high)" \
    "$WAIT_MS" >&2

# Active-high: idle level 0, so the pulse is low -> high -> low. Active-low
# is the mirror image.
if [[ "$ACTIVE_LOW" == "1" ]]; then
    idle=1
    pulse=0
else
    idle=0
    pulse=1
fi

gpio_pulse() {
    if [[ "$GPIOD_V" == "2" ]]; then
        # v2 toggle sequence: starts at the given value, toggles after each
        # period, and exits when the next period is 0.
        gpioset -t "${WAIT_MS}ms,${WAIT_MS}ms,0" -c "$GPIO_CHIP" "${GPIO}=${idle}"
    else
        # v1 has no toggle sequence: hold each level for one period and exit.
        local usec=$((WAIT_MS * 1000))
        gpioset --mode=time --usec="$usec" "$GPIO_CHIP" "${GPIO}=${idle}" &&
            gpioset --mode=time --usec="$usec" "$GPIO_CHIP" "${GPIO}=${pulse}" &&
            gpioset --mode=time --usec="$usec" "$GPIO_CHIP" "${GPIO}=${idle}"
    fi
}

if gpio_pulse; then
    # Let the SX1302 finish booting before the HAL opens SPI.
    sleep "$WAIT"
    exit 0
fi

printf 'error: could not drive line %s on %s\n' "$GPIO" "$GPIO_CHIP" >&2
if command -v gpioinfo >/dev/null 2>&1; then
    { gpioinfo "$GPIO_CHIP" || gpioinfo -c "$GPIO_CHIP"; } 2>/dev/null |
        grep -E "line[[:space:]]+${GPIO}:" >&2 || true
fi
printf 'hint: if another driver holds the line, stop it first (see gpioinfo)\n' >&2
exit 1
