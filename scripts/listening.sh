#!/bin/bash
# Is the game port in LISTEN inside the container?
#
#   scripts/listening.sh     exit 0 listening, 1 not listening, 3 cannot ask
#
# Read from the container's /proc/net/tcp, never by connecting: every
# connection to the game port takes one of the server's slots until the server
# decides it is a player, and one that never speaks the game's protocol is
# never released (see scripts/guard.sh). A probe that connects is the fault it
# would be looking for.
#
#   TERRARIA_SERVER_PORT    the game port      (default from .env, else 7777)
#   TERRARIA_COMPOSE_FILE   the compose file   (default terraria-server-docker-compose.yml)
#   COMPOSE_PROJECT_NAME    the project        (default terraria)
#
# Read whole before it runs: one brace group, ending in exit (scripts/guard.sh,
# "READ WHOLE BEFORE IT RUNS", says why).
{
set -uo pipefail
cd "$(dirname "$0")/.." || exit 3

PORT="${TERRARIA_SERVER_PORT:-$(grep -E '^TERRARIA_SERVER_PORT=' .env 2>/dev/null | tail -1 | cut -d= -f2-)}"
PORT="${PORT:-7777}"
COMPOSE_FILE=${TERRARIA_COMPOSE_FILE:-terraria-server-docker-compose.yml}
PROJECT=${COMPOSE_PROJECT_NAME:-terraria}

# A container that is not running is "cannot ask", not "not listening":
# docker compose exec fails with 1 either way.
[ -n "$(docker compose -f "$COMPOSE_FILE" -p "$PROJECT" ps -q --status running terraria-server 2>/dev/null)" ] || exit 3

# THE ANSWER IS A WORD, NOT AN EXIT CODE. The check above does not close the
# gap: a container that stops between it and the exec makes docker compose
# exec end with 1 ('service "terraria-server" is not running'), the same 1 a
# grep that found nothing gives, or with 128 and "cannot exec in a stopped
# state" printed on stdout (Compose 5.5.1, measured against restarts). So the
# container prints what it found, and only "listening" or "closed" from an
# exec that ended with 0 is an answer (tests/docker-failure.sh).
out=$(docker compose -f "$COMPOSE_FILE" -p "$PROJECT" exec -T terraria-server bash -c '
  p=$(printf "%04X" "$1")
  [ -r /proc/net/tcp ] || exit 3
  grep -qE "^ *[0-9]+: [0-9A-F]+:$p [0-9A-F]+:[0-9A-F]+ 0A " /proc/net/tcp /proc/net/tcp6 2>/dev/null
  case $? in 0) echo listening ;; 1) echo closed ;; *) exit 3 ;; esac' _ "$PORT" 2>/dev/null) || exit 3
case "$out" in
  listening) rc=0 ;;
  closed) rc=1 ;;
  *) rc=3 ;;
esac
exit "$rc"
}
