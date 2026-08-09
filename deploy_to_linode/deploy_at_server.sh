#!/bin/bash

# Configuration
IMAGE_NAME=$1
IMAGE_TAG="latest"
DOCKER_HUB_USERNAME=$2
DOCKER_CONTAINER_NAME=$3
EXPECTED_IMAGE_ID=$4
GIT_SHA=$5
APP_COMPOSE="/home/$IMAGE_NAME/docker-compose-$IMAGE_NAME.yml"
FULL_IMAGE="$DOCKER_HUB_USERNAME/$IMAGE_NAME:$IMAGE_TAG"

# Ensure the loaded image has the correct tags
# After docker load, the new image may end up untagged if the tag was on a previous image
CURRENT_TAG_ID=$(docker image inspect $FULL_IMAGE --format='{{.ID}}' 2>/dev/null || echo "none")
if [ -n "$EXPECTED_IMAGE_ID" ] && [ "$CURRENT_TAG_ID" != "$EXPECTED_IMAGE_ID" ]; then
    echo "Tag '$FULL_IMAGE' points to $CURRENT_TAG_ID, expected $EXPECTED_IMAGE_ID. Re-tagging..."
    docker tag $EXPECTED_IMAGE_ID $FULL_IMAGE
fi

if [ -n "$GIT_SHA" ] && [ -n "$EXPECTED_IMAGE_ID" ]; then
    SHA_IMAGE="$DOCKER_HUB_USERNAME/$IMAGE_NAME:$GIT_SHA"
    docker tag $EXPECTED_IMAGE_ID $SHA_IMAGE
    echo "Tagged as: $SHA_IMAGE"
fi

# Verify the correct image is tagged before restarting
FINAL_ID=$(docker image inspect $FULL_IMAGE --format='{{.ID}}')
echo "Deploying image: $FULL_IMAGE ($FINAL_ID)"

# Restart container with the new image.
#
# Migrations run BEFORE the new container starts, in a one-off container built
# from the same image. Ecto selects every field a schema declares, so a release
# whose schemas name a column the database does not have yet fails every query
# against that table (42703, "column ... does not exist"). Starting the app
# first and migrating after leaves a window where it serves those errors, and
# with network_mode: host nginx is already forwarding to it. Migrate while
# nothing is listening instead.
echo "Updating container on Linode..."
docker compose -f $APP_COMPOSE down

echo "Running migration for $DOCKER_CONTAINER_NAME...."
if ! docker compose -f $APP_COMPOSE run --rm --no-deps \
    --name "${DOCKER_CONTAINER_NAME}_migrate" web /app/bin/migrate; then
    # Fail closed: a half-migrated database serving traffic is worse than being
    # down with a clear message. The previous release is still on the box.
    echo "" >&2
    echo "MIGRATION FAILED - the new container was NOT started." >&2
    echo "$DOCKER_CONTAINER_NAME is down. Fix the migration and re-run this script," >&2

    if [ -n "$CURRENT_TAG_ID" ] && [ "$CURRENT_TAG_ID" != "none" ] &&
        [ "$CURRENT_TAG_ID" != "$EXPECTED_IMAGE_ID" ]; then
        echo "or restore the previous release with:" >&2
        echo "  docker tag $CURRENT_TAG_ID $FULL_IMAGE" >&2
        echo "  docker compose -f $APP_COMPOSE up -d --force-recreate" >&2
    fi

    exit 1
fi

docker compose -f $APP_COMPOSE up -d --force-recreate

# Clean up dangling images
docker image prune -f
