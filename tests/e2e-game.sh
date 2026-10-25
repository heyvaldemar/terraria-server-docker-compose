#!/bin/bash
# The real server, from empty volumes, through this compose file.
#
# Terraria is small enough to run whole on a CI runner: the image is TShock's
# own, a small world generates in under a minute, and nothing is downloaded at
# start. So every claim the compose file and the scripts make is checked
# against the server itself, and the ones that say "without this, that" are
# checked both ways.
#
#   the process        uid 1000, no capabilities, no anonymous volume
#   the API            REST off the host, the token in no environment, no
#                      command line and no log, config.json mode 600
#   the settings       the password from .env, quote and backslash included
#   the health check   red through a world generation, red for a frozen
#                      server, green again when it thaws
#   moderation         a 60-minute ban on a server in Asia/Tokyo ends in 60
#                      minutes, and the same ban with a Z suffix does not;
#                      unban, kick of nobody, say, save
#   the way out        stop saves the world through start.sh, exit 0; the
#                      image's own entrypoint loses it, exit 143
#   backup, restore    the archive holds the world and the ban database,
#                      mode 600; a restore into fresh volumes brings back the
#                      same world with its bans, byte for byte; an archive
#                      without the database, or with another world's name,
#                      is refused and changes nothing
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

RUN=$$
export COMPOSE_PROJECT_NAME="tr-e2e-$RUN"
export TERRARIA_VOLUME_PREFIX="tr-e2e-$RUN"
export TERRARIA_SERVER_PORT=17777
export TERRARIA_WORLD_SIZE=1
export TERRARIA_WORLD_NAME="CI World"
export TERRARIA_WORLD_FILE=ci-world
export TERRARIA_SERVER_TIMEZONE=Asia/Tokyo
export TERRARIA_SERVER_PASSWORD='pa"ss\word'
export TERRARIA_BACKUP_DIR
TERRARIA_BACKUP_DIR="$(mktemp -d)"
F=terraria-server-docker-compose.yml
IMAGE=terraria-server-docker-compose:local
compose() { docker compose -f "$F" "$@"; }
cid() { compose ps -a -q terraria-server 2>/dev/null | head -1; }
health() { docker inspect -f '{{.State.Health.Status}}' "$(cid)" 2>/dev/null; }
wait_health() {  # status seconds
  for _ in $(seq 1 "$2"); do [ "$(health)" = "$1" ] && return 0; sleep 1; done
  return 1
}
volumes() { for v in tshock worlds plugins; do docker volume "$1" "$TERRARIA_VOLUME_PREFIX-$v" >/dev/null 2>&1; done; }
cleanup() {
  compose down --remove-orphans >/dev/null 2>&1
  COMPOSE_PROJECT_NAME="tr-e2e-$RUN-restored" TERRARIA_VOLUME_PREFIX="tr-e2e-$RUN-restored" docker compose -f "$F" down >/dev/null 2>&1
  docker rm -f "tr-e2e-$RUN-stock" >/dev/null 2>&1
  for p in "tr-e2e-$RUN" "tr-e2e-$RUN-restored" "tr-e2e-$RUN-stock"; do
    for v in tshock worlds plugins; do docker volume rm -f "$p-$v" >/dev/null 2>&1; done
  done
  rm -rf "$TERRARIA_BACKUP_DIR"
}
trap cleanup EXIT

echo "=== the first start, from empty volumes ==="
echo
volumes create
compose up -d --build --quiet-pull >/dev/null 2>&1 || { echo "the stack did not start"; compose logs --tail 50; exit 1; }
# Red, or still starting, for as long as the world is being generated.
# (Logs are read into a string and then searched: with pipefail, grep -q
# closing the pipe early fails the whole pipeline.)
seen_green_early=false
for _ in $(seq 1 300); do
  started="$(docker logs "$(cid)" 2>&1 | grep -c 'Server started')"
  h="$(health)"
  [ "$started" = 0 ] && [ "$h" = healthy ] && seen_green_early=true
  [ "$h" = healthy ] && break
  sleep 1
done
[ "$(health)" = healthy ] || { echo "the server never became healthy"; docker logs --tail 60 "$(cid)"; exit 1; }
$seen_green_early && fail "healthy while the world was still being generated" || pass "not healthy until the world was generated and the game listened"

pid="$(docker exec "$(cid)" bash -c 'for p in /proc/[0-9]*; do [ "$(cat "$p/comm" 2>/dev/null)" = TShock.Server ] && echo "${p#/proc/}"; done' | head -1)"
uid="$(docker exec "$(cid)" sh -c "sed -n 's/^Uid:\t\([0-9]*\).*/\1/p' /proc/$pid/status")"
cap="$(docker exec "$(cid)" sh -c "sed -n 's/^CapEff:\t//p' /proc/$pid/status")"
[ "$uid" = 1000 ] && pass "TShock runs as uid 1000" || fail "TShock runs as uid ${uid:-?}"
[ "$cap" = 0000000000000000 ] && pass "with no capabilities (CapEff $cap)" || fail "capabilities: CapEff ${cap:-?}"
anon="$(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' "$(cid)" | tr ' ' '\n' | grep -vcE "^($TERRARIA_VOLUME_PREFIX-(tshock|worlds|plugins))?$")"
[ "$anon" = 0 ] && pass "no anonymous volume: the image's three VOLUME paths are all named" || fail "$anon anonymous volume(s) attached"

echo
echo "=== the API, the token and the settings ==="
echo
if (exec 3<>/dev/tcp/127.0.0.1/7878) 2>/dev/null; then fail "something answers on the host's 7878"; else pass "REST is not reachable from the host"; fi
[ -z "$(docker port "$(cid)" 7878/tcp 2>/dev/null)" ] && pass "7878 is published nowhere" || fail "7878 is published: $(docker port "$(cid)" 7878/tcp)"
mode="$(docker exec "$(cid)" stat -c %a /tshock/config.json)"
[ "$mode" = 600 ] && pass "config.json is mode 600" || fail "config.json is mode $mode"
# The token is read and compared inside the container; it is never printed.
leak="$( { docker inspect "$(cid)"; docker logs "$(cid)" 2>&1; } | docker exec -i "$(cid)" bash -c '
  tok="$(grep -B1 "\"Username\": \"terraria-server-docker-compose\"" /tshock/config.json | head -1 | grep -oE "[0-9a-f]{48}")"
  [ ${#tok} = 48 ] || { echo notoken; exit; }
  grep -qF "$tok" && echo leaked || echo clean')"
[ "$leak" = clean ] && pass "a 48-character token, in neither docker inspect nor the log" || fail "token check: $leak"
grep -q "A password for this server was set in config.json and is being used" <<<"$(docker logs "$(cid)" 2>&1)" \
  && grep -q '"serverpassword": true' <<<"$(scripts/rest.sh status)" \
  && pass "the password from .env, quote and backslash included, is the server's" || fail "the password from .env was not taken"
st="$(scripts/status.sh)"
[ "$st" = '{"status": "Online", "players": 0, "max": 8, "world": "CI World"}' ] && pass "status: $st" || fail "status: $st"

echo
echo "=== the health check: a frozen server ==="
echo
# TShock itself, not PID 1: that is start.sh, waiting for it.
docker exec "$(cid)" bash -c "kill -STOP $pid"   # bash's own kill: the image has no kill binary
if wait_health unhealthy 120; then
  state="$(docker exec "$(cid)" sh -c "sed -n 's/^State:\t//p' /proc/$pid/status")"
  pass "frozen with SIGSTOP: unhealthy, with TShock.Server still in the process table ($state)"
else
  fail "frozen and still $(health)"
fi
docker exec "$(cid)" bash -c "kill -CONT $pid"
wait_health healthy 120 && pass "thawed: healthy again" || fail "thawed and still $(health)"

echo
echo "=== moderation, on a server in Asia/Tokyo ==="
echo
out="$(scripts/admin.sh ban 'Ghost One' 60 'e2e')"; rc=$?
[ "$rc" = 0 ] && pass "ban: $out" || fail "ban: exit $rc, $out"
listed="$(scripts/admin.sh bans | grep 'name:Ghost One')"
want="$(date -u -d '+60 min' '+%H:%M' 2>/dev/null || date -u -v+60M '+%H:%M')"
grep -q "until .* $want UTC" <<<"$listed" && pass "the list says it ends at $want UTC, 60 minutes from now" || fail "the list says: $listed (want $want UTC)"
# The same 60 minutes with a trailing Z, sent the way the API invites.
end_z="$(date -u -d '+60 min' +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -v+60M +%Y-%m-%dT%H:%M:%S)Z"
scripts/rest.sh v3/bans/create identifier='name:With Z' end="$end_z" >/dev/null 2>&1
listed_z="$(scripts/admin.sh bans | grep 'name:With Z')"
grep -q "until .* $want UTC" <<<"$listed_z" && fail "with a Z suffix the ban still ends at $want: the zone handling this works around is gone" \
  || pass "with a Z suffix the same ban is listed $listed_z, not $want: why admin.sh sends none"
scripts/admin.sh unban 'With Z' >/dev/null
out="$(scripts/admin.sh unban 'Ghost One')" && ! grep -q 'name:Ghost One' <<<"$(scripts/admin.sh bans)" && pass "unban: $out, and gone from the list" || fail "unban: $out"
scripts/admin.sh unban 'Ghost One' >/dev/null 2>&1 && fail "a second unban of the same name said it worked" || pass "a second unban says not banned, exit 1"
out="$(scripts/admin.sh ban 'Banned Before Backup' 0)" && pass "permanent ban: $out" || fail "permanent ban: $out"
out="$(scripts/admin.sh kick Nobody 2>&1)" && fail "kick of nobody said it worked: $out" || pass "kick of nobody: $out"
scripts/admin.sh say "e2e & co" >/dev/null && pass "say: answered 200" || fail "say failed"
before="$(docker exec "$(cid)" stat -c %y "/worlds/$TERRARIA_WORLD_FILE.wld")"
out="$(scripts/admin.sh save 2>&1)" && [ "$(docker exec "$(cid)" stat -c %y "/worlds/$TERRARIA_WORLD_FILE.wld")" != "$before" ] \
  && pass "save waits for the file: $out" || fail "save: $out"

echo
echo "=== backup ==="
echo
out="$(scripts/backup.sh)"; rc=$?
archive="$(find "$TERRARIA_BACKUP_DIR" -name 'terraria-*.tar.gz' | head -1)"
if [ "$rc" = 0 ] && [ -n "$archive" ]; then pass "backup: ${out#* * }"; else fail "backup: exit $rc, $out"; echo; echo "passed: $PASSED   failed: $FAILED"; exit 1; fi
amode="$(stat -c %a "$archive" 2>/dev/null || stat -f %Lp "$archive")"
[ "$amode" = 600 ] && pass "the archive is mode 600, owned by $(stat -c %U "$archive" 2>/dev/null || stat -f %Su "$archive")" || fail "the archive is mode $amode"
list="$(tar -tzf "$archive")"
grep -qx "worlds/$TERRARIA_WORLD_FILE.wld" <<<"$list" && grep -qx tshock/tshock.sqlite <<<"$list" && ! grep -q '^tshock/logs/.' <<<"$list" \
  && pass "it holds the world and tshock.sqlite, and no logs" || fail "the archive holds: $(tr '\n' ' ' <<<"$list")"

echo
echo "=== the way out ==="
echo
before="$(docker exec "$(cid)" stat -c %Y "/worlds/$TERRARIA_WORLD_FILE.wld")"
sleep 2
compose stop >/dev/null 2>&1
code="$(docker inspect -f '{{.State.ExitCode}}' "$(cid)")"
after="$(docker run --rm -v "$TERRARIA_VOLUME_PREFIX-worlds:/w" --entrypoint stat "$IMAGE" -c %Y "/w/$TERRARIA_WORLD_FILE.wld")"
grep -q 'Saving before exit' <<<"$(docker logs "$(cid)" 2>&1)" && [ "$code" = 0 ] && [ "$after" -gt "$before" ] \
  && pass "stop: TShock saved the world on the way out and exited 0" || fail "stop: exit $code, world $before -> $after"
# Without the wrapper: the image's own entrypoint on a copy of the world.
for v in tshock worlds plugins; do
  docker volume create "tr-e2e-$RUN-stock-$v" >/dev/null
  docker run --rm --user 0:0 --entrypoint bash -v "$TERRARIA_VOLUME_PREFIX-$v:/from:ro" -v "tr-e2e-$RUN-stock-$v:/to" "$IMAGE" -c 'cp -a /from/. /to/' >/dev/null
done
docker run -d --name "tr-e2e-$RUN-stock" -i -e DOTNET_BUNDLE_EXTRACT_BASE_DIR=/tmp/b -e HOME=/tmp \
  -v "tr-e2e-$RUN-stock-tshock:/tshock" -v "tr-e2e-$RUN-stock-worlds:/worlds" -v "tr-e2e-$RUN-stock-plugins:/plugins" \
  "$IMAGE" -world "/worlds/$TERRARIA_WORLD_FILE.wld" -port 7777 >/dev/null
for _ in $(seq 1 120); do grep -q 'Server started' <<<"$(docker logs "tr-e2e-$RUN-stock" 2>&1)" && break; sleep 1; done
before="$(docker exec "tr-e2e-$RUN-stock" stat -c %Y "/worlds/$TERRARIA_WORLD_FILE.wld")"
sleep 2
docker stop -t 60 "tr-e2e-$RUN-stock" >/dev/null
code="$(docker inspect -f '{{.State.ExitCode}}' "tr-e2e-$RUN-stock")"
after="$(docker run --rm -v "tr-e2e-$RUN-stock-worlds:/w" --entrypoint stat "$IMAGE" -c %Y "/w/$TERRARIA_WORLD_FILE.wld")"
[ "$code" = 143 ] && [ "$after" = "$before" ] && pass "the image's own entrypoint: exit 143, the world file untouched, so start.sh is what saves it" \
  || fail "the image's own entrypoint: exit $code, world $before -> $after (the comment in the compose file would be wrong)"

echo
echo "=== restore, into fresh volumes ==="
echo
R="tr-e2e-$RUN-restored"
for v in tshock worlds plugins; do docker volume create "$R-$v" >/dev/null; done
# Refusals first: each leaves the fresh volumes empty.
bad="$TERRARIA_BACKUP_DIR/no-db.tar.gz"
mkdir -p "$TERRARIA_BACKUP_DIR/x" && tar -xzf "$archive" -C "$TERRARIA_BACKUP_DIR/x" && rm -f "$TERRARIA_BACKUP_DIR/x/tshock/tshock.sqlite" \
  && tar -czf "$bad" -C "$TERRARIA_BACKUP_DIR/x" worlds tshock plugins
out="$(TERRARIA_VOLUME_PREFIX=$R COMPOSE_PROJECT_NAME=$R scripts/restore.sh "$bad" 2>&1)" && fail "an archive without tshock.sqlite was restored" \
  || pass "refused without tshock.sqlite: ${out%%;*}"
out="$(TERRARIA_VOLUME_PREFIX=$R COMPOSE_PROJECT_NAME=$R TERRARIA_WORLD_FILE=other-world scripts/restore.sh "$archive" 2>&1)" && fail "an archive of another world's name was restored" \
  || pass "refused for a compose file that starts another world: ${out:0:120}..."
empty="$(docker run --rm -v "$R-worlds:/w" --entrypoint sh "$IMAGE" -c 'ls -A /w | grep -c .')"
[ "$empty" = 0 ] && pass "and the refusals changed nothing" || fail "after the refusals the fresh worlds volume holds $empty entr(ies)"
out="$(TERRARIA_VOLUME_PREFIX=$R COMPOSE_PROJECT_NAME=$R scripts/restore.sh "$archive" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "restore: $(head -1 <<<"$out")" || fail "restore: exit $rc, $out"
TERRARIA_VOLUME_PREFIX=$R COMPOSE_PROJECT_NAME=$R TERRARIA_SERVER_PORT=17778 docker compose -f "$F" up -d >/dev/null 2>&1
for _ in $(seq 1 180); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$(COMPOSE_PROJECT_NAME=$R docker compose -f "$F" ps -q terraria-server)" 2>/dev/null)" = healthy ] && break
  sleep 1
done
st="$(TERRARIA_VOLUME_PREFIX=$R COMPOSE_PROJECT_NAME=$R scripts/status.sh)"
grep -q '"world": "CI World"' <<<"$st" && pass "the restored server is up, in the same world: $st" || fail "the restored server: $st"
grep -q 'name:Banned Before Backup permanent' <<<"$(TERRARIA_VOLUME_PREFIX=$R COMPOSE_PROJECT_NAME=$R scripts/admin.sh bans)" \
  && pass "and the ban made before the backup is still there" || fail "the ban made before the backup is gone"
generated="$(docker logs "$(COMPOSE_PROJECT_NAME=$R docker compose -f "$F" ps -q terraria-server)" 2>&1 | grep -cE 'Generating world|Creating world')"
[ "$generated" = 0 ] && pass "no world was generated on the way" || fail "the restored server generated a world"

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
