#!/bin/bash
set -e

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

# Build Docker image
echo "Building Docker image... $script_path"
docker build -t $DOCKER_HUB_USERNAME/$IMAGE_NAME:$IMAGE_TAG -f $script_path/../Dockerfile $script_path/..

# Push the Docker image to Docker Hub
echo "Pushing image to Docker Hub..."
docker push $DOCKER_HUB_USERNAME/$IMAGE_NAME:$IMAGE_TAG

sshpass -p $LINODE_PWD ssh root@$LINODE_IP  "bash /home/$IMAGE_NAME/deploy_at_server.sh $IMAGE_NAME $DOCKER_HUB_USERNAME $DOCKER_CONTAINER_NAME"