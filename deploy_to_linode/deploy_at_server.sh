#!/bin/bash

# Configuration
IMAGE_NAME=$1
IMAGE_TAG="latest"
DOCKER_HUB_USERNAME=$2
DOCKER_CONTAINER_NAME=$3
APP_COMPOSE="/home/$IMAGE_NAME/docker-compose-$IMAGE_NAME.yml"

# SSH into Linode and pull & run the Docker image
echo "Instructing Linode to pull and run the new image..."
echo "Updating container on Linode..."
docker pull $DOCKER_HUB_USERNAME/$IMAGE_NAME:$IMAGE_TAG
docker compose -f $APP_COMPOSE down
docker compose -f $APP_COMPOSE up -d
echo "Running migration for $DOCKER_CONTAINER_NAME...."
docker exec $DOCKER_CONTAINER_NAME ./bin/migrate
