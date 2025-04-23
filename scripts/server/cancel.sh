#!/bin/bash

source "$(dirname "$0")/../.env"

# Colors for messages
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No color

# Function to display help
show_help() {
  echo "Usage: $0 <domain> [NEW_ADMIN_EMAIL] [--help]"
  echo
  echo "Script to cancel a WordPress site by deactivating plugins, removing license keys,"
  echo "exporting the database, and archiving the site directory."
  echo
  echo "Arguments:"
  echo "  <domain>            The base domain name of the WordPress site (e.g., example.com)."
  echo "  NEW_ADMIN_EMAIL     (Optional) The new email address to set for 'admin_email'."
  echo
  echo "Options:"
  echo "  --help              Display this help message."
  echo
}


# Check for --help flag
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
  show_help
  exit 0
fi  

# Validate domain parameter
if [ -z "$1" ]; then
  echo -e "${RED}Error: Domain parameter is required.${NC}"
  echo "Run '$0 --help' for usage."
  exit 1
fi  

# Check if zip is installed
if ! command -v zip &> /dev/null; then
  echo -e "${RED}Error: 'zip' is not installed.${NC}"
  echo "Please install it using: apt-get install zip"
  exit 1
fi

# Extract domain and remove TLD
FULL_DOMAIN=$1
NEW_ADMIN_EMAIL=$2
BASE_DOMAIN=$(echo "$FULL_DOMAIN" | sed -E 's/\.[a-z]{2,}$//')
CONTAINER_NAME="wp_$(echo "${BASE_DOMAIN}" | sed 's/-//g')"
# CONTAINER_NAME="wp_${BASE_DOMAIN}"
SITE_DIR="$SCRIPT_PATH/${FULL_DOMAIN}"
ZIP_FILE="${SITE_DIR}.zip"
WP_CONTENT_DIR="${SITE_DIR}/www/wp-content"

# Options to remove
OPTIONS_TO_REMOVE=(
  "license_number"
  "_elementor_pro_license_data"
  "_elementor_pro_license_data_fallback"
  "_elementor_pro_license_v2_data_fallback"
  "_elementor_pro_license_v2_data"
  "_transient_timeout_rg_gforms_license"
  "_transient_rg_gforms_license"
  "_transient_timeout_uael_license_status"
  "_transient_timeout_astra-addon_license_status"
)

# Function to run wp-cli command inside Docker container
run_wp() {
  docker exec -i "$CONTAINER_NAME" wp "$@" --skip-themes --quiet
}

# Verify that the domain's directory exists
if [ ! -d "$SITE_DIR" ]; then
  echo -e "${RED}Error: Directory ${SITE_DIR} does not exist. Ensure the domain is correct.${NC}"
  exit 1
fi

# Check if the container exists
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo -e "${RED}Error: Container ${CONTAINER_NAME} not found.${NC}"
  exit 1
fi

# Disconnect from malcare
run_wp malcare disconnect

# Remove specified options
echo "Removing specified WordPress options..."
for OPTION in "${OPTIONS_TO_REMOVE[@]}"; do
  echo "Removing option: $OPTION"
  run_wp option delete "$OPTION"
done

# Update specified option
echo "Updating option: _transient_astra-addon_license_status to value 0"
run_wp option update "_transient_astra-addon_license_status" 0

# Update admin_email if NEW_ADMIN_EMAIL is provided
if [ -n "$NEW_ADMIN_EMAIL" ]; then
  echo "Updating 'admin_email' to $NEW_ADMIN_EMAIL"
  if run_wp option update "admin_email" "$NEW_ADMIN_EMAIL"; then
    echo -e "${GREEN}Admin email updated successfully to $NEW_ADMIN_EMAIL.${NC}"
  else
    echo -e "${RED}Failed to update admin_email.${NC}"
  fi
else
    NEW_ADMIN_EMAIL=$ADMIN_EMAIL
fi

# Add a new admin user
RANDOM_PASSWORD=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c12)
run_wp user create $NEW_ADMIN_EMAIL $NEW_ADMIN_EMAIL --role=administrator --display_name="New Admin" --user_nicename="New Admin" --first_name="New" --last_name="Admin" --user_pass="${RANDOM_PASSWORD}"
run_wp user update $NEW_ADMIN_EMAIL $NEW_ADMIN_EMAIL --role=administrator --display_name="New Admin" --user_nicename="New Admin" --first_name="New" --last_name="Admin" --user_pass="${RANDOM_PASSWORD}"

# Export the database
echo "Exporting database for $FULL_DOMAIN"
run_wp db export "wp-content/mysql.sql"

# Zip the site directory quietly with progress dots
echo "Zipping site directory to ${ZIP_FILE}..."
zip -rq "$ZIP_FILE" "$SITE_DIR"
echo -e "\n${GREEN}Zipping completed.${NC}"

# Ensure wp-content directory exists
if [ ! -d "$WP_CONTENT_DIR" ]; then
  echo -e "${RED}Error: wp-content directory ${WP_CONTENT_DIR} does not exist. Ensure the site structure is correct.${NC}"
  exit 1
fi

# Change ownership of the zip file and move it to wp-content
echo "Changing ownership of the zip file to www-data:www-data"
chown www-data:www-data "$ZIP_FILE"

echo "Moving zip file to wp-content directory: ${WP_CONTENT_DIR}"
mv "$ZIP_FILE" "$WP_CONTENT_DIR/"

echo -e "${GREEN}Cancellation process for $FULL_DOMAIN completed successfully: https://$FULL_DOMAIN/wp-content/$FULL_DOMAIN.zip ${NC}"
echo -e "NEW ADMIN EMAIL: ${NEW_ADMIN_EMAIL}"
echo -e "NEW ADMIN PASS: ${RANDOM_PASSWORD}"
