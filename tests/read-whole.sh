#!/bin/bash
# Every script in scripts/ is read whole before it runs, and that is what
# keeps a run alive through an edit of its own file.
#
# bash reads a script as it executes it: after each command it reads on from
# the same byte offset, in whatever the file holds by then. A timer starts
# scripts/guard.sh every minute, and on the server this template comes from
# it was started while its file was being edited in place: a syntax error and
# a failed unit. So each script's body is one brace group, which bash parses
# in full before the first line runs, ending in exit.
#
#   the shape    every scripts/*.sh: the line after its header comment is
#                "{", its last line "}", the line before that an exit
#   both ways    a copy of the guard, paused inside its first command while
#                its own file is rewritten in place with "exit 9" at the
#                offset bash would read next: wrapped, it finishes as if
#                nothing happened; unwrapped, it runs the new text
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

echo "=== the shape ==="
echo
for f in scripts/*.sh; do
  first="$(awk 'NR > 1 && !/^#/ {print; exit}' "$f")"
  last="$(tail -1 "$f")"
  before="$(tail -2 "$f" | head -1)"
  if [ "$first" = "{" ] && [ "$last" = "}" ] && [[ $before == exit* ]] && bash -n "$f"; then
    pass "$f: one brace group, ending in \"$before\""
  else
    fail "$f: first command line \"$first\", ends \"$before\" / \"$last\""
  fi
done

echo
echo "=== both ways: the guard's own file rewritten under a running copy ==="
echo
# A copy of the repository's layout with the guard and stand-ins for what it
# calls: listening.sh takes two seconds and says "listening", and the dead
# connections are supplied, so the run ends in "nothing to do".
mkdir -p "$T/scripts"
printf '#!/bin/bash\nsleep 2\nexit 0\n' >"$T/scripts/listening.sh"
chmod +x "$T/scripts/listening.sh"
cp scripts/guard.sh "$T/scripts/guard.sh"
# The same guard without its braces: what every script here was before.
awk -v n="$(wc -l <scripts/guard.sh)" 'NR == n { next } !done && $0 == "{" { done = 1; next } { print }' scripts/guard.sh >"$T/scripts/unwrapped.sh"
chmod +x "$T/scripts/guard.sh" "$T/scripts/unwrapped.sh"
grep -qx '{' "$T/scripts/unwrapped.sh" && fail "the unwrapped copy still has its brace" || true

rewritten() {  # script: run it, and rewrite its file in place while it waits
  local f="$T/scripts/$1" line=scripts/listening.sh start off
  start="$(grep -b -x -m1 "$line" "$f" | cut -d: -f1)"
  off=$(( start + ${#line} + 1 ))   # just past that line: where bash reads next
  TERRARIA_DEAD_CONNECTIONS=0 TERRARIA_GUARD_STATE="$T/state" bash "$f" >"$T/out" 2>&1 &
  local pid=$!
  sleep 1
  { head -c "$off" "$f"; echo 'echo "INJECTED: read from the file after it started"; exit 9'; tail -c +"$(( off + 1 ))" "$f"; } >"$T/new"
  cat "$T/new" >"$f"   # in place: same file, same inode, as an editor that saves in place
  wait "$pid"
}

rewritten guard.sh; rc=$?
out="$(cat "$T/out")"
[ "$rc" = 0 ] && grep -q "listening: nothing to do" <<<"$out" && ! grep -q INJECTED <<<"$out" \
  && pass "wrapped: rewritten mid-run, it ran the text it started with and exited 0 (${out#* * })" \
  || fail "wrapped: exit $rc, $out"
rewritten unwrapped.sh; rc=$?
out="$(cat "$T/out")"
[ "$rc" = 9 ] && grep -q INJECTED <<<"$out" \
  && pass "unwrapped: the same rewrite, and it ran the new text, exit 9: what the braces prevent" \
  || fail "unwrapped: exit $rc, $out (the fault this guards against did not happen)"

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
