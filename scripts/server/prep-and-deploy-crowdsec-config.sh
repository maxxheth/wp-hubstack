#!/bin/bash
# Pass through all arguments to the script

set -auo pipefail

cp ./python-venv.py ./prep-and-deploy-crowdsec-config/ || exit 1

cd prep-and-deploy-crowdsec-config || exit 1

rm -rf venv

echo "Creating and activating Python virtual environment..."

./python-venv.py create -n venv

echo "Installing required Python packages..."

./python-venv.py activate venv

. venv/bin/activate

./python-venv.py install -r requirements.txt

if [ $? -ne 0 ]; then
	echo "Failed to install required Python packages."
	exit 1
fi

cd .. || exit 1

echo "Running the main script with provided arguments..."

./prep-and-deploy-crowdsec-config/main_script.py --dry-run --creds-file ./site-url-python-script-6a43db57673f.json --inject-labels --target-file /var/opt/traefik_mock/docker-compose.yml --spreadsheet-id 1RWAoVPrxbM7l3ilFDtNBQI13wRT6cU8aN3mW3ydPBHI

if [ $? -ne 0 ]; then
	echo "Failed to run the main script."
	exit 1
fi

echo "Script executed successfully."

set +auo pipefail