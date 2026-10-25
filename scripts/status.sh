#!/bin/bash
# The server's state, as one line of JSON, for a status page or a monitor.
#
#   {"status": "Online", "players": 0, "max": 8, "world": "Terraria"}
#   {"status": "Not accepting players", "players": 0, ...}               exit 1
#   {"status": "Unknown", "players": null, "max": null, "world": null}   exit 1
#
# ONLINE MEANS A PLAYER CAN GET IN. The REST API runs on its own thread and
# answers while the game port is closed: when silent connections have taken
# every slot (scripts/guard.sh), the process runs, REST says 200 and nobody
# can join. A status read from REST alone said "Online" through that whole
# outage, on the server this template comes from and in tests/e2e-game.sh.
# So Online needs the game port in LISTEN too (scripts/listening.sh); a
# server that answers and does not listen is "Not accepting players".
#
# AN UNKNOWN PLAYER COUNT IS NOT ZERO. When TShock does not answer, this says
# Unknown and exits 1; it never prints "Online" with 0. Terraria answers no
# Steam query, so its REST /status is the only place the count comes from,
# and a monitor that read silence as an empty server would report a server
# that is down as one nobody is playing on.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

unknown() { echo '{"status": "Unknown", "players": null, "max": null, "world": null}'; exit 1; }

body="$(scripts/rest.sh status 2>/dev/null)" || unknown
players="$(sed -nE 's/^ *"playercount": *([0-9]+),?$/\1/p' <<<"$body" | head -1)"
max="$(sed -nE 's/^ *"maxplayers": *([0-9]+),?$/\1/p' <<<"$body" | head -1)"
# The world name as TShock escaped it, so it goes out as valid JSON.
world="$(sed -nE 's/^ *"world": *"((\\.|[^"\\])*)",?$/\1/p' <<<"$body" | head -1)"
[ -n "$players" ] && [ -n "$max" ] || unknown
scripts/listening.sh
case $? in
  0) state="Online" ;;
  1) state="Not accepting players" ;;
  *) unknown ;;
esac
printf '{"status": "%s", "players": %s, "max": %s, "world": "%s"}\n' "$state" "$players" "$max" "$world"
[ "$state" = Online ]
