#!/bin/bash

# Migrates 1 or more sites to a new server
# Usage: ./migrate-sites.sh --sites <sites_glob> --target <target_server> [--dry-run]
# Example: ./migrate-sites.sh --sites [a-c]*.com --target wp18.example.com
# Example: ./migrate-sites.sh --sites [a-c]*.com --target wp18.example.com --dry-run


source "$(dirname "$0")/../.env"

CF_TOKEN=${CLOUDFLARE_API_TOKEN}
CF_ACCOUNT_NUMBER=${CLOUDFLARE_ACCOUNT_NUMBER}

# Display usage if --help is provided or no parameters are supplied
function display_help() {
    echo "Usage: $0 --sites <sites_glob> --target <target_server> [--dry-run]"
    echo "
Parameters:
  --sites <sites_glob>       Set the glob pattern to match sites for migration (e.g. --sites [a-c]*.com)
  --target <target_server>   Set the target server IP or hostname to migrate sites (e.g. wp18.example.com).
  --dry-run                  Display a summary of sites to migrate without making any changes.
  --help                     Display this help message."
    exit 0
}

# Default to displaying help if no parameters are supplied
if [ $# -eq 0 ]; then
    display_help
fi

# Set default values for variables
SITES_GLOB=""
TARGET_SERVER=""
DRY_RUN=false

# Parse parameters
while [ "$1" != "" ]; do
    case $1 in
        --help)
            display_help
            ;;
        --sites)
            shift
            SITES_GLOB=$1
            ;;
        --target)
            shift
            TARGET_SERVER=$1
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        *)
            echo "Unknown parameter: $1"
            display_help
            ;;
    esac
    shift
done

# Check for mandatory parameters
if [ -z "$SITES_GLOB" ] || [ -z "$TARGET_SERVER" ]; then
    echo "Error: --sites and --target parameters are required."
    display_help
fi

# Dry run summary
if [ "$DRY_RUN" = true ]; then
    echo "Dry run summary:" 
    SITES_TO_MIGRATE=$(ls $DOMAIN_PATH/$SITES_GLOB 2>/dev/null)
    if [ -z "$SITES_TO_MIGRATE" ]; then
        echo "No sites found for the given glob pattern: $SITES_GLOB"
    else
        echo "Sites to migrate:"
        echo "$SITES_TO_MIGRATE"
        echo "Total count: $(echo "$SITES_TO_MIGRATE" | wc -l)"
    fi
    exit 0
fi

# Check SSH key and generate if not present
if [ ! -f ~/.ssh/id_ed25519.pub ]; then
    echo "SSH key not found. Generating a new SSH key..."
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
fi

# Loop through sites and perform migration
for SITE_TO_MIGRATE in $SITES_GLOB; do
    if [ ! -e $DOMAIN_PATH/$SITE_TO_MIGRATE ]; then
        echo "$SITE_TO_MIGRATE: does not exist in $DOMAIN_PATH/."
        continue
    fi

    DB=$(grep "  wp_" $DOMAIN_PATH/$SITE_TO_MIGRATE/docker-compose.yml | sed 's|[ :]||g')

    if [ -z "$DB" ]; then
        echo "Skipping $SITE_TO_MIGRATE: Database not found."
        continue
    fi

    echo "Migrating site: $SITE_TO_MIGRATE"

    # Check SSH access to target server
    ssh -q -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 root@$TARGET_SERVER exit
    if [ $? -ne 0 ]; then
        echo "Error: SSH access to $TARGET_SERVER is not available. Please add this key to the target server:"
        cat ~/.ssh/id_ed25519.pub
        exit 1
    fi

    # Dump the database
    echo "Dumping database: $DB"
    docker exec mysql mysqldump -p$MYSQL_PASS $DB > $DOMAIN_PATH/$SITE_TO_MIGRATE/www/wp-content/mysql.sql

    # Rsync site files to target server
    echo "Rsyncing files to target server: $TARGET_SERVER"
    rsync -azv $DOMAIN_PATH/$SITE_TO_MIGRATE root@$TARGET_SERVER:$DOMAIN_PATH/

    # Perform IP lookup for the domain's new host
    NEW_IP=$(dig +short $TARGET_SERVER)
    if [ -z "$NEW_IP" ]; then
        echo "Error: Could not determine new IP address for $TARGET_SERVER. Skipping DNS update."
        continue
    fi

    # Get the zone ID for the domain
    ZONE_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?account.id=$CF_ACCOUNT_NUMBER&name=$SITE_TO_MIGRATE" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json")
    ZONE_ID=$(echo $ZONE_RESPONSE | jq -r '.result[0].id')
    if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" == "null" ]; then
        echo "Error: Could not retrieve zone ID for $SITE_TO_MIGRATE. Skipping DNS update."
        continue
    fi

    # Get the record ID for the A record
    RECORD_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$SITE_TO_MIGRATE" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json")
    RECORD_ID=$(echo $RECORD_RESPONSE | jq -r '.result[0].id')
    if [ -z "$RECORD_ID" ] || [ "$RECORD_ID" == "null" ]; then
        echo "Error: Could not retrieve DNS record ID for $SITE_TO_MIGRATE. Skipping DNS update."
        continue
    fi

    # Update DNS via Cloudflare API
    echo "Updating DNS for $SITE_TO_MIGRATE to IP $NEW_IP via Cloudflare API..."
    RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" \
        --data '{"type":"A","name":"'$SITE_TO_MIGRATE'","content":"'$NEW_IP'","ttl":120,"proxied":false}')

    if [[ $(echo $RESPONSE | jq -r '.success') == "true" ]]; then
        echo "DNS update successful for $SITE_TO_MIGRATE."
        echo "Now hurry and connect to $TARGET_SERVER and run: cd $DOMAIN_PATH/$SITE_TO_MIGRATE && docker compose up -d"
    else
        echo "Error: DNS could not be automatically updated for $SITE_TO_MIGRATE. Response: $RESPONSE"
    fi

done
