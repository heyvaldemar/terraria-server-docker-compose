#!/bin/bash
# Call TShock's REST API from inside the container.
#
#   scripts/rest.sh status
#   scripts/rest.sh v2/players/list
#   scripts/rest.sh v2/server/broadcast msg='Restart in five minutes'
#
# Prints the JSON body. Exit 0 when TShock answered 200, 1 when it answered
# anything else, 3 when it could not be asked at all: the server is not
# running, REST is off, or no token of this template's is in config.json.
#
# THE API IS PUBLISHED NOWHERE, so this asks from inside the container,
# where the image has bash and nothing else (no curl, no wget, no python):
# HTTP/1.0 over bash's /dev/tcp. THE TOKEN NEVER LEAVES THE CONTAINER. It is
# read from config.json in there, by the line after the entry start.sh made,
# and used in there; it is in no argument to docker, no environment variable
# and no output. Names and values are percent-encoded in there too, byte by
# byte, so a name with a space, an ampersand or a letter outside ASCII
# arrives as typed.
#
#   TERRARIA_COMPOSE_FILE   the compose file   (default terraria-server-docker-compose.yml)
#   COMPOSE_PROJECT_NAME    the project        (default terraria)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
[ $# -ge 1 ] || { echo "usage: scripts/rest.sh <path> [name=value ...]" >&2; exit 2; }
COMPOSE_FILE=${TERRARIA_COMPOSE_FILE:-terraria-server-docker-compose.yml}
PROJECT=${COMPOSE_PROJECT_NAME:-terraria}

if [ -z "$(docker compose -f "$COMPOSE_FILE" -p "$PROJECT" ps -q --status running terraria-server 2>/dev/null)" ]; then
  echo "the server is not running" >&2
  exit 3
fi

docker compose -f "$COMPOSE_FILE" -p "$PROJECT" exec -T terraria-server bash -s -- "$@" <<'IN'
set -uo pipefail
export LC_ALL=C
CFG=/tshock/config.json
tok="$(grep -B1 '"Username": "terraria-server-docker-compose"' "$CFG" 2>/dev/null | head -1 | grep -oE '"[0-9a-f]{48}"' | tr -d '"')"
if [ -z "$tok" ]; then
  echo "no REST token of this template's in $CFG; start the server once with scripts/start.sh as its entrypoint" >&2
  exit 3
fi
enc() {
  local s=$1 out="" c i h
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [A-Za-z0-9._~-]) out+=$c ;;
      *) printf -v h '%%%02X' "'$c"; out+=$h ;;
    esac
  done
  printf '%s' "$out"
}
path=${1#/}; shift
query="token=$tok"
for kv in "$@"; do
  query+="&$(enc "${kv%%=*}")=$(enc "${kv#*=}")"
done
if ! exec 3<>/dev/tcp/127.0.0.1/7878; then
  echo "TShock's REST API does not answer on 7878: is RestApiEnabled true in $CFG?" >&2
  exit 3
fi
printf 'GET /%s?%s HTTP/1.0\r\nHost: localhost\r\n\r\n' "$path" "$query" >&3
IFS=' ' read -r -t 30 _ code _ <&3 || { echo "TShock accepted the connection and did not answer in 30 s" >&2; exit 3; }
while IFS= read -r -t 30 h <&3; do [ "${h%$'\r'}" = "" ] && break; done
timeout 30 cat <&3
echo
[ "$code" = 200 ]
IN
