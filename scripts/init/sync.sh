#!/bin/bash

# sync.sh

# This script synchronizes files and directories from the local server to a remote server to prepare for a new WordPress installation.
# It uses rsync to transfer files and directories, excluding certain patterns.
# The script requires the user to provide a host as an argument.

# Usage: ./sync.sh <host>
# Example: ./sync.sh wp125.example.com

source "$(dirname "$0")/../.env"

HOST=$1

rsync -azv /root/.docker/config.json root@$HOST:/root/.docker/
rsync -azv /root/.ssh/authorized_keys root@$HOST:/root/.ssh/
rsync -azv /var/opt/new-site.sh root@$HOST:/var/opt/
rsync -azv /var/opt/migrate.sh root@$HOST:/var/opt/
rsync -azv /var/opt/init-server.sh root@$HOST:/var/opt/
rsync -azv /var/opt/restart-all-wordpress-services.sh root@$HOST:/var/opt/
rsync -azv /var/opt/traefik --exclude acme.json root@$HOST:/var/opt/
rsync -azv /var/opt/mysql --exclude data root@$HOST:/var/opt/
rsync -azv /var/opt/shared --exclude data root@$HOST:/var/opt/
rsync -azv /var/opt/cache --exclude redis_data root@$HOST:/var/opt/
rsync -azv /var/opt/wordpress-manager --exclude log root@$HOST:/var/opt/
rsync -azv /var/opt/.skel root@$HOST:/var/opt/
scp /root/.vimrc root@$HOST:/root/