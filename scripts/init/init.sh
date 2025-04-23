#!/bin/bash
# 
# Initial setup script for the server.
# 
# TODO: Variablize the directories and paths used in this script.

source "$(dirname "$0")/../.env"

apt-get update
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |   sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
apt-get install -y unzip
touch $DOMAIN_PATH/traefik/acme.json
chmod 600 $DOMAIN_PATH/traefik/acme.json
echo "alias dc='docker compose'" >> /root/.bashrc
sed -i "s/wp0.ciwgserver.com/$(hostname).ciwgserver.com/g" $DOMAIN_PATH/traefik/docker-compose.yml

# Start the services
cd $DOMAIN_PATH/traefik && docker compose up -d
cd $DOMAIN_PATH/mysql && docker compose up -d
cd $DOMAIN_PATH/wordpress-manager && docker compose up -d
cd $DOMAIN_PATH/cache && docker compose up -d
rm $DOMAIN_PATH/sync-server.sh

# Prepare for WordPress sites
docker pull $REGISTRY_URL/advanced-wordpress:latest