#!/bin/bash
# The server's state, as one line of JSON, for a status page or a monitor.
#
#   {"status": "Online", "players": 0, "max": 8, "world": "Terraria"}
#   {"status": "Unknown", "players": null, "max": null, "world": null}   exit 1
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
printf '{"status": "Online", "players": %s, "max": %s, "world": "%s"}\n' "$players" "$max" "$world"
