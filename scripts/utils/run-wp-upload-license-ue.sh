#!/bin/bash

# Load .env
. .env

rm -rf venv

set -auo pipefail

# Set up virtual environment for Python

apt install python3.12-venv -y

echo "Setting up Python virtual environment..."
./python-venv.py create -n venv
./python-venv.py activate venv
. venv/bin/activate
./python-venv.py install -r requirements.txt

echo "Virtual environment setup complete."

echo "Checking for the existence of 'wp_check_plugins.py'..."

if [ ! -f "wp-check-plugins.py" ]; then
  echo "File 'wp-check-plugins.py' does not exist. Exiting."
  exit 1
fi

chmod +x ./wp-check-plugins.py

# Check if CREDS_FILE and WP_CHECK_PLUGIN_SPREADSHEET are set

if [ -z "$CREDS_FILE" ]; then
  echo "CREDS_FILE is not set. Please set it in the .env file."
  exit 1
fi

if [ -z "$WP_CHECK_PLUGIN_SPREADSHEET" ]; then
  echo "WP_CHECK_PLUGIN_SPREADSHEET is not set. Please set it in the .env file."
  exit 1
fi

echo "CREDS_FILE: $CREDS_FILE"
echo "WP_CHECK_PLUGIN_SPREADSHEET: $WP_CHECK_PLUGIN_SPREADSHEET"

# Run the wp-check-plugins.py script with the provided arguments

echo "Running wp-check-plugins.py with the provided arguments..."

./wp-upload-license-ue.py \
    --creds-file="$CREDS_FILE" \
    --spreadsheet-id="$WP_UPLOAD_LICENSE_UE" \
    --dry-run
    # Add --dry-run to test without making changes or actual GSheet updates
    # Add --check-json-key to only test GSheet connection