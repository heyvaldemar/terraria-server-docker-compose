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
set -uo pipefail
cd "$(dirname "$0")/.." || exit 3

PORT="${TERRARIA_SERVER_PORT:-$(grep -E '^TERRARIA_SERVER_PORT=' .env 2>/dev/null | tail -1 | cut -d= -f2-)}"
PORT="${PORT:-7777}"
COMPOSE_FILE=${TERRARIA_COMPOSE_FILE:-terraria-server-docker-compose.yml}
PROJECT=${COMPOSE_PROJECT_NAME:-terraria}

# A container that is not running is "cannot ask", not "not listening":
# docker compose exec fails with 1 either way.
[ -n "$(docker compose -f "$COMPOSE_FILE" -p "$PROJECT" ps -q --status running terraria-server 2>/dev/null)" ] || exit 3
docker compose -f "$COMPOSE_FILE" -p "$PROJECT" exec -T terraria-server bash -c '
  p=$(printf "%04X" "$1")
  [ -r /proc/net/tcp ] || exit 3
  grep -qE "^ *[0-9]+: [0-9A-F]+:$p [0-9A-F]+:[0-9A-F]+ 0A " /proc/net/tcp /proc/net/tcp6 2>/dev/null' _ "$PORT" 2>/dev/null
rc=$?
case "$rc" in 0|1) exit "$rc" ;; *) exit 3 ;; esac
