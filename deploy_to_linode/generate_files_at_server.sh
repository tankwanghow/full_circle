#!/bin/bash

# Configuration
DB_NAME=$1
DB_USER=$2
DB_PWD=$3
PORT=$4
DOMAIN_NAME=$5
IMAGE_NAME=$6
DOCKER_HUB_USERNAME=$7
DOCKER_CONTAINER_NAME=$8
MAIL_HOST=$9
MAIL_PORT=${10}
MAIL_USERNAME=${11}
MAIL_PASSWORD=${12}
MAIL_FROM=${13}
APP_COMPOSE="/home/$IMAGE_NAME/docker-compose-$IMAGE_NAME.yml"
NGINX_CONF="${IMAGE_NAME}-nginx.conf"
SECRET_KEY_BASE=${14}

if [ -z "$SECRET_KEY_BASE" ]; then
    echo "Error: SECRET_KEY_BASE not supplied." >&2
    echo "Add it to deploy.conf; the live value is in $APP_COMPOSE on the server." >&2
    exit 1
fi

echo "Creating ${APP_COMPOSE} file..."
cat << EOF > $APP_COMPOSE
services:
  web:
    image: ${DOCKER_HUB_USERNAME}/${IMAGE_NAME}:latest
    container_name: ${DOCKER_CONTAINER_NAME}
    volumes:
      - /home/${IMAGE_NAME}/uploads:/app/uploads
    environment:
      - DATABASE_URL=postgres://${DB_USER}:${DB_PWD}@localhost:5432/${DB_NAME}
      - DATABASE_QUERY_URL=postgres://${DB_USER}_query:${DB_PWD}@localhost:5432/${DB_NAME}
      - SECRET_KEY_BASE=${SECRET_KEY_BASE}
      - PHX_HOST=${DOMAIN_NAME}
      - MIX_ENV=prod
      - PORT=$PORT
      - MAIL_HOST=${MAIL_HOST}
      - MAIL_PORT=${MAIL_PORT}
      - MAIL_USERNAME=${MAIL_USERNAME}
      - MAIL_PASSWORD=${MAIL_PASSWORD}
      - MAIL_FROM=${MAIL_FROM}
      - UPLOADS_DIR=/app/uploads
    network_mode: host
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

echo "Creating Nginx conf file for ${DOMAIN_NAME}..."
cat << EOF > /etc/nginx/sites-available/${NGINX_CONF}
# /etc/nginx/sites-available/${NGINX_CONF}

map \$http_upgrade \$${IMAGE_NAME}_connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN_NAME} www.${DOMAIN_NAME};

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN_NAME} www.${DOMAIN_NAME};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf; # Managed by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # Managed by Certbot

    # Allow large uploads (PDFs etc.); nginx default is only 1 MB.
    client_max_body_size 50M;

    location / {
        proxy_pass http://localhost:$PORT; # ${IMAGE_NAME} container uses host network

        # The whole response header block must fit in ONE proxy buffer, and the
        # default is a single 4k page. Phoenix signs its session into a cookie
        # that Plug allows up to 4096 bytes on its own, so a large session put
        # the header over the line and nginx answered 502 while the app was
        # returning 200. Give the header room rather than relying on the
        # session staying small.
        proxy_buffer_size 16k;
        proxy_buffers 8 16k;
        proxy_busy_buffers_size 32k;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$${IMAGE_NAME}_connection_upgrade;

        # Must exceed the app's own query timeout, or nginx abandons a slow
        # report as a 504 while the query keeps holding a pool connection.
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }
}
EOF
ln -sf /etc/nginx/sites-available/${NGINX_CONF} /etc/nginx/sites-enabled/