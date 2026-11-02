#!/bin/bash
# scripts/listening.sh never reads Docker's own failure as "closed".
#
# The guard restarts a server whose game port stays closed, and status.sh
# shows "Not accepting players" for one. Both learn "closed" from
# listening.sh, which used to take it from the exit code of docker compose
# exec. Measured with Compose 5.5.1 against a container restarted under a
# loop of execs, the exec itself fails in shapes a grep's answer can wear:
#
#   not running   'service "terraria-server" is not running' on stderr, exit 1
#   stopped       "cannot exec in a stopped state" on STDOUT, exit 128
#   killed        whatever was printed so far, then exit 137
#   missing       "OCI runtime exec failed: ..." on STDOUT, exit 126
#
# The first is the same 1 a grep that found nothing gives, and it comes when
# the container stops between listening.sh's own running check and the exec.
# A fake `docker` early in PATH plays each shape, and the real answers too.
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

BIN=$(mktemp -d)
trap 'rm -rf "$BIN"' EXIT
cat > "$BIN/docker" <<'SH'
#!/bin/bash
case " $* " in
  *" ps "*) [ "$FAKE" = gone ] || echo 0123456789ab; exit 0 ;;
esac
case "$FAKE" in
  notrunning) echo 'service "terraria-server" is not running' >&2; exit 1 ;;
  stopped)    echo "cannot exec in a stopped state"; exit 128 ;;
  killed)     exit 137 ;;
  missing)    echo 'OCI runtime exec failed: exec failed: unable to start container process: exec: "bash": executable file not found in $PATH'; exit 126 ;;
  noproc)     exit 3 ;;
  answer)     echo "$FAKE_OUT"; exit 0 ;;
esac
exit 99
SH
chmod +x "$BIN/docker"
export TERRARIA_SERVER_PORT=7777

# answer <fake> [output]: listening.sh's exit code
answer() { PATH="$BIN:$PATH" FAKE="$1" FAKE_OUT="${2:-}" scripts/listening.sh >/dev/null 2>&1; echo $?; }

echo "== the container's own answers"
[ "$(answer answer listening)" = 0 ] && pass "listening is 0" || fail "listening gave $(answer answer listening)"
[ "$(answer answer closed)" = 1 ] && pass "closed is 1" || fail "closed gave $(answer answer closed)"
[ "$(answer noproc)" = 3 ] && pass "no /proc/net/tcp to read is 3" || fail "no /proc gave $(answer noproc)"
[ "$(answer gone)" = 3 ] && pass "no running container is 3" || fail "no container gave $(answer gone)"

echo "== Docker failing on the way: cannot ask (3), never closed (1)"
for f in notrunning stopped killed missing; do
  [ "$(answer $f)" = 3 ] && pass "$f is 3" || fail "$f gave $(answer $f)"
done
[ "$(answer answer 'cannot exec in a stopped state')" = 3 ] && pass "any other text, even from an exec that ended with 0, is 3" || fail "stray text gave $(answer answer 'cannot exec in a stopped state')"

echo
echo "passed $PASSED, failed $FAILED"
[ "$FAILED" -eq 0 ]
