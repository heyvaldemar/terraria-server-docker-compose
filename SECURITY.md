# Security Policy

## Supported versions

| Version                                        | Status             |
|------------------------------------------------|--------------------|
| Current `main` and the latest tagged release   | :white_check_mark: |
| Older tags without a recent rebuild            | :x:                |

Fixes land on `main` and ship as a new tag; older tags are not patched in place.

## Reporting a vulnerability

Report privately through GitHub: **Security → Report a vulnerability** on this repository, or by email to v@valdemar.ai. The process is described at [heyvaldemar.com/security](https://heyvaldemar.com/security/).

You can expect an acknowledgment within 7 days. This project does not operate a bounty program; researchers who submit valid, responsibly disclosed reports receive public credit in the release notes and the changelog.

Please do not open public GitHub issues for security reports.

## Supply chain trust

This repository publishes a deployment template, not a custom software distribution. The upstream image, TShock's own `ghcr.io/pryaxis/tshock`, is pinned by `tag@sha256:<digest>` as an interpolation default in the compose file's `x-images` block, so a plain `git pull` delivers the exact combination this repository has tested. The one local layer on top of it (`Dockerfile`) changes file ownership so the server runs as uid 1000, and builds `FROM` that same pin. The Pin Freshness workflow re-resolves the pin daily and fails when it has drifted or a newer release exists; the Deployment Verification workflow scans the pinned image and runs the real server, from empty volumes, on every change. Either one notifies the maintainer. GitHub Actions are pinned by commit SHA.

## Credentials

`.env` is gitignored and holds one secret at most, the optional server password. The REST API token is not in `.env` at all: `scripts/start.sh` makes it inside the container on the first start and keeps it in `config.json`, mode 600, in a volume; `scripts/rest.sh` reads and uses it inside the container. It never appears in an environment variable, a command line or a log, and `tests/e2e-game.sh` checks that on every run. The REST API is published on no port. Backup archives hold `config.json` and are written mode 600. This repository has never tracked a credential.
