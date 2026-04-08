#!/bin/bash
set -e

# Path to your setup file
SETUP_FILE=$1

script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRC_SETUP_SRV="${script_path}/setup_barebone_debian_at_server.sh"
SRC_SETUP_DB="${script_path}/setup_db_at_server.sh"
SRC_SETUP_CERTBOT="${script_path}/setup_certbot_at_server.sh"
SRC_GEN_FILE="${script_path}/generate_files_at_server.sh"
SRC_DEPLOY_FILE="${script_path}/deploy_at_server.sh"

SETUP_SRV="setup_barebone_debian_at_server.sh"
SETUP_DB="setup_db_at_server.sh"
SETUP_CERTBOT="setup_certbot_at_server.sh"
GEN_FILE="generate_files_at_server.sh"
DEPLOY_FILE="deploy_at_server.sh"

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
    echo "$key -> $value"

    # Set the variable in Bash's environment
    declare "$key=$value"
done < "$SETUP_FILE"

stty -echo
echo -n "Please enter password of the server: "
read LINODE_PWD
stty echo
echo

stty -echo
echo -n "Please enter password for '$DB_USER': "
read DB_PWD
stty echo
echo

# copy script to server
sshpass -p $LINODE_PWD ssh root@$LINODE_IP << EOF
if [ ! -d "/home/${IMAGE_NAME}" ]; then
    # If it doesn't exist, create it
    mkdir -p "/home/${IMAGE_NAME}"
    echo "Directory created: /home/${IMAGE_NAME}"
else 
    echo "Directory already exists: /home/${IMAGE_NAME}"
fi
if [ ! -d "/home/${IMAGE_NAME}/files" ]; then
    # If it doesn't exist, create it
    mkdir -p "/home/${IMAGE_NAME}/files"
    echo "Directory created: /home/${IMAGE_NAME}/files"
else 
    echo "Directory already exists: /home/${IMAGE_NAME}/files"
fi
EOF

sshpass -p $LINODE_PWD scp $SRC_SETUP_SRV $SRC_SETUP_DB $SRC_SETUP_CERTBOT $SRC_GEN_FILE $SRC_DEPLOY_FILE root@$LINODE_IP:/home/${IMAGE_NAME}

sshpass -p $LINODE_PWD ssh root@$LINODE_IP "bash /home/${IMAGE_NAME}/$SETUP_SRV"

sshpass -p $LINODE_PWD ssh root@$LINODE_IP "bash /home/${IMAGE_NAME}/$SETUP_DB $DB_NAME $DB_USER $DB_PWD"

sshpass -p $LINODE_PWD ssh root@$LINODE_IP "bash /home/${IMAGE_NAME}/$SETUP_CERTBOT $DOMAIN_NAME"

sshpass -p $LINODE_PWD ssh root@$LINODE_IP "bash /home/${IMAGE_NAME}/$GEN_FILE $DB_NAME $DB_USER $DB_PWD $PORT $DOMAIN_NAME $IMAGE_NAME $DOCKER_HUB_USERNAME $DOCKER_CONTAINER_NAME"

IMAGE_TAG="latest"
GIT_SHA=$(git -C "$script_path/.." rev-parse --short HEAD)
FULL_IMAGE="$DOCKER_HUB_USERNAME/$IMAGE_NAME:$IMAGE_TAG"
SHA_IMAGE="$DOCKER_HUB_USERNAME/$IMAGE_NAME:$GIT_SHA"

# Build Docker image
echo "Building Docker image..."
docker build --builder default -t $FULL_IMAGE -t $SHA_IMAGE -f $script_path/../Dockerfile $script_path/..

# Verify the new image was tagged correctly
NEW_IMAGE_ID=$(docker image inspect $FULL_IMAGE --format='{{.ID}}')
echo "Built image ID: $NEW_IMAGE_ID"

# Transfer image directly to server (skip Docker Hub)
IMAGE_SIZE=$(docker image inspect $FULL_IMAGE --format='{{.Size}}')
echo "Transferring image to server (~$(( IMAGE_SIZE / 1024 / 1024 )) MB uncompressed)..."
echo "Image tagged as: $IMAGE_TAG and $GIT_SHA"
docker save $FULL_IMAGE $SHA_IMAGE | gzip | pv | sshpass -p $LINODE_PWD ssh -o StrictHostKeyChecking=no root@$LINODE_IP "gunzip | docker load"

# Restart containers and run migrations
sshpass -p $LINODE_PWD ssh root@$LINODE_IP "bash /home/${IMAGE_NAME}/deploy_at_server.sh $IMAGE_NAME $DOCKER_HUB_USERNAME $DOCKER_CONTAINER_NAME $NEW_IMAGE_ID $GIT_SHA"