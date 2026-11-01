#!/bin/bash
# Every timer in systemd/ keeps running through the night the clocks go back.
#
# The night the clocks went back an hour, the server this template comes
# from ran none of its local-time "*:0/5" timers for that hour: systemd
# reads a local calendar in wall-clock time and took the repeated hour as
# already gone. A watchdog that
# runs every two minutes ran 8 times in that window instead of about 38. A
# calendar written in UTC has no repeated hour.
#
#   the rule    every systemd/*.timer: its OnCalendar ends in UTC, and it has
#               an OnUnitActiveSec net longer than its period and at most twice
#               it, so a missed run is made up within one more period, and a
#               run on time resets the net before it fires
#   the night   systemd-analyze, on Berlin time, from one second before its
#               fall-back on 2026-10-25: each calendar's next run falls inside
#               the repeated hour; the same calendar without UTC (the plant) is
#               seen to skip it, so this test can tell the two apart. Any zone
#               with a fall-back shows the same.
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

command -v systemd-analyze >/dev/null || { echo "systemd-analyze is not here: this test needs a systemd host"; exit 2; }
NIGHT="2026-10-25 00:59:59 UTC"
REPEAT_END=$(date -u -d "2026-10-25 02:00:00 UTC" +%s)

# The runs a calendar makes after the base time, as UTC epoch seconds.
runs() {
  TZ=Europe/Berlin systemd-analyze calendar --base-time="$NIGHT" --iterations=3 "$1" 2>/dev/null \
    | sed -n 's/.*(in UTC): //p' \
    | while read -r when; do date -u -d "$when" +%s; done
}
# A systemd time span in seconds.
seconds() {
  systemd-analyze timespan "$1" 2>/dev/null | sed -n 's/^ *μs: //p' | awk '{print int($1 / 1000000)}'
}

shopt -s nullglob
timers=(systemd/*.timer)
[ "${#timers[@]}" -gt 0 ] && pass "systemd/ has ${#timers[@]} timer(s)" || fail "systemd/ has no timers to check"

for t in "${timers[@]}"; do
  echo "=== $t ==="
  cal=$(sed -n 's/^OnCalendar=//p' "$t")
  net=$(sed -n 's/^OnUnitActiveSec=//p' "$t")
  [ "$(printf '%s\n' "$cal" | grep -c .)" = 1 ] && pass "one OnCalendar: $cal" || { fail "expected one OnCalendar line"; continue; }
  [[ "$cal" == *" UTC" ]] && pass "the calendar is in UTC" || fail "the calendar is local time: \"$cal\" skips the repeated hour when the clocks go back"

  mapfile -t r < <(runs "$cal")
  [ "${#r[@]}" -ge 2 ] && pass "systemd-analyze reads it" || { fail "systemd-analyze could not read \"$cal\""; continue; }
  period=$(( r[1] - r[0] ))
  [ "${r[0]}" -lt "$REPEAT_END" ] && pass "it runs inside the repeated hour ($(date -u -d "@${r[0]}" +%H:%M:%S) UTC)" \
    || fail "its next run after $NIGHT is $(date -u -d "@${r[0]}" '+%H:%M:%S') UTC, after the repeated hour"

  plant="${cal% UTC}"
  mapfile -t p < <(runs "$plant")
  [ "${#p[@]}" -ge 1 ] && [ "${p[0]}" -ge "$REPEAT_END" ] && pass "the plant, \"$plant\" on local time, is seen to skip the hour" \
    || fail "the plant \"$plant\" did not skip the hour, so this test cannot tell UTC from local time here"

  [ -n "$net" ] || { fail "no OnUnitActiveSec net under the calendar"; continue; }
  n=$(seconds "$net")
  [ -n "$n" ] && [ "$n" -gt "$period" ] && [ "$n" -le $(( 2 * period )) ] \
    && pass "the net, $net, is longer than the period (${period}s) and at most twice it" \
    || fail "the net, $net (${n:-?}s), must be longer than the period (${period}s) and at most twice it"
done

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
