#!/bin/bash

# Initialize flags
RUN_DOCKERFILE_UPDATER="false"
RUN_SETUP_ASSETS="false"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dockerfile-updater)
      RUN_DOCKERFILE_UPDATER="true"
      shift # past argument
      ;;
    --run-setup-assets)
      RUN_SETUP_ASSETS="true"
      shift # past argument
      ;;
    *)
      # Pass remaining arguments to the main script
      # This assumes batch-wp-plugin-update-runner-docker.sh handles them
      break # Stop parsing flags, rest are for the other script
      ;;
  esac
done

if [[ "$RUN_DOCKERFILE_UPDATER" == "true" ]]; then
  chmod +x ./wp-dockerfile-updater.sh
  echo "Running wp-dockerfile-updater.sh..."
  ./wp-dockerfile-updater.sh --append-only
fi

if [[ "$RUN_SETUP_ASSETS" == "true" ]]; then
  chmod +x ./set-up-batch-wp-plugin-assets.sh
  echo "Running set-up-batch-wp-plugin-assets.sh..."
  ./set-up-batch-wp-plugin-assets.sh
fi

# Always run the main batch update script, passing any remaining arguments
echo "Running batch-wp-plugin-update-runner-docker.sh..."
docker ps > /var/opt/docker-containers.txt
#./batch-wp-plugin-update-runner-docker.sh --local-update-script /var/opt/wp-plugin-update.sh --container-list-file /var/opt/docker-containers.txt --exclude-checks core-update,constant-wp-debug-falsy,cache-flush
./batch-wp-plugin-update-runner-docker.sh --local-update-script /var/opt/wp-plugin-update.sh --container-list-file /var/opt/docker-containers.txt --exclude-checks core-update,constant-wp-debug-falsy,cache-flush --skip-plugins --skip-wp-doctor --custom-plugins-dir /var/opt/shared/plugins
#./batch-wp-plugin-update-runner-docker.sh "$@"

rm -rf ./venv

./report-runner.sh