#!/usr/bin/env bash
#
# Build the single-file, self-extracting installer.
#
#   ./installer/build-installer.sh   ->   dist/bobcat-g295-install.sh
#
# The payload is sx1302_rns/ (including the vendored Semtech HAL) and
# bobcat-g295/ (profile, reset script, announce test), as a tar.gz appended to
# install-template.sh after the __PAYLOAD_BELOW__ marker line.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/dist"
OUT="$OUT_DIR/bobcat-g295-install.sh"
TEMPLATE="$ROOT/installer/install-template.sh"

[[ -f "$ROOT/sx1302_rns/vendor/sx1302_hal/libloragw/Makefile" ]] ||
    { echo "error: vendored HAL missing at sx1302_rns/vendor/sx1302_hal" >&2; exit 1; }
[[ -f "$ROOT/bobcat-g295/bobcat-g295-us915.conf" ]] ||
    { echo "error: bobcat-g295/ profile missing" >&2; exit 1; }
grep -c '^__PAYLOAD_BELOW__$' "$TEMPLATE" | grep -qx 1 ||
    { echo "error: template must contain the payload marker exactly once" >&2; exit 1; }

mkdir -p "$OUT_DIR"
PAYLOAD="$(mktemp)"
trap 'rm -f "$PAYLOAD"' EXIT

tar -C "$ROOT" \
    --exclude=.git --exclude=build --exclude=__pycache__ --exclude=.pytest_cache \
    --exclude='*.egg-info' --exclude='*.pyc' \
    --owner=0 --group=0 --numeric-owner \
    -czf "$PAYLOAD" sx1302_rns bobcat-g295

INFO="$(date -u +%Y-%m-%dT%H:%MZ), payload $(du -h "$PAYLOAD" | cut -f1)"
sed "s|@BUILD_INFO@|$INFO|" "$TEMPLATE" > "$OUT"
cat "$PAYLOAD" >> "$OUT"
chmod +x "$OUT"

bash -n "$TEMPLATE"
printf 'built %s (%s)\n' "$OUT" "$(du -h "$OUT" | cut -f1)"
