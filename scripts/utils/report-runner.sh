#!/bin/bash

# Install Python venv

./python-venv.py create

./python-venv.py activate

. ./venv/bin/activate

./python-venv.py install

docker ps > docker-containers.txt

./batch-wp-plugin-list.py --container-list-file docker-containers.txt

./wp-render-plugin-report.py --reports-dir wp-plugin-update-reports --render-individual-reports --list-plugins