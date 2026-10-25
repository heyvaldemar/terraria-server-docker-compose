#!/bin/bash
# guard.sh - restart a server whose game port has stopped listening, while
# nobody is on. Run it from systemd/terraria-guard.timer, every minute.
#
#   scripts/guard.sh            act if the rules say so
#   scripts/guard.sh --dry-run  go as far as deciding, never restart
#
# WHY A SERVER STOPS LISTENING. Terraria gives every accepted TCP connection a
# client slot and stops listening when none is free, and a connection that
# never speaks the game's protocol is never released. TShock's maintainers
# wrote in 2016 that any open socket is treated as a player and moved the
# issue to the API layer (Pryaxis/TShock#1023), where it still is. Internet
# scanners connect and go quiet. On the server this template comes from, the
# owner could not join while the process ran, the health check of the time
# was green, REST answered and the status page said Online; every connection
# on the game port was a scanner's. Here, 28 silent connections (TShock's 8
# slots and its 20 reserved) close the port, and tests/e2e-game.sh does exactly
# that. Killing the dead sockets in the kernel does not help, because the
# game's own bookkeeping holds the slots. A restart does, and the port is back
# in about five seconds.
#
# Docker does not restart an unhealthy container, and the health check here
# does go red when the port closes, so something has to act. These are its
# rules:
#
# - Listening: nothing to do.
# - Closed for less than TERRARIA_GUARD_AFTER seconds (120): wait. A restart
#   of the game closes the port for a few seconds on its own.
# - The player count cannot be read: do nothing and exit 1. Unknown is not
#   empty.
# - Players on: say so once and wait. They are playing; ending their game to
#   let a stranger in would be backwards.
# - TERRARIA_GUARD_MAX restarts (6) in the last 24 hours: stop acting and exit
#   1 on every run until that clears, so a different fault cannot hide in a
#   restart loop.
# - Otherwise save the world, restart, and prove the port is back.
#
# TERRARIA_GUARD_WEBHOOK, when set, receives every action as {"text": ...},
# which Mattermost and Slack incoming webhooks accept. A webhook that does not
# answer is reported and fails the run.
#
# State lives beside the repository in .terraria-guard* (TERRARIA_GUARD_STATE).
# tests/e2e-game.sh proves the decisions against the real server with its port
# closed by silent connections. One reading can be supplied instead of asked
# for:
#   TERRARIA_PLAYERS   a count, in place of asking REST; set but empty means
#                      "could not be read"
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

DRY=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=true ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

COMPOSE_FILE=${TERRARIA_COMPOSE_FILE:-terraria-server-docker-compose.yml}
PROJECT=${COMPOSE_PROJECT_NAME:-terraria}
AFTER=${TERRARIA_GUARD_AFTER:-120}
MAX=${TERRARIA_GUARD_MAX:-6}
STATE=${TERRARIA_GUARD_STATE:-.terraria-guard}
WEBHOOK=${TERRARIA_GUARD_WEBHOOK:-}
compose() { docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }
say() { echo "$(date '+%F %T') $*"; }
tell() {  # message: to the log, and to the webhook when there is one
  say "$1"
  [ -n "$WEBHOOK" ] || return 0
  local text=${1//\\/\\\\}
  text=${text//\"/\\\"}
  if ! printf '{"text": "terraria: %s"}' "$text" \
       | curl -fsS -m 10 -o /dev/null -H 'Content-Type: application/json' --data-binary @- "$WEBHOOK"; then
    say "the webhook did not answer; the message above was not delivered" >&2
    return 1
  fi
}
players() {
  if [ -n "${TERRARIA_PLAYERS+x}" ]; then echo "${TERRARIA_PLAYERS:-?}"; return; fi
  local n
  n="$(scripts/rest.sh status 2>/dev/null | sed -nE 's/^ *"playercount": *([0-9]+),?$/\1/p' | head -1)"
  echo "${n:-?}"
}
now=$(date +%s)

scripts/listening.sh
case $? in
  0) rm -f "$STATE" "$STATE.warned"; say "listening: nothing to do"; exit 0 ;;
  1) ;;
  *) say "the server is not running, or its port cannot be read: nothing for the guard to do"; exit 0 ;;
esac

[ -s "$STATE" ] || echo "$now" >"$STATE"
closed=$(( now - $(cat "$STATE") ))
if [ "$closed" -lt "$AFTER" ]; then say "the game port is closed (${closed}s); acting after ${AFTER}s"; exit 0; fi

n="$(players)"
case "$n" in ''|*[!0-9]*) n="?" ;; esac
if [ "$n" = "?" ]; then
  say "the game port has been closed for ${closed}s, and the player count cannot be read; not acting on a guess" >&2
  exit 1
fi
if [ "$n" -gt 0 ]; then
  if [ ! -e "$STATE.warned" ]; then
    tell "the game port has been closed for $(( closed / 60 )) min, so nobody new can join; $n player(s) are on and unaffected, so no restart until they leave" || exit 1
    $DRY || touch "$STATE.warned"
  else
    say "still closed, $n player(s) on: waiting for an empty server"
  fi
  exit 0
fi

# Restarts in the last 24 hours, one stamp per line.
recent=0
if [ -s "$STATE.restarts" ]; then
  recent="$(awk -v since=$(( now - 86400 )) '$1 >= since' "$STATE.restarts" | grep -c .)"
fi
if [ "$recent" -ge "$MAX" ]; then
  tell "the game port is closed again and there have been $recent restarts in 24 hours; not restarting any more, something other than silent connections is wrong. docker compose -p $PROJECT logs --tail 200 terraria-server" >&2
  exit 1
fi

if $DRY; then say "would restart: the game port has been closed for $(( closed / 60 )) min and nobody is on"; exit 0; fi
scripts/admin.sh save >/dev/null 2>&1 || say "the save before the restart did not answer; the stop saves the world anyway (start.sh)"
start=$(date +%s)
compose restart terraria-server >/dev/null 2>&1 || { tell "FAILED to restart: docker compose -p $PROJECT logs --tail 200 terraria-server" >&2; exit 1; }
# One stamp per restart, the day's only: older ones are dropped as this adds.
{ awk -v since=$(( start - 86400 )) '$1 >= since' "$STATE.restarts" 2>/dev/null; echo "$start"; } >"$STATE.restarts.new" && mv -f "$STATE.restarts.new" "$STATE.restarts"
for _ in $(seq 1 180); do
  if scripts/listening.sh; then
    rm -f "$STATE" "$STATE.warned"
    tell "the game port had been closed for $(( closed / 60 )) min with nobody on; restarted, and it listens again after $(( $(date +%s) - start ))s (restart $(( recent + 1 )) of $MAX allowed in 24 hours)" || exit 1
    exit 0
  fi
  sleep 1
done
tell "FAILED: restarted, and the game port is still closed three minutes later. docker compose -p $PROJECT logs --tail 200 terraria-server" >&2
exit 1
