# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/heyvaldemar/terraria-server-docker-compose/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/heyvaldemar/terraria-server-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/terraria-server-docker-compose/releases/tag/v1.0.0
