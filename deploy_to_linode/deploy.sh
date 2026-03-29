#!/bin/bash
set -eo pipefail

# Path to your setup file
SETUP_FILE=$1

script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if the setup file exists
if [ ! -f "$SETUP_FILE" ]; then
    echo "Error: Setup file $SETUP_FILE not found."
    exit 1
fi

# Read and set variables from the setup file
while IFS='=' read -r key value
do
    # Ignore comments and empty lines
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ "$key" =~ ^[[:space:]]*$ ]] && continue

    # Remove leading and trailing whitespace from key and value
    key=$(echo $key | tr -d '[:space:]')
    value=$(echo $value | tr -d '[:space:]')

    # Set the variable in Bash's environment
    declare "$key=$value"
done < "$SETUP_FILE"

stty -echo
echo -n "Please enter password of the server: "
read LINODE_PWD
stty echo
echo

# Configuration
IMAGE_TAG="latest"
FULL_IMAGE="$DOCKER_HUB_USERNAME/$IMAGE_NAME:$IMAGE_TAG"

# Build Docker image
echo "Building Docker image... $script_path"
docker build --builder default -t $FULL_IMAGE -f $script_path/../Dockerfile $script_path/..

# Verify the new image was tagged correctly
NEW_IMAGE_ID=$(docker image inspect $FULL_IMAGE --format='{{.ID}}')
echo "Built image ID: $NEW_IMAGE_ID"

# Transfer image directly to server (skip Docker Hub)
IMAGE_SIZE=$(docker image inspect $FULL_IMAGE --format='{{.Size}}')
echo "Transferring image to server (~$(( IMAGE_SIZE / 1024 / 1024 )) MB uncompressed)..."
docker save $FULL_IMAGE | gzip | pv | sshpass -p $LINODE_PWD ssh -o StrictHostKeyChecking=no root@$LINODE_IP "gunzip | docker load"

# Restart containers and run migrations
sshpass -p $LINODE_PWD ssh root@$LINODE_IP "bash /home/$IMAGE_NAME/deploy_at_server.sh $IMAGE_NAME $DOCKER_HUB_USERNAME $DOCKER_CONTAINER_NAME $NEW_IMAGE_ID"
