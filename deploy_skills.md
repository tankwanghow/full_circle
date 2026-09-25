# Deployment Skills

Deployment guide for Full Circle on Linode. For shared monorepo asset tooling, see
`~/Projects/elixir/shared_config/WORKSPACE_ASSETS.md`.

## Overview

Full Circle uses a two-stage `Dockerfile` Mix release deployed to Debian/Linode. Images are
built on the dev machine and streamed to the server over SSH (no Docker Hub push required).

## Prerequisites

```bash
# Once per machine (monorepo root)
~/Projects/elixir/.global_assets/setup.sh
```

## Scripts in `deploy_to_linode/`

| Script | Purpose |
|---|---|
| `deploy.sh` | Build image, stream to server, migrate, recreate container |
| `launch.sh` | First-time provision + deploy |
| `deploy_at_server.sh` | Pull/tag image, `compose down`, migrate in a one-off container, `compose up`. Migrating before start avoids serving a release whose schemas name columns the DB lacks; a failed migration aborts the deploy and leaves the app down with a rollback command rather than starting it. |
| `setup_barebone_debian_at_server.sh` | Docker, Nginx, PostgreSQL 17 |
| `setup_db_at_server.sh` | Database user/database |
| `setup_certbot_at_server.sh` | SSL via certbot |
| `setup_samba_share.sh` | Samba file sharing |
| `generate_files_at_server.sh` | docker-compose + the site's nginx conf. **Only `launch.sh` runs this — `deploy.sh` never does.** |

## Regular deployment

1. Prepare `deploy.conf` (gitignored) with `LINODE_IP`, `DOCKER_HUB_USERNAME`, `IMAGE_NAME`,
   `DOCKER_CONTAINER_NAME`, etc.

2. Deploy:

   ```bash
   ./deploy_to_linode/deploy.sh deploy.conf
   ```

   The script sources `shared_config/docker_deploy.sh`, ensures global assets exist, stages
   `full_circle/.dockerignore` at the monorepo root, and runs:

   ```bash
   docker build -f full_circle/Dockerfile ~/Projects/elixir/
   ```

3. Verify the app loads at the server URL.

## Infrastructure changes do NOT ship with a deploy

`deploy.sh` builds the image and calls `deploy_at_server.sh`. That is all. It never
runs `generate_files_at_server.sh`, so editing that script changes **nothing** on a
normal deploy — the server keeps the `docker-compose-*.yml` and
`/etc/nginx/sites-available/<image>-nginx.conf` it was last provisioned with.

So a change to the compose file (env vars, `restart:`, volumes) or to the nginx conf
(buffers, timeouts, headers) needs one of:

- **apply it by hand on the server**, then `docker compose up -d --force-recreate` for
  compose changes or `nginx -t && systemctl reload nginx` for nginx ones; or
- **re-run `launch.sh`** — but that also re-runs the Debian, database and certbot setup,
  so it is a provisioning tool, not a config-push tool. Not something to reach for
  mid-incident.

Edit `generate_files_at_server.sh` as well, or the next re-provision silently reverts
whatever you applied by hand.

A worked example: the 2026-09-22 `502 Bad Gateway` outage was fixed by raising nginx's
`proxy_buffer_size` on the server by hand. The matching change to the generator was
committed in the same session, but it did not reach production until someone applied it
— and would not have, however many times the app was deployed.

## Troubleshooting

- **Build fails on assets** — run `~/Projects/elixir/.global_assets/setup.sh`
- **Wrong files in image** — confirm build context is the monorepo root, not `full_circle/` alone
- **Server update fails** — check SSH access and `docker-compose-*.yml` on the server
- **A config change had no effect** — see "Infrastructure changes do NOT ship with a deploy" above
- **502 with a healthy app** (`Sent 200` in the app log, `upstream sent too big header`
  in `/var/log/nginx/error.log`) — the response header block exceeded nginx's
  `proxy_buffer_size`. Usually an oversized session cookie; see the `pl-forecast-model` skill
- **Migrations fail** — check `DATABASE_URL` in the container env

## Pre-deployment checklist

- [ ] Code committed
- [ ] `mix test` passes
- [ ] `mix precommit` or `mix credo` clean (note: Credo may be absent from deps — verify before requiring it)
- [ ] `deploy.conf` ready
- [ ] Server reachable via SSH

## Related ops scripts (repo root `scripts/`)

| Script | Purpose |
|---|---|
| `scripts/restore_backup.sh` | Drop/recreate local `full_circle_dev`, restore a `pg_dump -Ft` archive, optionally `mix ecto.migrate`. Prefer this over `pg_restore -c` when local has tables newer than the dump (e.g. `trading_*`). |
| `deploy_to_linode/backup_db.sh` | Prod nightly backup (root crontab `0 13 * * *`, installed as `/usr/local/bin/fullcircle_backup_db.sh`). Dumps to `.partial`, verifies with `pg_restore -l`, keeps newest 14 + first-of-month ×12 in `monthly/`, optional `RCLONE_REMOTE` off-site copy. Password from `/root/.pgpass`. Log: `db_backup/backup.log`. Install steps in the script header. |

Cert renewal is the `certbot.timer` systemd unit — there is no certbot crontab line (the old one in root's crontab never ran and was removed 2026-09-25).
