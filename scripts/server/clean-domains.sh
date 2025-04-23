#!/bin/bash
#
# clean-domains.sh
#
# This script cleans up WordPress installations that are no longer hosted on the server.
# It checks each directory in the current path, and if it matches a domain format,
# it verifies if the domain is hosted on the server. If not, it stops and removes
# the Docker container, drops the MySQL database and user, and removes the directory.
# It also supports a dry-run mode to simulate the actions without executing them.
# 
# Usage: ./clean-domains.sh [--dry-run]

# TODO: Perform backup of the database and files before deletion
# TODO: Add S3 upload functionality for the backup

source "$(dirname "$0")/../.env"

# Automatically get the public IP of the server
LOCAL_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip)  # Fetches the public IP
MYSQL_PASS=$MYSQL_ROOT_PASSWORD  # MySQL root password from .env
DRY_RUN=false

# Check if --dry-run is set
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "Running in dry-run mode. No actions will be executed."
fi

# Loop through each directory that appears to be a domain format
for DOMAIN_DIR in *; do

    # Only proceed if the directory name looks like a domain
    if [[ "$DOMAIN_DIR" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]+$ ]]; then

        # Remove the TLD for Docker container and DB/user names
        DOMAIN="${DOMAIN_DIR%%.*}"
        CONTAINER_NAME="wp_${DOMAIN}"

        # Get IP for the domain
        DOMAIN_IP=$(dig +short "$DOMAIN_DIR" | head -n 1)
  
        # Check if the domain is hosted on this server
        if [[ "$DOMAIN_IP" != "$LOCAL_IP" && -n "$DOMAIN_IP" ]]; then
            echo "Domain $DOMAIN_DIR is not hosted on this server (IP: $DOMAIN_IP). Proceeding with cleanup..."

            # Commands for cleanup
            STOP_CONTAINER="docker stop $CONTAINER_NAME"
            REMOVE_CONTAINER="docker rm $CONTAINER_NAME"
            DROP_DATABASE="docker exec mysql mysql -p${MYSQL_PASS} -e \"DROP DATABASE IF EXISTS wp_${DOMAIN}\""
            DROP_USER="docker exec mysql mysql -p${MYSQL_PASS} -e \"DROP USER IF EXISTS '${DOMAIN}'@'%'\""
            REMOVE_DIRECTORY="rm -rf $DOMAIN_PATH/$DOMAIN_DIR"

            # Execute or simulate each command based on dry-run
            if $DRY_RUN; then
                echo "[DRY RUN] $STOP_CONTAINER"
                echo "[DRY RUN] $REMOVE_CONTAINER"
                echo "[DRY RUN] $DROP_DATABASE"
                echo "[DRY RUN] $DROP_USER"
                echo "[DRY RUN] $REMOVE_DIRECTORY"
            else
                # Stop and remove the docker container
                eval $STOP_CONTAINER && eval $REMOVE_CONTAINER
                # Drop the database and user in MySQL
                eval $DROP_DATABASE && eval $DROP_USER
                # Remove the directory
                eval $REMOVE_DIRECTORY
                echo "Cleanup completed for $DOMAIN_DIR"
            fi
        else
            echo "Domain $DOMAIN_DIR is hosted on this server or not resolvable. Skipping..."
        fi
    else
        echo "Skipping $DOMAIN_DIR: Not in domain format."
    fi
done

echo "Script execution completed."