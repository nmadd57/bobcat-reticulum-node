#!/usr/bin/env bash
#
# Tests for bobcat-logprune on a throwaway directory: only old rotated archives are
# removed, current logs and the live journal are never touched, the size cap works.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/bobcat-logprune"
pass=0 failed=0
ok()    { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '     %s\n' "$2"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
D="$T/log.hdd"

mk() {   # mk <path> <age in days> [size in KiB]
    mkdir -p "$(dirname "$D/$1")"
    head -c "$(( ${3:-1} * 1024 ))" /dev/zero > "$D/$1"
    touch -d "$2 days ago" "$D/$1"
}
fresh() { rm -rf "$D"; mkdir -p "$D"; : > "$T/conf"; }
run() { OUT="$(env -i PATH=/usr/bin:/bin LOGPRUNE_DIR="$D" LOGPRUNE_CONF="$T/conf" BASH_ENV=/dev/null bash "$SCRIPT" 2>&1)"; RC=$?; }
exists() { [[ -e "$D/$1" ]]; }

# 1. by age
fresh
mk syslog 0; mk auth.log 40; mk syslog.1 20; mk syslog.2.gz 30; mk dpkg.log.3.xz 15; mk old.log.old 99
mk syslog.4.gz 3; mk kern.log.1 5
mk journal/abc/system.journal 90                         # live journal: never touched, however old
mk journal/abc/system@dead.journal~ 30                    # unclean leftover: archive, old
mk journal/abc/system@new.journal~ 2                      # unclean leftover, recent
mkdir -p "$D/journal-20260101-00:00:00"; touch -d "30 days ago" "$D/journal-20260101-00:00:00"
mkdir -p "$D/journal-20261101-00:00:00"; touch -d "2 days ago" "$D/journal-20261101-00:00:00"
run
check "age: exit 0" "$RC" 0
for f in syslog.1 syslog.2.gz dpkg.log.3.xz old.log.old journal/abc/system@dead.journal~ journal-20260101-00:00:00; do
    exists "$f" && bad "age: $f (old) removed" || ok "age: $f (old) removed"
done
for f in syslog auth.log syslog.4.gz kern.log.1 journal/abc/system.journal journal/abc/system@new.journal~ journal-20261101-00:00:00; do
    exists "$f" && ok "age: $f kept" || bad "age: $f kept"
done
[[ "$OUT" == *"removed 6 old log file(s)"* ]] && ok "age: summary says what happened" || bad "age: summary" "$OUT"

# 2. a current log is never deleted, however old it is
fresh; mk syslog 400; mk kern.log 400; mk journal/x/system.journal 400; run
check "current logs and the live journal survive any age" "$(exists syslog && exists kern.log && exists journal/x/system.journal && echo yes)" yes
check "nothing to do: silent" "$OUT" ""

# 3. size cap: oldest archives go first, newest kept
fresh; printf 'LOG_MAX_MB=20\n' > "$T/conf"
mk syslog 0 100
mk a.1 2 8000; mk b.2.gz 4 8000; mk c.3.gz 6 8000; mk d.4.gz 8 8000     # 32 MB of archives, all within 14 days
run
for f in a.1 b.2.gz; do exists "$f" && ok "cap: newer $f kept" || bad "cap: newer $f kept"; done
for f in d.4.gz c.3.gz; do exists "$f" && bad "cap: older $f removed first" || ok "cap: older $f removed first"; done
check "cap: current log kept" "$(exists syslog && echo yes)" yes
size="$(du -sb --exclude=journal "$D" | cut -f1)"
(( size <= 20 * 1024 * 1024 )) && ok "cap: total is under the limit now" || bad "cap: total is under the limit now" "$size"

# 4. the live journal does not count towards the cap and is not pruned for it
fresh; printf 'LOG_MAX_MB=20\n' > "$T/conf"; mk journal/x/system.journal 0 30000; mk syslog.1 1 1000; run
check "journal size is journald's job: not counted" "$(exists journal/x/system.journal && exists syslog.1 && echo yes)" yes

# 5. cap cannot be met with archives alone: stops cleanly, keeps current logs
fresh; printf 'LOG_MAX_MB=20\n' > "$T/conf"; mk big.log 0 30000; mk x.1 1 100; run
check "cap too tight: archives gone, current log kept, no error" "$RC $(exists big.log && echo kept) $(exists x.1 && echo present)" "0 kept "

# 6. settings
fresh; printf 'LOG_KEEP_DAYS=3\n' > "$T/conf"; mk a.1 2; mk b.1 5; run
check "LOG_KEEP_DAYS is honoured" "$(exists a.1 && echo keep)/$(exists b.1 && echo keep)" "keep/"
fresh; printf 'LOG_KEEP_DAYS=0\nLOG_KEEP_DAYS=abc\nLOG_MAX_MB=1\nEVIL=1\n' > "$T/conf"; mk a.1 10; run
check "out-of-range and junk settings fall back to defaults (14 days)" "$(exists a.1 && echo kept)" kept
fresh; printf 'LOG_KEEP_DAYS=3\r\n' > "$T/conf"; mk a.1 5; run
check "CRLF settings are read" "$(exists a.1 && echo kept || echo removed)" removed

# 7. odd cases
rm -rf "$D"; run
check "missing log directory: exit 0, no noise" "$RC|$OUT" "0|"
fresh; mk 'weird name.log.1' 30; mk 'ünï.log.2.gz' 30; run
check "file names with spaces and unicode are handled" "$(exists 'weird name.log.1' || exists 'ünï.log.2.gz' && echo left || echo gone)" gone
fresh; mk syslog.20261115 30; run
check "date-suffixed rotations (.20261115) count as archives" "$(exists syslog.20261115 && echo kept || echo removed)" removed

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[[ "$failed" -eq 0 ]]
