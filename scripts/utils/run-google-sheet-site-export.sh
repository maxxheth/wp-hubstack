#!/bin/bash

. .env

rm -rf venv

set -a

./python-venv.py create -n venv
./python-venv.py activate venv
. venv/bin/activate
./python-venv.py install -r requirements.txt

chmod +x ./export-site-urls-to-google-sheets.py

./export-site-urls-to-google-sheets.py --creds-file=$CREDS_FILE --spreadsheet-id=1z20_GunM3s0WuAFSp2s0G7l3oSeLYcThpzhaZvQFgfc

set +a
