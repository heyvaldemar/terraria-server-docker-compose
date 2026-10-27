#!/bin/bash
# The container's entrypoint: the settings .env owns into config.json, then
# TShock, then a way out that saves the world.
#
# REST ON, WITH A TOKEN MADE HERE. Status, moderation and the save before a
# backup all go through TShock's REST API, which is off by default and needs
# a token. On the first start there is no config.json: this writes the few
# keys it needs, and TShock fills in every other key and writes the whole
# file back (that is what it does with a partial config). On every later
# start it edits the lines TShock wrote, in the shape TShock writes them. The
# token is 48 hex characters from /dev/urandom, made in here, kept in
# config.json (mode 600) and read in here by scripts/rest.sh: it is never in
# .env, an environment variable, a command line or a log.
#
# .ENV OWNS THE SLOTS. TShock 6.2.1 sizes the server's network slots from
# config.json when it reads the file: Main.maxNetPlayers = MaxSlots +
# ReservedSlots, with MaxSlots cut to 255 - ReservedSlots (Terraria has 255).
# A -maxplayers flag changes MaxSlots in memory and nothing else, and /reload
# reads the file again. On the server this template comes from, started with
# -maxplayers 16 over TShock's own 8 and 20, the game had 28 network slots,
# and a /reload would have put the player cap back to 8; tests/e2e-game.sh
# shows a /reload taking the cap from the file. So both numbers are written
# here on every start, and the compose file passes no -maxplayers at all:
# MaxSlots is TERRARIA_MAX_PLAYERS (8), the cap a player meets, and
# ReservedSlots is TERRARIA_RESERVED_SLOTS, by default every slot left,
# 255 - TERRARIA_MAX_PLAYERS. A reserved slot takes a player only with
# TShock's tshock.reservedslot permission; its use here is headroom. A
# connection that never speaks the game's protocol holds a slot until a
# restart, and with no slot free the game stops listening (scripts/guard.sh).
# At 8 + 20 that took 28 such connections; at 8 + 247 it takes 255. A value
# outside 1-255, or a reserve past 255 in total, stops the start here with
# its name, since TShock would cut it without a word.
#
# .ENV OWNS THE SERVER PASSWORD. It is written into ServerPassword on every
# start, so a password changed in .env is the password after the next start,
# and an empty one opens the server again. It goes into the file, not onto
# TShock's command line, where any user on the host could read it with ps.
#
# THE WAY OUT. TShock does not save on SIGTERM. Run with the image's own
# entrypoint, `docker compose stop` ended it in under a second, exit 143, and
# the world on disk was the last autosave. Here TShock reads its console from
# a pipe this script holds open, and SIGTERM or SIGINT becomes `off`, TShock's
# command that saves the world and shuts down. tests/e2e-game.sh shows the
# world file rewritten and exit 0 with this, and exit 143 and the old file
# without it.
#
# Read whole before it runs: one brace group, ending in exit (scripts/guard.sh,
# "READ WHOLE BEFORE IT RUNS", says why).
{
set -uo pipefail

CFG=/tshock/config.json
ME=terraria-server-docker-compose
umask 077

token() { od -An -N24 -tx1 /dev/urandom | tr -d ' \n'; }
entry() {  # the token entry TShock reads, at the indentation it writes
  printf '      "%s": {\n        "Username": "%s",\n        "UserGroupName": "superadmin"\n      }%s\n' "$(token)" "$ME" "$1"
}

slots=${TERRARIA_MAX_PLAYERS:-8}
case $slots in ''|*[!0-9]*|????*) slots=x ;; esac
if [ "$slots" = x ] || [ "$slots" -lt 1 ] || [ "$slots" -gt 255 ]; then
  echo "start.sh: TERRARIA_MAX_PLAYERS=${TERRARIA_MAX_PLAYERS:-} is not a number from 1 to 255" >&2
  exit 2
fi
slots=$(( 10#$slots ))   # 08 is eight, not a bad octal number
reserved=${TERRARIA_RESERVED_SLOTS:-$(( 255 - slots ))}
case $reserved in ''|*[!0-9]*|????*) reserved=x ;; esac
[ "$reserved" = x ] || reserved=$(( 10#$reserved ))
if [ "$reserved" = x ] || [ $(( slots + reserved )) -gt 255 ]; then
  echo "start.sh: TERRARIA_RESERVED_SLOTS=${TERRARIA_RESERVED_SLOTS:-} with TERRARIA_MAX_PLAYERS=$slots: the two together must be 255 or fewer, the slots Terraria has" >&2
  exit 2
fi

pw=${TERRARIA_SERVER_PASSWORD:-}
pw=${pw//\\/\\\\}
pw=${pw//\"/\\\"}

if [ ! -s "$CFG" ]; then
  {
    printf '{\n  "Settings": {\n    "ServerPassword": "%s",\n    "MaxSlots": %s,\n    "ReservedSlots": %s,\n    "RestApiEnabled": true,\n    "RestApiPort": 7878,\n    "ApplicationRestTokens": {\n' "$pw" "$slots" "$reserved"
    entry ""
    printf '    }\n  }\n}\n'
  } >"$CFG"
  echo "start.sh: first start; REST on, with a token made in this container"
else
  ours=false
  grep -q "\"Username\": \"$ME\"" "$CFG" && ours=true
  rest=false tokens=false max=false res=false
  tmp="$CFG.start.$$"
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      '    "ServerPassword": '*)
        printf '    "ServerPassword": "%s",\n' "$pw" ;;
      '    "MaxSlots": '*)
        printf '    "MaxSlots": %s%s\n' "$slots" "${line##*[0-9]}"; max=true ;;
      '    "ReservedSlots": '*)
        printf '    "ReservedSlots": %s%s\n' "$reserved" "${line##*[0-9]}"; res=true ;;
      '    "RestApiEnabled": '*)
        printf '    "RestApiEnabled": true,\n'; rest=true ;;
      '    "ApplicationRestTokens": {}'*)
        printf '    "ApplicationRestTokens": {\n'; entry ""; printf '    }%s\n' "${line#*\}}"; tokens=true ;;
      '    "ApplicationRestTokens": {')
        printf '%s\n' "$line"; $ours || entry ","; tokens=true ;;
      *)
        printf '%s\n' "$line" ;;
    esac
  done <"$CFG" >"$tmp"
  mv -f "$tmp" "$CFG"
  if ! $rest || ! $tokens; then
    echo "start.sh: WARNING: config.json is not in the shape TShock writes (RestApiEnabled found: $rest, ApplicationRestTokens found: $tokens)." >&2
    echo "start.sh: the server starts, but status, moderation and the save before a backup need REST and will say so." >&2
  fi
  if ! $max || ! $res; then
    echo "start.sh: WARNING: config.json has no MaxSlots or ReservedSlots line in the shape TShock writes (MaxSlots found: $max, ReservedSlots found: $res); TShock uses its own 8 and 20 for what is missing." >&2
  fi
fi
echo "start.sh: $slots player slots and $reserved reserved, $(( slots + reserved )) of Terraria's 255"
chmod 600 "$CFG"

CONSOLE=/tmp/console
rm -f "$CONSOLE"
mkfifo -m 600 "$CONSOLE"
# Read and write, so the pipe never reaches end-of-file while TShock reads it.
exec 3<>"$CONSOLE"
cd /server || exit 1
# The image's own entrypoint, flag for flag; tests/e2e-game.sh compares them.
./TShock.Server -configpath /tshock -logpath /tshock/logs -crashdir /tshock/crashes -worldselectpath /worlds -additionalplugins /plugins "$@" <&3 &
game=$!
# shellcheck disable=SC2329  # called from the traps below
stop() {
  echo "start.sh: $1; asking TShock to save the world and shut down"
  printf 'off\n' >&3
}
trap 'stop SIGTERM' TERM
trap 'stop SIGINT' INT
# wait returns early when a trapped signal arrives; keep waiting for TShock.
while :; do
  wait "$game"
  rc=$?
  kill -0 "$game" 2>/dev/null || break
done
echo "start.sh: TShock exited $rc"
# KILLED, AND BY WHAT. Exit 137 is SIGKILL. When this container's memory limit
# did it, its cgroup counts the kill, and that is said here, so a limit set too
# low names itself in the log instead of leaving a restart nobody explains.
oom="$(sed -n 's/^oom_kill //p' /sys/fs/cgroup/memory.events 2>/dev/null)"
if [ "$rc" = 137 ] && [ "${oom:-0}" -gt 0 ]; then
  echo "start.sh: the memory limit killed TShock (oom_kill $oom in this container's cgroup). A world's first generation needs the most; raise TERRARIA_SERVER_MEMORY_LIMIT in .env." >&2
fi
exit "$rc"
}
