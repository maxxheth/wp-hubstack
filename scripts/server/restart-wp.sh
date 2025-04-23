#!/bin/bash

# Find all docker-compose.yml files with wp_services and restarts them

source "$(dirname "$0")/../.env"

for compose_file in $DOMAIN_PATH/*/docker-compose.yml; do

    # Change to the directory containing the docker-compose.yml
    compose_dir=$(dirname "$compose_file")
    cd "$compose_dir" || continue

    # Get the list of services starting with "wp_"
    wp_services=$(docker compose config --services | grep '^wp_')

    # Restart each wp_ service
    if [ -n "$wp_services" ]; then
        for service in $wp_services; do
            echo "Restarting service $service in $compose_dir..."
            docker compose down "$service"
            docker compose up -d "$service"
        done
    else
        echo "No wp_ services found in $compose_dir"
    fi
done
