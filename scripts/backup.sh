#!/bin/bash
# Archive the Terraria world and TShock's database.
#
# WHAT IS ARCHIVED, from the three volumes:
#   worlds/   the world, and the game's own .bak of it
#   tshock/   config.json (with the REST token, which is why the archive is
#             mode 600), tshock.sqlite (accounts, groups and BANS: a restore
#             without it lets every banned player back in), the motd, rules,
#             whitelist and server-side character settings
#   plugins/  empty until you add one, kept so one added later is not lost
# Not tshock/logs, tshock/crashes or the pid file: of no use to a restore.
# Nor what scripts/restore.sh set aside, which is in .before-restore-* until
# you delete it.
#
# SAVED FIRST. scripts/admin.sh save asks TShock to write the world now and
# waits until the file is written (TShock answers before it is), so the
# archive holds the world as it is: not as the last autosave left it, and not
# half written.
# When the save cannot be asked for (the server is stopped, which already
# saved it on the way out through start.sh, or REST does not answer), the
# archive is still made, from the file on disk, and the line says so.
#
# A BACKUP IS JUDGED BY WHAT IT HOLDS. The archive is written as .partial and
# renamed only once tar has succeeded AND the archive is shown to hold both
# the world the compose file names and tshock.sqlite: tar's exit code says it
# ran, not that it kept a server.
#
# NO WORLD YET IS NOT A FAILURE; NO WORLD ANY MORE IS. Before the first start
# there is nothing to archive, and this says so and exits 0. Once an archive
# of a world exists, the same absence means the world is gone, or is not
# where the compose file says, and it fails.
#
# Usage: scripts/backup.sh
#   TERRARIA_BACKUP_DIR     where archives go        (default ./backups)
#   TERRARIA_BACKUP_KEEP    how many to keep         (default 14)
#   TERRARIA_WORLD_FILE     the world's file name    (default from .env, else world)
#   TERRARIA_VOLUME_PREFIX  the volumes' prefix      (default from .env, else terraria-server)
#
# Read whole before it runs: one brace group, ending in exit (scripts/guard.sh,
# "READ WHOLE BEFORE IT RUNS", says why).
{
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

from_env() {  # name default: the environment, then .env, then the default
  local v="${!1:-}"
  [ -n "$v" ] || v="$(grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2-)"
  echo "${v:-$2}"
}
BACKUP_DIR="${TERRARIA_BACKUP_DIR:-./backups}"
KEEP="${TERRARIA_BACKUP_KEEP:-14}"
WORLD="$(from_env TERRARIA_WORLD_FILE world).wld"
PREFIX="$(from_env TERRARIA_VOLUME_PREFIX terraria-server)"
IMAGE=terraria-server-docker-compose:local
say() { echo "$(date '+%F %T') $*"; }

for v in tshock worlds plugins; do
  docker volume inspect "$PREFIX-$v" >/dev/null 2>&1 || { say "no volume $PREFIX-$v: nothing to back up" >&2; exit 1; }
done
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker compose -f terraria-server-docker-compose.yml build -q terraria-server >/dev/null \
  || { say "the image $IMAGE is not here and could not be built" >&2; exit 1; }
# The template's own image, as root, with no network: no second image to pull
# or pin, and it reads config.json, which is mode 600 for uid 1000.
helper() {  # entrypoint [docker run options...] -- [arguments...]
  local entry=$1; shift
  local opts=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do opts+=("$1"); shift; done
  shift
  docker run --rm --network none --user 0:0 --entrypoint "$entry" \
    -v "$PREFIX-tshock:/tr/tshock:ro" -v "$PREFIX-worlds:/tr/worlds:ro" -v "$PREFIX-plugins:/tr/plugins:ro" \
    ${opts[@]+"${opts[@]}"} "$IMAGE" "$@"
}

# `test` answers 1 for "not there"; anything else is docker failing to ask.
helper test -- -f "/tr/worlds/$WORLD"
rc=$?
if [ "$rc" -gt 1 ]; then say "could not look inside $PREFIX-worlds (docker exited $rc); nothing archived" >&2; exit 1; fi
if [ "$rc" = 1 ]; then
  last="$(find "$BACKUP_DIR" -maxdepth 1 -name 'terraria-*.tar.gz' 2>/dev/null | sort | tail -1)"
  if [ -n "$last" ]; then
    say "FAILED: no $WORLD in $PREFIX-worlds, and $(basename "$last") holds a world: the world is gone, or the compose file names another one" >&2
    exit 1
  fi
  say "no $WORLD in $PREFIX-worlds yet: nothing to back up. The first start generates it."
  exit 0
fi

saved="saved first"
scripts/admin.sh save >/dev/null 2>&1 || saved="NOT saved first (the server is stopped, or REST did not answer): archived from the file on disk"

mkdir -p "$BACKUP_DIR"
OUT="$(cd "$BACKUP_DIR" && pwd)"
NAME="terraria-$(date +%Y%m%d-%H%M%S).tar.gz"
if ! helper tar -v "$OUT:/out" -- -czf "/out/$NAME.partial" -C /tr \
       --exclude tshock/logs --exclude tshock/crashes --exclude tshock/tshock.pid --exclude '*/.before-restore-*' worlds tshock plugins; then
  mv "$OUT/$NAME.partial" "$OUT/$NAME.failed" 2>/dev/null
  say "FAILED: tar did not complete; see $BACKUP_DIR/$NAME.failed" >&2
  exit 1
fi
# Owned by whoever ran this, readable by nobody else: it holds the REST token.
# shellcheck disable=SC2016  # expanded by the shell in the container, not here
helper sh -v "$OUT:/out" -e OWNER="$(id -u):$(id -g)" -- -c 'chown "$OWNER" "/out/$0" && chmod 600 "/out/$0"' "$NAME.partial"
held="$(tar -tzf "$OUT/$NAME.partial" 2>/dev/null | grep -cE "^(\./)?(worlds/$WORLD|tshock/tshock\.sqlite)$")"
if [ "${held:-0}" -lt 2 ]; then
  mv "$OUT/$NAME.partial" "$OUT/$NAME.failed"
  say "FAILED: the archive lacks worlds/$WORLD or tshock/tshock.sqlite, so it is not a backup of this server; see $BACKUP_DIR/$NAME.failed" >&2
  exit 1
fi
mv "$OUT/$NAME.partial" "$OUT/$NAME"
say "wrote $BACKUP_DIR/$NAME ($(du -h "$OUT/$NAME" | cut -f1)): $WORLD and tshock.sqlite, $saved"

# The newest KEEP finished archives stay; .partial and .failed are never kept.
# shellcheck disable=SC2012  # the names are this script's own fixed pattern
ls -1t "$OUT"/terraria-*.tar.gz 2>/dev/null | tail -n +"$((KEEP + 1))" | while IFS= read -r old; do rm -f -- "$old"; done
find "$OUT" -maxdepth 1 -name 'terraria-*.tar.gz.partial' -mmin +60 -delete 2>/dev/null
exit 0
}
