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
| `deploy.sh` | Build image, stream to server, recreate container, migrate |
| `launch.sh` | First-time provision + deploy |
| `deploy_at_server.sh` | Pull/tag image, `docker compose` restart, migrate |
| `setup_barebone_debian_at_server.sh` | Docker, Nginx, PostgreSQL 17 |
| `setup_db_at_server.sh` | Database user/database |
| `setup_certbot_at_server.sh` | SSL via certbot |
| `setup_samba_share.sh` | Samba file sharing |
| `generate_files_at_server.sh` | docker-compose, env files on server |

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

## Troubleshooting

- **Build fails on assets** — run `~/Projects/elixir/.global_assets/setup.sh`
- **Wrong files in image** — confirm build context is the monorepo root, not `full_circle/` alone
- **Server update fails** — check SSH access and `docker-compose-*.yml` on the server
- **Migrations fail** — check `DATABASE_URL` in the container env

## Pre-deployment checklist

- [ ] Code committed
- [ ] `mix test` passes
- [ ] `mix precommit` or `mix credo` clean
- [ ] `deploy.conf` ready
- [ ] Server reachable via SSH