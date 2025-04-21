#!/bin/bash

# Variables (customize these as needed)
SHARE_NAME="shared"                   # Name of the Samba share
SHARE_PATH="/home/comp_doc"        # Path to the shared directory
GROUP_NAME="sambashare"               # Common group for Samba users
USERS=("kpstdocuser")       # Array of usernames
USER_PASSWORD="kpstdocuser"       # Default Linux password for users (change this or set manually)

# Ensure the script runs as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root (e.g., with sudo)."
    exit 1
fi

# Update package list and install Samba
echo "Installing Samba..."
apt update -y
apt install samba -y

# Create the shared directory
echo "Creating shared directory at $SHARE_PATH..."
mkdir -p "$SHARE_PATH"

# Create a group for Samba users
echo "Creating group $GROUP_NAME..."
groupadd "$GROUP_NAME"

# Set up users and add them to the group
for USER in "${USERS[@]}"; do
    echo "Creating user $USER..."
    # Add user with a default password (non-interactive)
    useradd -m -s /bin/bash -G "$GROUP_NAME" "$USER"
    echo "$USER:$USER_PASSWORD" | chpasswd
    
    # Add user to Samba and set a Samba password (same as Linux password here, adjust as needed)
    echo -e "$USER_PASSWORD\n$USER_PASSWORD" | smbpasswd -a "$USER"
    smbpasswd -e "$USER"  # Enable the Samba account
done

# Set permissions on the shared directory
echo "Setting permissions on $SHARE_PATH..."
chown :"$GROUP_NAME" "$SHARE_PATH"
chmod -R 775 "$SHARE_PATH"

# Configure Samba
echo "Configuring Samba..."
cat <<EOF >> /etc/samba/smb.conf
[$SHARE_NAME]
    path = $SHARE_PATH
    browsable = yes
    writable = yes
    read only = no
    valid users = $(echo "${USERS[@]}" | tr ' ' ',')
EOF

# Restart Samba services
echo "Restarting Samba services..."
systemctl restart smbd
systemctl restart nmbd

# Open firewall ports (if UFW is enabled)
if command -v ufw >/dev/null; then
    echo "Configuring firewall..."
    ufw allow 137,138/udp
    ufw allow 139,445/tcp
    ufw reload
fi

# Verify Samba status
echo "Checking Samba status..."
systemctl status smbd --no-pager
systemctl status nmbd --no-pager

echo "Samba setup complete!"
echo "Share is available at \\\\<linode-ip>\\$SHARE_NAME"
echo "Users: ${USERS[@]}"
echo "Test access with the default password: $USER_PASSWORD (change passwords with 'smbpasswd <username>')"