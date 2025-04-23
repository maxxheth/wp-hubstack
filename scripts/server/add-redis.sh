#!/bin/bash

for F in /var/opt/*/docker-compose.yml; do
    # Check if the file contains a WordPress service (wp_)
    if grep -q 'wp_' "$F"; then
        sed -E -i 's|^networks:|networks:\n  cache:\n    name: cache\n    external: true|g' $F
        sed -E -i 's|^    networks:|    networks:\n      - cache|g' $F

        docker compose -f $F down
        docker compose -f $F up -d

    fi
done