#!/bin/bash
# Put an archive from scripts/backup.sh back where the server reads it.
#
#   scripts/restore.sh backups/terraria-20261025-043000.tar.gz
#
# THE WORLD HAS TO BE THE ONE THE COMPOSE FILE NAMES. The server is started
# with -world /worlds/<TERRARIA_WORLD_FILE>.wld and -autocreate, so a world
# file under any other name is not an error to it: it generates a new world
# and starts, healthy, with nobody's buildings in it. A restore that puts the
# old world back under the wrong name succeeds and reports success. So this
# refuses an archive whose world is not the one .env names, and checks
# afterwards that it is at that path.
#
# THE BAN LIST COMES BACK WITH THE WORLD. An archive without tshock.sqlite is
# refused: a restore of the world alone lets every banned player back in and
# forgets every account.
#
# BY PATH AND BY BYTE. Every file in the archive is compared with the file at
# its live path, by sha256, after the extract.
#
# NOTHING IS OVERWRITTEN. What each volume holds now is moved into a
# .before-restore-<time> directory inside that volume first, so a restore of
# the wrong archive is undone by moving it back. The server must be stopped:
# it holds the world in memory and would write it over the restored one on
# its way out.
#
#   TERRARIA_WORLD_FILE     the world's file name   (default from .env, else world)
#   TERRARIA_VOLUME_PREFIX  the volumes' prefix     (default from .env, else terraria-server)
#   COMPOSE_PROJECT_NAME    the compose project     (default terraria)
#
# Read whole before it runs: one brace group, ending in exit (scripts/guard.sh,
# "READ WHOLE BEFORE IT RUNS", says why).
{
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

from_env() {
  local v="${!1:-}"
  [ -n "$v" ] || v="$(grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2-)"
  echo "${v:-$2}"
}
ARCHIVE="${1:-}"
WORLD="$(from_env TERRARIA_WORLD_FILE world).wld"
PREFIX="$(from_env TERRARIA_VOLUME_PREFIX terraria-server)"
PROJECT="${COMPOSE_PROJECT_NAME:-terraria}"
COMPOSE_FILE=terraria-server-docker-compose.yml
IMAGE=terraria-server-docker-compose:local

if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then
  echo "usage: scripts/restore.sh <archive from scripts/backup.sh>" >&2
  exit 2
fi
for v in tshock worlds plugins; do
  docker volume inspect "$PREFIX-$v" >/dev/null 2>&1 || { echo "no volume $PREFIX-$v: create it first (docker volume create $PREFIX-$v)" >&2; exit 1; }
done
if [ -n "$(docker compose -f "$COMPOSE_FILE" -p "$PROJECT" ps -q --status running terraria-server 2>/dev/null)" ]; then
  echo "the server is running; stop it first, or it writes its world over the restored one on the way out:" >&2
  echo "  docker compose -f $COMPOSE_FILE -p $PROJECT stop terraria-server" >&2
  exit 1
fi
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker compose -f "$COMPOSE_FILE" build -q terraria-server >/dev/null \
  || { echo "the image $IMAGE is not here and could not be built" >&2; exit 1; }

# What the archive holds, read before anything moves.
listing="$(tar -tzf "$ARCHIVE" 2>/dev/null | sed 's#^\./##')" || { echo "$ARCHIVE is not a readable tar.gz; nothing changed" >&2; exit 1; }
outside="$(grep -vcE '^(worlds|tshock|plugins)(/|$)' <<<"$listing")"
worlds="$(grep -E '^worlds/[^/]+\.wld$' <<<"$listing" | sed 's#^worlds/##' | tr '\n' ' ')"
if [ "$outside" -gt 0 ] || ! grep -qx 'tshock/tshock.sqlite' <<<"$listing"; then
  echo "$ARCHIVE is not an archive from scripts/backup.sh ($outside entr(ies) outside worlds/, tshock/ and plugins/; tshock.sqlite $(grep -qx 'tshock/tshock.sqlite' <<<"$listing" && echo present || echo MISSING)); nothing changed" >&2
  exit 1
fi
if ! grep -qx "worlds/$WORLD" <<<"$listing"; then
  echo "$ARCHIVE holds the world(s) ${worlds:-none}, and the compose file starts /worlds/$WORLD: the server would generate a new world under that name and start in it. Set TERRARIA_WORLD_FILE in .env to the archive's world, without .wld; nothing changed" >&2
  exit 1
fi

DIR="$(cd "$(dirname "$ARCHIVE")" && pwd)"
FILE="$(basename "$ARCHIVE")"
stamp="$(date +%Y%m%d-%H%M%S)"
vols=(-v "$PREFIX-tshock:/tr/tshock" -v "$PREFIX-worlds:/tr/worlds" -v "$PREFIX-plugins:/tr/plugins")
# shellcheck disable=SC2016  # expanded by the shell in the container
docker run --rm --network none --user 0:0 --entrypoint bash "${vols[@]}" -v "$DIR:/in:ro" -e STAMP="$stamp" -e FILE="$FILE" "$IMAGE" -euc '
  shopt -s dotglob nullglob
  for v in tshock worlds plugins; do
    aside="/tr/$v/.before-restore-$STAMP"
    mkdir "$aside"
    for f in /tr/$v/*; do
      case "$f" in */.before-restore-*) ;; *) mv "$f" "$aside/" ;; esac
    done
  done
  tar -xzf "/in/$FILE" -C /tr
  # The server runs as uid 1000; the token file stays its own.
  chown -R 1000:1000 /tr/tshock /tr/worlds /tr/plugins
  [ -f /tr/tshock/config.json ] && chmod 600 /tr/tshock/config.json
  true
' || { echo "the extract failed; what the volumes held is in .before-restore-$stamp inside each" >&2; exit 1; }

# BY PATH AND BY BYTE: the archive unpacked once more, apart, and every file
# in it compared by sha256 with the file at its live path.
# shellcheck disable=SC2016  # expanded by the shell in the container
check="$(docker run --rm --network none --user 0:0 --entrypoint bash "${vols[@]}" -v "$DIR:/in:ro" -e FILE="$FILE" "$IMAGE" -c '
  mkdir /tmp/c && tar -xzf "/in/$FILE" -C /tmp/c && cd /tmp/c || exit 1
  find . -type f -print0 | xargs -0 sha256sum >/tmp/sums
  cd /tr && echo "$(sha256sum -c /tmp/sums 2>/dev/null | grep -vc ": OK$") $(grep -c . /tmp/sums)"')"
read -r bad files <<<"$check"
if [ -z "${files:-}" ] || [ "${bad:-1}" != 0 ]; then
  echo "restore FAILED its check: $bad of $files file(s) are not at their live path byte for byte; what the volumes held is in .before-restore-$stamp inside each" >&2
  exit 1
fi
echo "restored $files file(s) from $FILE: worlds/$WORLD and tshock/tshock.sqlite at the paths the server reads, byte for byte; what the volumes held is in .before-restore-$stamp inside each"
echo "start the server: docker compose -f $COMPOSE_FILE -p $PROJECT up -d"
exit
}
