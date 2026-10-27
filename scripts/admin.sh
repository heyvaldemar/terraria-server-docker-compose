#!/bin/bash
# Moderation and the console, through TShock's REST API.
#
#   scripts/admin.sh who                       who is on
#   scripts/admin.sh kick <name> [reason]
#   scripts/admin.sh ban <name> [minutes] [reason]   0 or no minutes: permanent
#   scripts/admin.sh unban <name>
#   scripts/admin.sh bans                      every ban, with its end in UTC
#   scripts/admin.sh say <message>             to everyone on the server
#   scripts/admin.sh save                      write the world to disk now,
#                                              and wait until it is written
#
# Bans are by character name (name:<name>), so they hold for somebody who has
# already left. Three things about TShock 6.2.1's REST API this works around,
# each measured against it:
#
# A BAN IS JUDGED BY THE BAN LIST, NEVER BY THE STATUS CODE. /v3/bans/create
# writes the ban and then answers 500 "Object reference not set to an
# instance of an object": its next step, kicking matching players who are
# online, trips over the empty player slots. Read as a failure, every ban
# would be reported as failed and retried into duplicates; read as success
# without looking, a ban that really failed would say "banned". So the ban is
# looked up in /v3/bans/list afterwards, its end checked against the one
# asked for, and a player who is on is kicked separately.
#
# THE END IS UTC WITHOUT A ZONE SUFFIX. TShock takes a ban's start as
# DateTime.UtcNow and parses its end with DateTime.TryParse, which converts a
# trailing Z to the server's local time. On a server not on UTC a timed ban
# then ends hours off: on the machine this template comes from, a 60-minute
# ban came out already over. A bare UTC stamp is read on
# the same clock as the start. tests/e2e-game.sh runs the server on
# Asia/Tokyo and measures a 60-minute ban both ways.
#
# AN UNBAN TAKES A TICKET NUMBER, not a name, so it is looked up first, and
# the name is checked gone afterwards.
#
# A /ban run as a console command through REST fails with the same
# NullReferenceException (it wants a player to run as), which is why the ban
# goes through /v3/bans/create at all.
#
# Read whole before it runs: one brace group, ending in exit (scripts/guard.sh,
# "READ WHOLE BEFORE IT RUNS", says why).
{
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

usage() { sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 1 ] || usage
cmd=$1; shift

COMPOSE_FILE=${TERRARIA_COMPOSE_FILE:-terraria-server-docker-compose.yml}
PROJECT=${COMPOSE_PROJECT_NAME:-terraria}
rest() { scripts/rest.sh "$@"; }
# The world file TShock was started with, its modification time and size,
# read from the running process's own command line.
world_stamp() {
  docker compose -f "$COMPOSE_FILE" -p "$PROJECT" exec -T terraria-server bash -c '
    for p in /proc/[0-9]*; do
      [ "$(cat "$p/comm" 2>/dev/null)" = TShock.Server ] || continue
      w="$(tr "\0" "\n" <"$p/cmdline" | grep -A1 -x -- -world | tail -1)"
      [ -n "$w" ] && stat -c "%n %y %s" "$w"
      break
    done' 2>/dev/null
}
jstr() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }
error_of() { sed -nE 's/^ *"error": *"((\\.|[^"\\])*)",?$/\1/p' | head -1; }
# .NET ticks (100 ns since 0001-01-01 UTC) to seconds since 1970.
ticks_to_epoch() { echo $(( ($1 - 621355968000000000) / 10000000 )); }
utc() { date -u -d "@$1" '+%F %H:%M' 2>/dev/null || date -u -r "$1" '+%F %H:%M'; }
# "ticket end_ticks identifier" for every ban, one per line.
bans_list() {
  rest v3/bans/list | awk '
    /"ticket_number":/ { t = $2; sub(/,$/, "", t) }
    /"identifier":/    { i = $0; sub(/^ *"identifier": *"/, "", i); sub(/",?$/, "", i) }
    /"end_date_ticks":/ { e = $2; sub(/,$/, "", e); print t, e, i }'
}
tickets_of() {  # name
  local want; want="name:$(jstr "$1")"
  bans_list | while read -r t _ i; do [ "$i" = "$want" ] && echo "$t"; done
}

case "$cmd" in
  who)
    body="$(rest v2/players/list)" || { echo "who FAILED: $(error_of <<<"$body")" >&2; exit 1; }
    names="$(sed -nE 's/^ *"nickname": *"((\\.|[^"\\])*)",?$/\1/p' <<<"$body")"
    if [ -n "$names" ]; then echo "$names"; else echo "nobody is on the server"; fi
    ;;
  kick)
    [ $# -ge 1 ] || usage
    body="$(rest v2/players/kick player="$1" reason="${2:-Kicked by an admin}")" \
      || { echo "kick FAILED: $(error_of <<<"$body")" >&2; exit 1; }
    echo "kicked: $1"
    ;;
  ban)
    [ $# -ge 1 ] || usage
    name=$1 minutes=${2:-0} reason=${3:-Banned by an admin}
    case "$minutes" in ''|*[!0-9]*) echo "minutes must be a whole number, 0 for permanent" >&2; exit 2 ;; esac
    args=(identifier="name:$name" reason="$reason")
    if [ "$minutes" -gt 0 ]; then
      end=$(( $(date -u +%s) + minutes * 60 ))
      args+=(end="$(date -u -d "@$end" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -r "$end" +%Y-%m-%dT%H:%M:%S)")
    fi
    rest v3/bans/create "${args[@]}" >/dev/null 2>&1
    want="name:$(jstr "$name")"
    line="$(bans_list | while read -r t e i; do [ "$i" = "$want" ] && echo "$t $e"; done | tail -1)"
    [ -n "$line" ] || { echo "ban FAILED: no ban for name:$name in TShock's list" >&2; exit 1; }
    read -r _ e <<<"$line"
    if [ "$minutes" -gt 0 ]; then
      got=$(ticks_to_epoch "$e")
      off=$(( got - end )); off=${off#-}
      if [ "$off" -gt 120 ]; then
        echo "ban FAILED its check: name:$name is listed until $(utc "$got") UTC, and $minutes min from now is $(utc "$end") UTC" >&2
        exit 1
      fi
    fi
    rest v2/players/kick player="$name" reason="$reason" >/dev/null 2>&1
    if [ "$minutes" -gt 0 ]; then echo "banned: name:$name for $minutes min, until $(utc "$end") UTC"; else echo "banned: name:$name, permanently"; fi
    ;;
  unban)
    [ $# -ge 1 ] || usage
    t="$(tickets_of "$1")"
    [ -n "$t" ] || { echo "not banned: name:$1"; exit 1; }
    for n in $t; do rest v3/bans/destroy ticketNumber="$n" fullDelete=true >/dev/null 2>&1; done
    [ -z "$(tickets_of "$1")" ] || { echo "unban FAILED: name:$1 is still listed" >&2; exit 1; }
    echo "unbanned: name:$1"
    ;;
  bans)
    out="$(bans_list)" || { echo "could not read the ban list" >&2; exit 1; }
    [ -n "$out" ] || { echo "nobody is banned"; exit 0; }
    # A permanent ban ends at DateTime.MaxValue.
    while read -r t e i; do
      i=${i//\\\"/\"}; i=${i//\\\\/\\}
      if [ "$e" -ge 3155378975990000000 ] 2>/dev/null; then echo "#$t $i permanent"; else echo "#$t $i until $(utc "$(ticks_to_epoch "$e")") UTC"; fi
    done <<<"$out"
    ;;
  say)
    [ $# -ge 1 ] || usage
    body="$(rest v2/server/broadcast msg="$*")" || { echo "say FAILED: $(error_of <<<"$body")" >&2; exit 1; }
    echo "said: $*"
    ;;
  save)
    # THE SAVE RUNS AFTER THE ANSWER. TShock answers 200 when it has queued
    # the save on the game's thread; the file is written a moment later. A
    # backup that archived on the answer could take the world mid-write, so
    # this waits until the world file has changed and then stopped changing.
    before="$(world_stamp)"
    [ -n "$before" ] || { echo "save FAILED: cannot find the world file TShock was started with" >&2; exit 1; }
    body="$(rest v3/server/rawcmd cmd=/save)" || { echo "save FAILED: $(error_of <<<"$body")" >&2; exit 1; }
    for _ in $(seq 1 60); do
      sleep 1
      now="$(world_stamp)"
      [ -n "$now" ] && [ "$now" != "$before" ] || continue
      sleep 1
      [ "$(world_stamp)" = "$now" ] && { echo "saved: ${now%% *} written"; exit 0; }
    done
    echo "save FAILED: TShock accepted it, and the world file was not rewritten within a minute" >&2
    exit 1
    ;;
  *)
    usage
    ;;
esac
exit
}
