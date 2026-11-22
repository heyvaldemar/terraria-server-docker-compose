# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **The secret probe no longer fails when a process ends while it reads the container.** `tests/secret-probe.sh` read each process's command line in a loop that ended on the status of its last test, so a short-lived process last in glob order and gone by the read failed the whole container as unreadable, while an unreadable process anywhere else passed. Now a process gone by the read is not counted, every process still there must be read, and a container that cannot be entered or has nothing to read still fails. Found on the HumanitZ template, where it turned a digest refresh red; against a container starting processes in a loop the old loop failed 170 of 200 reads there and the new one none ([heyvaldemar/humanitz-server-docker-compose#3](https://github.com/heyvaldemar/humanitz-server-docker-compose/pull/3)). CI only; nothing a deployment runs changes.

## [1.3.0] - 2026-11-14

### Security

- **The guard's webhook address is no longer on a command line.** `scripts/guard.sh` gave curl the address as an argument, where every process on the host could read it in `ps` for as long as curl ran, and an incoming webhook's address is its key. curl reads it from stdin now (`--config -`), the message from a file of its own. `tests/e2e-game.sh` posts to a listener on the runner and checks the address was not among curl's arguments.
- **CI looks for the join password everywhere it could leak to.** `tests/secret-probe.sh`, with the password `.env` sets (a quote and a backslash in it): it fails on it in `docker compose logs`, any command line in the container or the host's `ps`, after the first start, across the backup, after the guard's restart and after a crash, and the test reads TShock's own logs as uid 1000 for it too; it names the place, never the value. It found nothing ([run 43623760207](https://github.com/heyvaldemar/terraria-server-docker-compose/actions/runs/43623760207)).

### Added

- **A crash is said by the guard.** When TShock exits, `start.sh` exits with its status, Docker starts the container again, and the health check is green with the fresh one. The guard now writes down Docker's restart count every minute and says a restart once, through the webhook too, with the exit code and the reason from Docker's die and oom events; a 137 whose oom event Docker has not stored yet is read again for up to ten seconds; three in a day exit 1. CI kills TShock with SIGKILL and needs the guard to say it once.
- **A stop is measured.** `tests/clean-stop.sh` in `tests/e2e-game.sh`: a second of the 60-second grace period, exit 0, TShock's "Saving before exit".

### Fixed

- **An index pushed again over the same build is no longer reported as drift.** The daily pin check compared each pin with the digest the tag's index has now and failed on any difference, so a publisher re-pushing the index over the very same images (a platform added, an attestation rewritten) turned it red for an image nobody rebuilt, and no pin would ever move to turn it green. It now also compares the linux/amd64 build under both digests, the one CI runs and proves: the same build passes with a notice naming both digests, a new build fails as drift exactly as before, and a build that cannot be read still fails.

### Changed

- **Helper containers take their values by name.** The backup helper was started with `-e OWNER=…`, the restore helpers with `-e STAMP=…` and `-e FILE=…`. None of them is a secret, but fleet conformance now flags any value expanded into `-e NAME=` (a name says nothing about what it carries), so each is set for that one command and passed as `-e NAME`. Nothing a deployment does changes.

## [1.2.4] - 2026-11-08

### Changed

- **The README says why the health check never speaks the game protocol.** Measured on 2026-11-08 against TShock 6.2.1: a ConnectRequest is answered in 50 ms, and every one writes "is connecting" and "was booted" to the log and makes the server save and back up the world. The check stays the game port's LISTEN state in `/proc/net/tcp` and REST `/status`, and the README now also says it asks from inside the container, so it does not prove the port is published on the host or open in a firewall.
## [1.2.3] - 2026-11-02

### Fixed

- **A container stopping under the port check no longer reads as a closed port.** `scripts/listening.sh` took "closed" from the exit code of `docker compose exec`, and with Compose 5.5.1 a container that stops between its running check and the exec makes the exec itself end with 1 ('service "terraria-server" is not running'), the same 1 a grep that found nothing gives. `status.sh` then showed "Not accepting players" and the guard started its closed-port clock on a Docker failure. The container now prints `listening` or `closed`, and only that word from an exec that ended with 0 is an answer; anything else is "cannot ask". On the server this template comes from, a chat bot read a Docker error on stdout as part of a game's log. `tests/docker-failure.sh` plays the measured shapes (exit 1, 128 with "cannot exec in a stopped state" on stdout, 137, 126) through a fake `docker`.

## [1.2.2] - 2026-11-01

### Changed

- **`tests/timers.sh` checks the fall-back on Berlin time (2026-10-25).** Any zone with a fall-back shows the same skip; the timers themselves are unchanged.

## [1.2.1] - 2026-11-01

### Fixed

- **The timers keep running the night the clocks go back.** `terraria-guard.timer` (`*:*:30`) was a local-time calendar, and the night the clocks went back, the server this template comes from ran none of its local-time timers for an hour: systemd took the repeated hour as already gone. They are now in UTC, with an `OnUnitActiveSec` net a little longer than the period and `AccuracySec=1s`. `tests/timers.sh` reproduces a fall-back night with `systemd-analyze` and fails on a local-time calendar. Reinstall the units after updating: `sudo cp systemd/*.timer /etc/systemd/system/ && sudo systemctl daemon-reload`.

## [1.2.0] - 2026-10-27

### Changed

- **The player cap and the reserve are written into `config.json` on every start, and the reserve is now every slot Terraria has left.** TShock 6.2.1 sizes the network slots from the file (`MaxSlots` + `ReservedSlots`), and the `-maxplayers` flag this template passed changed `MaxSlots` in memory only: a `/reload` put the cap back to whatever the file said, TShock's own 8 unless edited, and the network slots stayed at 8 + 20 = 28 whatever `TERRARIA_MAX_PLAYERS` was. `scripts/start.sh` now writes `MaxSlots` from `TERRARIA_MAX_PLAYERS` (8) and `ReservedSlots` from the new `TERRARIA_RESERVED_SLOTS`, by default 255 minus the cap, and the compose file passes no `-maxplayers`. It takes 255 silent connections to close the game port instead of 28. A value outside 1-255, or a cap and reserve past 255 together, stops the start with its name. **Upgrade note:** a `MaxSlots` or `ReservedSlots` edited by hand in `config.json` is overwritten on the next start; set them in `.env`.
- **The README records the guard's first catch in the wild.** On the server this template comes from, scanners filled the slots again about twenty hours after `scripts/guard.sh` went in; it waited its two minutes, found nobody playing, saved, restarted, and the port listened again in five seconds.

### Fixed

- **The test's check of the restored server asked the first server's port.** It passed on the world name alone while `status.sh`, asking 17777 of a server on 17778, said "Not accepting players". It now asks 17778 and needs Online.

### Added

- **Housekeeping in `scripts/guard.sh`: an empty server that has been up 12 hours and holds dead connections is restarted before they close the port.** A larger reserve only moves the day the port closes, and that day may have players on, when nothing may be done until they leave. So a server that still listens, has nobody on and holds at least one connection in CLOSE_WAIT on the game port is saved and restarted after `TERRARIA_GUARD_HOUSEKEEP_AFTER` (12 hours) up, in the log and not the webhook. It does nothing when the player count, the dead connections or the uptime cannot be read, and it counts against the same six restarts in 24 hours.
- **`tests/read-whole.sh`: every script is read whole before it runs.** bash reads a script as it executes it, from the same byte offset in whatever the file holds by then; on the server this template comes from, the timer started the guard while its file was being edited in place, and the run died on a syntax error. Every script in `scripts/` is now one brace group ending in `exit`. The test checks the shape of each, and rewrites the guard's file in place under a running copy: wrapped, it finishes as it started; unwrapped, it runs the new text.

## [1.1.0] - 2026-10-25

### Added

- **`scripts/guard.sh`, with `systemd/terraria-guard.timer` every minute: a server whose game port stopped listening is restarted, while nobody is on.** Terraria gives every accepted TCP connection a slot and stops listening when none is free, and a connection that never speaks the game's protocol is never released (Pryaxis/TShock#1023, open at the API layer since 2016). Internet scanners do exactly that: on the server this template comes from, nobody could join while the process ran, REST answered and the status page said Online. Here, 28 silent connections close the port. The guard acts after two minutes closed, does nothing when the player count cannot be read, warns once and waits when players are on, stops after six restarts in 24 hours, and otherwise saves, restarts and proves the port listens again, in about five seconds. `TERRARIA_GUARD_WEBHOOK` reports each action to Mattermost or Slack.
- **`scripts/listening.sh`**: whether the game port is in LISTEN, read from the container's `/proc/net/tcp`. Never by connecting: a probe that connects takes a slot, and is the fault it would look for.

### Fixed

- **`scripts/status.sh` said Online while nobody could join.** It read TShock's REST API, which answers on its own thread while the game port is closed. Online now needs the port in LISTEN too; a server that answers and does not listen is "Not accepting players", exit 1. The health check already read the port and went red.

## [1.0.0] - 2026-10-25

### Added

- **A Terraria server on TShock 6.2.1 (Terraria 1.4.5.8), from TShock's own image**, `ghcr.io/pryaxis/tshock`, pinned by tag and digest, with one local layer that makes it run as uid 1000. Every capability dropped, `no-new-privileges`, the game on 7777/TCP and nothing else published.
- **`scripts/start.sh`, the entrypoint, for the way out.** TShock does not save on SIGTERM: run as the image runs it, a stop ended it in under a second, exit 143, with the world on disk as the last autosave left it. The script turns the signal into TShock's `off`, which saves and exits 0. It also turns the REST API on with a token it makes inside the container, and writes the password from `.env` into `config.json` on every start.
- **The REST API published nowhere, its token in nothing readable.** `scripts/rest.sh` calls it from inside the container over bash's `/dev/tcp`, since the image has no curl. The token lives in `config.json`, mode 600, and appears in no environment variable, command line or log.
- **A health check that needs the game listening and REST answering.** REST answers while a world is still being generated (98 seconds of a large world's first start, measured), and a frozen server keeps its process and its socket, so either question alone passes for a server nobody can use.
- **`scripts/admin.sh`: who, kick, ban, unban, bans, say, save.** `save` waits until the world file is written, since TShock answers 200 when it has queued the save, not when it is done. A ban is checked in the ban list, since TShock 6.2.1's create call writes the ban and then answers 500; a timed ban's end is sent as UTC with no `Z`, since TShock reads a `Z` as local time and the ban ends hours off.
- **`scripts/status.sh`**, one line of JSON, and `"Unknown"` with exit 1 when TShock does not answer, never "Online" with nobody on.
- **`scripts/backup.sh` and `scripts/restore.sh`.** The world and the account and ban database, saved first, kept only once the archive is shown to hold both, mode 600. A restore refuses an archive without the database or under another world's name than the compose file starts, sets aside what was there, and compares every file at its live path by sha256.
- **`tests/e2e-game.sh`, the real server in CI** from empty volumes, every claim above checked against it, the "without this" ones both ways.

[Unreleased]: https://github.com/heyvaldemar/terraria-server-docker-compose/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/heyvaldemar/terraria-server-docker-compose/compare/v1.2.4...v1.3.0
[1.2.4]: https://github.com/heyvaldemar/terraria-server-docker-compose/compare/v1.2.3...v1.2.4
[1.2.3]: https://github.com/heyvaldemar/terraria-server-docker-compose/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/heyvaldemar/terraria-server-docker-compose/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/heyvaldemar/terraria-server-docker-compose/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/heyvaldemar/terraria-server-docker-compose/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/terraria-server-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/terraria-server-docker-compose/releases/tag/v1.0.0
