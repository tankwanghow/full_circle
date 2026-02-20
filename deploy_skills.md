# Deployment Skills

This file documents deployment processes and Cline commands for the Full Circle project.

## Deployment Overview

Full Circle uses Docker for containerization and deploys to Linode servers. The process involves building a Docker image, pushing to Docker Hub, and updating the remote server via SSH.

## Scripts in deploy_to_linode/

- `deploy.sh`: Main deployment script (build, push, remote update)
- `deploy_at_server.sh`: Runs on server to pull image and restart containers
- `setup_barebone_debian_at_server.sh`: Initial server setup (Debian, Docker, etc.)
- `setup_db_at_server.sh`: Database setup
- `setup_certbot_at_server.sh`: SSL certificate setup
- `setup_samba_share.sh`: Samba file sharing setup
- `generate_files_at_server.sh`: Generate config files on server
- `launch.sh`: Launch the app on server

## Deployment Steps

### Initial Server Setup (One-time)

1. Provision Linode server with Debian.
2. Run `setup_barebone_debian_at_server.sh` to install Docker, etc.
3. Run `setup_db_at_server.sh` for PostgreSQL.
4. Run `setup_certbot_at_server.sh` for SSL.
5. Run `generate_files_at_server.sh` to create docker-compose.yml, etc.

### Regular Deployment

1. **Prepare setup file**: Create a text file with variables:
   ```
   LINODE_IP=your.server.ip
   DOCKER_HUB_USERNAME=your_dockerhub_user
   IMAGE_NAME=full_circle
   DOCKER_CONTAINER_NAME=full_circle_app
   ```

2. **Run deployment**: Use `execute_command`:
   ```
   ./deploy_to_linode/deploy.sh path/to/setup_file.txt
   ```
   - Prompts for server password.
   - Builds Docker image locally.
   - Pushes to Docker Hub.
   - SSH to server, pulls image, docker compose down/up, runs migrations.

3. **Verify**: Check app loads at server URL.

## Cline Commands for Deployment

- **Deploy**: `execute_command` with `./deploy_to_linode/deploy.sh setup.txt`
- **Check server logs**: `execute_command` with `ssh root@server_ip "docker logs full_circle_app"`
- **Restart app**: `execute_command` with `ssh root@server_ip "docker compose -f /home/full_circle/docker-compose-full_circle.yml restart"`
- **Run migrations manually**: `execute_command` with `ssh root@server_ip "docker exec full_circle_app ./bin/migrate"`

## Troubleshooting

- If build fails: Check Dockerfile and assets build.
- If push fails: Verify Docker Hub credentials.
- If server update fails: Check SSH access and docker-compose.yml on server.
- Migrations fail: Check DB connection in prod config.

## Pre-deployment Checklist

- [ ] Code committed and pushed to git
- [ ] Tests pass: `mix test`
- [ ] Assets built: `mix assets.deploy`
- [ ] No credo issues: `mix credo`
- [ ] Setup file ready with correct vars
- [ ] Server accessible via SSH