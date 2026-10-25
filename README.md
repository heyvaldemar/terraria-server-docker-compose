# Terraria server using Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/terraria-server-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/terraria-server-docker-compose/actions/workflows/deployment-verification.yml)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/15914/badge)](https://www.bestpractices.dev/projects/15914)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A Terraria server on TShock, the community's server, from TShock's own image, pinned by digest and run as uid 1000 with no capabilities. Its admin API is published nowhere, a stop saves the world, and every claim below is checked against the real server on every change.

Terraria is small enough to run whole in CI: no game download, a small world in under a minute. So this template's tests start the server itself, from empty volumes, and the ones that say "without this, that" run both ways.

```bash
git clone https://github.com/heyvaldemar/terraria-server-docker-compose
cd terraria-server-docker-compose
cp .env.example .env && $EDITOR .env      # a world name, a size, a password if you want one
for v in tshock worlds plugins; do docker volume create terraria-server-$v; done
docker compose -f terraria-server-docker-compose.yml -p terraria up -d
```

The first start builds one layer on the pinned image, generates the world and starts. Watch it:

```bash
docker compose -p terraria logs -f terraria-server
docker compose -p terraria ps          # healthy once the world is loaded and the game listens
```

Players join from Terraria's multiplayer menu with the host's address and port 7777, TCP.

**Become the server's owner once.** TShock prints a one-time setup code on the first start. Join the game and type `/setup <code>`; it makes you a superadmin, and the code stops working.

```bash
docker compose -p terraria exec terraria-server cat /tshock/setup-code.txt
```

## What this file knows that a fresh one does not

**A stop saves the world.** TShock does not save on SIGTERM. Run the way the image runs it, `docker compose stop` ended the server in under a second, exit 143, and the world on disk was whatever the last autosave wrote. `scripts/start.sh` is the entrypoint here: TShock reads its console from a pipe the script holds open, and the stop signal becomes `off`, TShock's own command that saves the world and shuts down. The test stops the server both ways and compares the world file: rewritten and exit 0 through the script, untouched and exit 143 without it.

**It runs as uid 1000, with nothing.** The official image runs as root, and TShock writes into its own program directory, so as any other user it cannot start. One layer (`Dockerfile`) gives that directory and the three volume paths to uid 1000; the compose file drops every capability and sets `no-new-privileges`. As uid 1000 the server also stopped once more before it started, on "Failed to determine location for extracting embedded files": `TShock.Server` is a .NET single-file bundle that unpacks itself into a directory only root can write, so `DOTNET_BUNDLE_EXTRACT_BASE_DIR` points it at `/tmp`. The test reads the running process's uid and its effective capabilities, `0000000000000000`.

**The admin API is published nowhere, and its token is in nothing you can read.** TShock's REST API can ban, kick, run any console command and read the account database. It answers on 7878 inside the container only. `scripts/start.sh` turns it on and makes its token on the first start, 48 hex characters from `/dev/urandom`, kept in `config.json` at mode 600; `scripts/rest.sh` reads and uses it inside the container, over bash's `/dev/tcp`, because the image has no curl, wget or python. The token is in no `.env`, no environment variable, no command line and no log; the test pipes `docker inspect` and the container log into the container and looks for it there.

**Healthy means the game listens and answers.** REST `/status` answers 200 while the world is still being generated: measured here, for 98 seconds of a large world's first start, before the game had opened its port. A check on the process name stays green for a frozen server. So the check asks two things: is the game port in LISTEN in the container's `/proc/net/tcp`, read rather than connected to, because every probe of the game port is logged as a player arriving and leaving; and does REST answer. The test freezes the server with SIGSTOP and watches it go unhealthy with its process still there, then thaw and come back.

**The memory ceiling is measured.** At the first start, generating the world, an empty server peaked at 386 MiB for a small world, 454 MiB for a medium one and 663 MiB for a large one (cgroup `memory.peak`). The limit is 2 GB, with no swap on top, so a leak here cannot get some other container killed and a tick that pages is not a stutter every player sees. Players and a long-played world add to it; raise `TERRARIA_SERVER_MEMORY_LIMIT` with them.

**A ban is judged by the ban list, never by the status code.** Measured against TShock 6.2.1: `/v3/bans/create` writes the ban and then answers 500, "Object reference not set to an instance of an object", because its next step, kicking matching players who are online, trips over the empty slots. `scripts/admin.sh ban` looks the ban up afterwards and checks its end against the one asked for, and kicks a player who is on by itself.

**A timed ban's end is UTC without a zone suffix.** TShock takes a ban's start as UTC and parses its end with .NET's `DateTime.TryParse`, which turns a trailing `Z` into the server's local time. On a server not on UTC, a timed ban then ends hours off. The test runs the server on Asia/Tokyo: a 60-minute ban from `admin.sh` ends 60 minutes later, and the same 60 minutes sent with a `Z` is listed ten hours out. On the machine this template comes from, a 60-minute ban came out already over.

**The three volume paths are all named.** The image declares `/tshock`, `/worlds` and `/plugins` as volumes. Leave one out and Docker makes an anonymous volume for it on every recreate, holding what was written there last time and attached to nothing. All three are external here, so `docker compose down -v` cannot delete the world or the ban list, and the test checks that nothing anonymous is attached.

**The password lives in `.env`, and goes into a file.** `TERRARIA_SERVER_PASSWORD` is written into `ServerPassword` in `config.json` on every start, escaped, so a quote or a backslash in it works and an empty one opens the server again. It is not passed on TShock's command line, where any user on the host could read it with `ps`.

## Administration

```bash
scripts/status.sh                          # {"status": "Online", "players": 0, "max": 8, "world": "Terraria"}
scripts/admin.sh who
scripts/admin.sh kick <name> [reason]
scripts/admin.sh ban <name> [minutes] [reason]    # no minutes, or 0: permanent
scripts/admin.sh unban <name>
scripts/admin.sh bans
scripts/admin.sh say <message>
scripts/admin.sh save                      # returns once the world file is written
scripts/rest.sh <endpoint> [name=value ...]       # anything else TShock's REST API offers
```

Bans are by character name, so they hold for somebody who has already left. An unknown player count is not zero: when TShock does not answer, `status.sh` says `"Unknown"` with `null` players and exits 1, never "Online" with nobody on.

## Backups

```bash
scripts/backup.sh                                   # into ./backups, the newest 14 kept
scripts/restore.sh backups/terraria-20261025-043000.tar.gz
```

The archive holds the world and TShock's directory: `config.json`, and `tshock.sqlite`, the accounts, groups and bans. A restore of the world without that database lets every banned player back in, so `restore.sh` refuses an archive without it. The world is saved through REST first, and the save is waited for: TShock answers 200 when it has queued the save on the game's thread and writes the file a moment later, so `admin.sh save` returns only once the world file has changed and then stopped changing. The archive is the world as it is, not as the last autosave left it, and not half written. A backup is judged by what it holds: it is written as `.partial` and kept only once it is shown to contain both the world and the database. Archives are mode 600, because `config.json` holds the REST token.

**The world has to be the one the compose file names.** The server starts `/worlds/<TERRARIA_WORLD_FILE>.wld` with `-autocreate`, so a world under any other name is not an error to it: it generates a new world and starts, healthy, in it. `restore.sh` refuses an archive whose world is not the one `.env` names, and says which name to set. It moves what each volume holds into `.before-restore-<time>` inside that volume first, extracts, and compares every file at its live path with the archive by sha256. The server has to be stopped; it would write the world in its memory over the restored one on the way out.

The test restores into fresh volumes on a second project and port, starts it, and asks it: the same world, no world generated, and a ban made before the backup still listed.

## Updating

**The template:** the pin lives in the `x-images` block at the top of the compose file, as an interpolation default, and the `Dockerfile` builds from it on every `up` (from the layer cache when nothing moved), so a `git pull` delivers the image this repository has tested with no separate build to forget. The tag is TShock's release; the Terraria version it serves is in TShock's release notes. `./update.sh` moves to the latest release tag, refuses to cross a major unattended, and names any new required variable before anything has moved. A new TShock release changes the server under the people on it, so update when nobody is.

## Testing

`tests/e2e-game.sh` starts the real server from empty volumes through this compose file, on a CI runner, on every change and every day. It checks the process (uid 1000, no capabilities, no anonymous volume); the API (nothing on the host's 7878, published nowhere, `config.json` mode 600, a 48-character token found in neither `docker inspect` nor the log); the password from `.env` with a quote and a backslash in it; `status.sh`; the health check, never healthy while the world is generated, unhealthy when the server is frozen and healthy when it thaws; a 60-minute ban on Asia/Tokyo time ending in 60 minutes, and the same ban sent with a `Z` that does not; unban, a second unban refused, a kick of nobody refused, say, save; the backup's contents and mode; a stop that saves the world and exits 0, and the image's own entrypoint that exits 143 with the world file untouched; and a restore into fresh volumes, after two refusals that leave them empty, that comes back in the same world with its bans.

CI also lints the shell and the workflows, scans the pinned image with Trivy, and checks daily that the pin still resolves to what upstream publishes and is TShock's newest release.

## Supply chain trust

| Image | Source | Pinned |
|---|---|---|
| `ghcr.io/pryaxis/tshock` | [github.com/Pryaxis/TShock](https://github.com/Pryaxis/TShock), GPL-3.0, built by the project's own CI | tag and digest, in the compose file |
| `terraria-server-docker-compose:local` | `Dockerfile` here: the pin above, owned by uid 1000 | built from the pin on every `up` |

The scripts' helper containers are the local image too, so nothing else is pulled to touch the volumes. TShock is GPL-3.0 and is not copied into this repository; the template is MIT.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · CNCF Ambassador · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
