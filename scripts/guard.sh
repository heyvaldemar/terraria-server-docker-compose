#!/bin/bash
# guard.sh - restart a server whose game port has stopped listening, while
# nobody is on, and clear the dead connections of an empty one before they
# get that far. Run it from systemd/terraria-guard.timer, every minute.
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
# on the game port was a scanner's. With TShock's own 8 slots and 20 reserved,
# 28 silent connections close the port; start.sh now gives the reserve every
# slot Terraria has left, so it takes 255, and tests/e2e-game.sh shows both.
# Killing the dead sockets in the kernel does not help, because the game's own
# bookkeeping holds the slots. A restart does, and the port is back in about
# five seconds.
#
# Docker does not restart an unhealthy container, and the health check here
# does go red when the port closes, so something has to act. These are its
# rules:
#
# - Listening, no dead connection on the game port: nothing to do.
# - Listening, with dead connections (CLOSE_WAIT: the other side has gone, the
#   game has not let go): housekeeping. A larger reserve only moves the day
#   the port closes, and that day may have players on, when nothing may be
#   done until they leave and nobody new can join. So a server that is empty,
#   up for TERRARIA_GUARD_HOUSEKEEP_AFTER seconds (12 hours) and holding at
#   least one dead connection is saved and restarted now, while nobody is
#   there to notice. Quietly, in the log only: it is housekeeping, not an
#   incident. An unreadable count of players, of dead connections or of
#   uptime means it does nothing, and so do players on.
# - Closed for less than TERRARIA_GUARD_AFTER seconds (120): wait. A restart
#   of the game closes the port for a few seconds on its own.
# - The player count cannot be read: do nothing and exit 1. Unknown is not
#   empty.
# - Players on: say so once and wait. They are playing; ending their game to
#   let a stranger in would be backwards.
# - TERRARIA_GUARD_MAX restarts (6) in the last 24 hours: stop acting and exit
#   1 on every run until that clears, so a different fault cannot hide in a
#   restart loop. Housekeeping counts against the same six and stops at them
#   too; since it waits for 12 hours up and a restart starts that clock again,
#   it can take at most two of them.
# - Otherwise save the world, restart, and prove the port is back.
#
# A CRASH DOCKER RESTARTS IS SAID ONCE. When TShock exits, start.sh exits with
# its status and Docker starts the container again; the health check goes
# green with the fresh one and nothing else says the server went down. Each
# run writes down the container's name, id and Docker's restart count
# (RestartCount). A count that grew is said once, through the webhook too,
# with the exit code and the reason from Docker's die and oom events (a
# restarted container's own state says exit 0 and not killed for memory
# again); 3 or more in 24 hours exit 1. The first run only writes the count
# down; a new container id, or a count that went down (`docker restart`, the
# guard's own restarts included, sets it to 0), starts afresh.
#
# TERRARIA_GUARD_WEBHOOK, when set, receives every action but housekeeping as
# {"text": ...}, which Mattermost and Slack incoming webhooks accept, and a
# housekeeping restart that does not bring the port back. A webhook that does
# not answer is reported and fails the run.
#
# State lives beside the repository in .terraria-guard* (TERRARIA_GUARD_STATE).
# tests/e2e-game.sh proves every decision against the real server, with its
# port closed by silent connections and with dead connections held while it
# still listens. One reading of each can be supplied instead of asked for;
# set but empty means "could not be read":
#   TERRARIA_PLAYERS           a count, in place of asking REST
#   TERRARIA_DEAD_CONNECTIONS  a count, in place of reading /proc/net/tcp
#   TERRARIA_UPTIME            seconds, in place of asking Docker
#
# READ WHOLE BEFORE IT RUNS. bash reads a script as it executes it and, after
# each command, reads on from the same byte offset in whatever the file holds
# by then. On the server this template comes from, the timer started this
# guard while the file was being edited in place: a syntax error, a failed
# unit, and the host's dead man's switch reporting the whole host down. The
# body is one brace group, which bash parses in full before the first line
# runs, and it ends in exit, so nothing past the closing brace is ever read.
# tests/read-whole.sh rewrites the file under a running copy both ways. (A git
# checkout, and so update.sh, writes a new file rather than this one, which a
# running copy never sees; an editor that saves in place does not.)
{
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
PORT="${TERRARIA_SERVER_PORT:-$(grep -E '^TERRARIA_SERVER_PORT=' .env 2>/dev/null | tail -1 | cut -d= -f2-)}"
PORT="${PORT:-7777}"
AFTER=${TERRARIA_GUARD_AFTER:-120}
HOUSEKEEP_AFTER=${TERRARIA_GUARD_HOUSEKEEP_AFTER:-43200}
MAX=${TERRARIA_GUARD_MAX:-6}
STATE=${TERRARIA_GUARD_STATE:-.terraria-guard}
WEBHOOK=${TERRARIA_GUARD_WEBHOOK:-}
compose() { docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }
say() { echo "$(date '+%F %T') $*"; }
tell() {  # message: to the log, and to the webhook when there is one
  say "$1"
  [ -n "$WEBHOOK" ] || return 0
  local text=${1//\\/\\\\} body url rc=0
  text=${text//\"/\\\"}
  # The webhook's address is its key, so curl reads it from stdin (--config
  # -) and it is on no command line, where every process on the host could
  # read it in ps; the message goes in a file of its own.
  url=${WEBHOOK//\\/\\\\}
  url=${url//\"/\\\"}
  body=$(mktemp) || return 1
  printf '{"text": "terraria: %s"}' "$text" >"$body"
  printf 'url = "%s"\n' "$url" \
    | curl -fsS -m 10 -o /dev/null -H 'Content-Type: application/json' --data-binary @"$body" --config - || rc=$?
  rm -f "$body"
  if [ "$rc" != 0 ]; then
    say "the webhook did not answer; the message above was not delivered" >&2
    return 1
  fi
}
count() {  # a reading that must be a whole number, or "?"
  case "$1" in ''|*[!0-9]*) echo "?" ;; *) echo "$1" ;; esac
}
players() {
  if [ -n "${TERRARIA_PLAYERS+x}" ]; then count "${TERRARIA_PLAYERS}"; return; fi
  count "$(scripts/rest.sh status 2>/dev/null | sed -nE 's/^ *"playercount": *([0-9]+),?$/\1/p' | head -1)"
}
dead() {  # connections on the game port in CLOSE_WAIT, inside the container
  if [ -n "${TERRARIA_DEAD_CONNECTIONS+x}" ]; then count "${TERRARIA_DEAD_CONNECTIONS}"; return; fi
  # shellcheck disable=SC2016  # expanded by the container's bash, not this one
  count "$(compose exec -T terraria-server bash -c '
    p=$(printf "%04X" "$1")
    [ -r /proc/net/tcp ] || exit 3
    cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk -v p=":$p" "\$2 ~ p\"\$\" && \$4 == \"08\"" | grep -c .' _ "$PORT" 2>/dev/null)"
}
uptime_s() {  # seconds since the container started
  if [ -n "${TERRARIA_UPTIME+x}" ]; then count "${TERRARIA_UPTIME}"; return; fi
  local started t
  started="$(docker inspect -f '{{.State.StartedAt}}' "$(compose ps -q terraria-server 2>/dev/null | head -1)" 2>/dev/null)"
  t="$(date -d "$started" +%s 2>/dev/null || TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "${started%%.*}" +%s 2>/dev/null)"
  case "$t" in ''|*[!0-9]*) echo "?" ;; *) count "$(( now - t ))" ;; esac
}
recent() {  # restarts in the last 24 hours, one stamp per line
  if [ -s "$STATE.restarts" ]; then
    awk -v since=$(( now - 86400 )) '$1 >= since' "$STATE.restarts" | grep -c .
  else
    echo 0
  fi
}
# Save, restart, stamp, and wait for the port. Prints how long it took to
# listen again and returns 0; returns 2 when the restart itself failed, 1 when
# the port stayed closed for three minutes after it.
restart() {
  local start
  scripts/admin.sh save >/dev/null 2>&1 || say "the save before the restart did not answer; the stop saves the world anyway (start.sh)" >&2
  start=$(date +%s)
  compose restart terraria-server >/dev/null 2>&1 || return 2
  # One stamp per restart, the day's only: older ones are dropped as this adds.
  { awk -v since=$(( start - 86400 )) '$1 >= since' "$STATE.restarts" 2>/dev/null; echo "$start"; } >"$STATE.restarts.new" && mv -f "$STATE.restarts.new" "$STATE.restarts"
  for _ in $(seq 1 180); do
    if scripts/listening.sh; then
      echo "$(( $(date +%s) - start ))"
      return 0
    fi
    sleep 1
  done
  return 1
}
now=$(date +%s)

# ------------------------------------------------------------- Docker's restarts
rcid="$(compose ps -q --status running terraria-server 2>/dev/null | head -1)"
if [ -n "$rcid" ]; then
  for f in "$STATE.docker" "$STATE.crashes"; do
    [ -L "$f" ] && { say "$f is a symlink; refusing to use it"; exit 1; }
  done
  if ! info=$(docker inspect "$rcid" --format '{{.Name}} {{.Id}} {{.RestartCount}} {{.State.FinishedAt}} {{.State.StartedAt}}' 2>/dev/null) || [ -z "$info" ]; then
    say "cannot read the restart count of terraria-server; nothing written"
    exit 1
  fi
  read -r rname rid rcount rfin rstart <<<"$info"
  case ${rcount:-} in ''|*[!0-9]*) say "cannot read the restart count of terraria-server ($rcount); nothing written"; exit 1 ;; esac
  bname=""; bid=""; bcount=""; bsince=""
  read -r bname bid bcount bsince 2>/dev/null <"$STATE.docker" || true
  case ${bcount:-} in ''|*[!0-9]*) bcount="" ;; esac
  case ${bsince:-} in ''|*[!0-9]*) bsince=$now ;; esac
  if [ "$bname" = "$rname" ] && [ "$bid" = "$rid" ] && [ -n "$bcount" ] && [ "$rcount" -gt "$bcount" ]; then
    more=$(( rcount - bcount ))
    # From a minute before the last run to two seconds from now: an "until"
    # of this very second missed a die of this very second (measured).
    ev=$(docker events --since $(( bsince - 60 )) --until $(( $(date +%s) + 2 )) --filter "container=$rid" --filter event=die --filter event=oom \
      --format '{{.Action}} {{index .Actor.Attributes "exitCode"}}' 2>/dev/null)
    rexit=$(awk '$1 == "die" { c = $2 } END { print c }' <<<"$ev")
    # A KILL FOR MEMORY CAN BE STORED LATE. On a GitHub runner (Docker 29.4.2)
    # the oom event of 1 kill in 20 was not there when the die was, and was
    # 10 seconds later. A 137 with no oom event yet is read again, for up to
    # ten seconds, before it is called a plain SIGKILL.
    if [ "$rexit" = 137 ] && ! grep -q '^oom' <<<"$ev"; then
      for _ in 1 2 3 4 5; do
        sleep 2
        ev=$(docker events --since $(( bsince - 60 )) --until $(( $(date +%s) + 2 )) --filter "container=$rid" --filter event=die --filter event=oom \
          --format '{{.Action}} {{index .Actor.Attributes "exitCode"}}' 2>/dev/null)
        grep -q '^oom' <<<"$ev" && break
      done
    fi
    case "$rexit" in
      134) rexit="134 (SIGABRT)" ;; 137) rexit="137 (SIGKILL)" ;; 139) rexit="139 (SIGSEGV)" ;; 143) rexit="143 (SIGTERM)" ;;
    esac
    why=""
    if grep -q '^oom' <<<"$ev"; then
      why="killed for memory (oom event, exit ${rexit:-?})"
    else
      # start.sh's own last word before Docker started it again, or the
      # crash line; anything 24 characters or longer masked.
      why=$(docker logs --until "$rstart" --tail 400 "$rid" 2>&1 | grep -a -i -E 'fatal|segmentation|core dumped|panic|abort|unhandled exception|start.sh: (TShock exited|the memory limit)' | tail -1 \
        | sed -E 's/[A-Za-z0-9+\/=_-]{24,}/<masked>/g' | tr -d '\r' | cut -c1-200)
      [ -n "$why" ] && why="its log before that: $why"
    fi
    before=0
    [ -f "$STATE.crashes" ] && before=$(awk -v t=$(( now - 86400 )) '$1 > t { n += $2 } END { print n + 0 }' "$STATE.crashes")
    crashes=$(( before + more ))
    if ! $DRY; then
      echo "$now $more" >>"$STATE.crashes"
      echo "$rname $rid $rcount $now" >"$STATE.docker"
    fi
    tell "the server restarted $more time$( [ "$more" = 1 ] || echo s) since $(date -d "@$bsince" '+%F %T' 2>/dev/null || echo "$bsince"), last exit code ${rexit:-?}, last finished ${rfin:-?}${why:+; $why} ($crashes in 24 h). Docker brought it back, so its health check is green again. docker compose -p $PROJECT logs --since 2h terraria-server" || true
    [ "$crashes" -ge 3 ] && exit 1
  elif [ "$bname" != "$rname" ] || [ "$bid" != "$rid" ] || [ -z "$bcount" ] || [ "$rcount" -lt "$bcount" ]; then
    $DRY || echo "$rname $rid $rcount $now" >"$STATE.docker"
  fi
fi

scripts/listening.sh
listening=$?
case $listening in
  0) rm -f "$STATE" "$STATE.warned" ;;
  1) ;;
  *) say "the server is not running, or its port cannot be read: nothing for the guard to do"; exit 0 ;;
esac

if [ "$listening" = 0 ]; then
  # Listening: housekeeping, or nothing.
  d="$(dead)"
  if [ "$d" = 0 ]; then say "listening: nothing to do"; exit 0; fi
  if [ "$d" = "?" ]; then say "listening; the dead connections on the game port cannot be counted, so nothing to clear"; exit 0; fi
  up="$(uptime_s)"
  if [ "$up" = "?" ]; then say "listening, $d dead connection(s); how long the server has been up cannot be read, so not clearing on a guess"; exit 0; fi
  if [ "$up" -lt "$HOUSEKEEP_AFTER" ]; then
    say "listening, $d dead connection(s) holding slots; up $(( up / 3600 )) h, cleared once up $(( HOUSEKEEP_AFTER / 3600 )) h with nobody on"
    exit 0
  fi
  n="$(players)"
  if [ "$n" = "?" ]; then say "listening, $d dead connection(s), up $(( up / 3600 )) h; the player count cannot be read, so not clearing on a guess"; exit 0; fi
  if [ "$n" -gt 0 ]; then say "listening, $d dead connection(s), up $(( up / 3600 )) h; $n player(s) on, so not clearing them now"; exit 0; fi
  r="$(recent)"
  if [ "$r" -ge "$MAX" ]; then say "listening, $d dead connection(s), up $(( up / 3600 )) h, nobody on; $r restarts in 24 hours already, so not clearing them now"; exit 0; fi
  if $DRY; then say "would restart to clear $d dead connection(s): up $(( up / 3600 )) h, nobody on"; exit 0; fi
  took="$(restart)"
  case $? in
    0) say "housekeeping: empty, up $(( up / 3600 )) h, $d dead connection(s) on the game port; restarted to clear them, listening again after ${took}s (restart $(( r + 1 )) of $MAX allowed in 24 hours)"; exit 0 ;;
    2) tell "FAILED to restart, for housekeeping (empty, $d dead connection(s)): docker compose -p $PROJECT logs --tail 200 terraria-server" >&2; exit 1 ;;
    *) tell "FAILED: a housekeeping restart, to clear $d dead connection(s) from an empty server, and the game port is not listening three minutes later. docker compose -p $PROJECT logs --tail 200 terraria-server" >&2; exit 1 ;;
  esac
fi

# Closed.
[ -s "$STATE" ] || echo "$now" >"$STATE"
closed=$(( now - $(cat "$STATE") ))
if [ "$closed" -lt "$AFTER" ]; then say "the game port is closed (${closed}s); acting after ${AFTER}s"; exit 0; fi

n="$(players)"
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

r="$(recent)"
if [ "$r" -ge "$MAX" ]; then
  tell "the game port is closed again and there have been $r restarts in 24 hours; not restarting any more, something other than silent connections is wrong. docker compose -p $PROJECT logs --tail 200 terraria-server" >&2
  exit 1
fi

if $DRY; then say "would restart: the game port has been closed for $(( closed / 60 )) min and nobody is on"; exit 0; fi
took="$(restart)"
case $? in
  0) rm -f "$STATE" "$STATE.warned"
     tell "the game port had been closed for $(( closed / 60 )) min with nobody on; restarted, and it listens again after ${took}s (restart $(( r + 1 )) of $MAX allowed in 24 hours)" || exit 1
     exit 0 ;;
  2) tell "FAILED to restart: docker compose -p $PROJECT logs --tail 200 terraria-server" >&2 ;;
  *) tell "FAILED: restarted, and the game port is still closed three minutes later. docker compose -p $PROJECT logs --tail 200 terraria-server" >&2 ;;
esac
exit 1
}
