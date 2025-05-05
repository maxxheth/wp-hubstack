#!/bin/bash

# Exit immediately if a command exits with a non-zero status (for non-dry-run).
# set -e will be conditionally applied later.

# Treat unset variables as an error when substituting.
set -u
# Cause pipelines to return the exit status of the last command that exited with a non-zero status.
set -o pipefail

# --- Configuration ---
COMPOSE_FILENAME="docker-compose.yml"
WP_CONFIG_FILENAME="wp-config.php"
DATE_FORMAT="%Y%m%d-%H%M%S"
# Timeouts for curl check (in seconds)
CURL_CONNECT_TIMEOUT=7
CURL_MAX_TIME=15
# Time to wait after 'docker compose up' before checking site (in seconds)
POST_DEPLOY_WAIT=10
# --- End Configuration ---

# --- Script Variables ---
dry_run=false
TARGET_DIR=""
SOURCE_RESTART_POLICY="always" # Default source policy to look for
TARGET_RESTART_POLICY="unless-stopped" # Target policy to set
verify_wp_config=false # Default: Do not require wp-config.php
# --- End Script Variables ---


# --- Functions ---
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1"
}

log_warn() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARN: $1" >&2 # Warnings to stderr
}

log_dry() {
  # Only prints if dry_run is true
  if [ "$dry_run" = true ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] DRYRUN: $1"
  fi
}

error_exit() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
  # Add usage information to error messages
  echo "Usage: $0 [--dry-run] [--restart-policy <source_policy>] [--verify-wp-config] <path_to_wp_installations_directory>" >&2
  exit 1
}

# Function to find the docker compose command
find_docker_compose_cmd() {
  if command -v docker &> /dev/null && docker compose version &> /dev/null; then
    echo "docker compose"
  elif command -v docker-compose &> /dev/null; then
    echo "docker-compose"
  else
    error_exit "Neither 'docker compose' nor 'docker-compose' command found. Please ensure Docker Compose is installed and in your PATH."
  fi
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --dry-run)
      dry_run=true
      log "Dry run mode enabled. No changes will be made."
      shift # past argument
      ;;
    --restart-policy)
      if [[ -z "$2" || "$2" == -* ]]; then
        error_exit "Option '--restart-policy' requires a non-empty argument (e.g., 'always', 'on-failure')."
      fi
      SOURCE_RESTART_POLICY="$2"
      log "Source restart policy to search for set to '$SOURCE_RESTART_POLICY'."
      shift # past argument
      shift # past value
      ;;
    --verify-wp-config)
      verify_wp_config=true
      log "Verification of '$WP_CONFIG_FILENAME' enabled."
      shift # past argument
      ;;
    -*)
      # Unknown option
      error_exit "Unknown option: $1."
      ;;
    *)
      # Assume it's the TARGET_DIR
      if [ -n "$TARGET_DIR" ]; then
        error_exit "Multiple target directories specified ('$TARGET_DIR' and '$1')."
      fi
      TARGET_DIR="$1"
      shift # past argument
      ;;
  esac
done

# --- Argument Validation ---
if [ -z "$TARGET_DIR" ]; then
  error_exit "Target directory not specified."
fi

if [ ! -d "$TARGET_DIR" ]; then
  error_exit "Target directory '$TARGET_DIR' not found or is not a directory."
fi

# Enable exit on error only if NOT in dry run mode
if [ "$dry_run" = false ]; then
    set -e
fi

# Determine the correct docker compose command
DOCKER_COMPOSE_CMD=$(find_docker_compose_cmd)
log "Using '$DOCKER_COMPOSE_CMD' for Docker operations."
log "Will search for 'restart: $SOURCE_RESTART_POLICY' and replace with 'restart: $TARGET_RESTART_POLICY'."

# --- Main Processing Loop ---
log "Starting processing in directory: $TARGET_DIR"
shopt -s nullglob # Prevent loop from running if no subdirectories match

# Find subdirectories directly under TARGET_DIR
for installdir in "$TARGET_DIR"/*/; do
  # Remove trailing slash for cleaner paths
  installdir_clean="${installdir%/}"
  log "Processing potential WP installation: $installdir_clean"

  wp_config_path="$installdir_clean/$WP_CONFIG_FILENAME"
  compose_file_path="$installdir_clean/$COMPOSE_FILENAME"

  # Check 1: wp-config.php exists (optional)
  if [ "$verify_wp_config" = true ]; then
    if [ ! -f "$wp_config_path" ]; then
      log "Skipping '$installdir_clean': '$WP_CONFIG_FILENAME' not found (verification enabled)."
      continue
    fi
  fi

  # Check 2: docker-compose.yml exists
  if [ ! -f "$compose_file_path" ]; then
    log "Skipping '$installdir_clean': '$COMPOSE_FILENAME' not found."
    continue
  fi

  log "Found '$WP_CONFIG_FILENAME' and '$COMPOSE_FILENAME' in '$installdir_clean'."

  # Check if modification is needed (using the source policy)
  # Use double quotes for variable expansion in grep pattern
  if ! grep -q "restart:[[:space:]]*$SOURCE_RESTART_POLICY" "$compose_file_path"; then
     log "No 'restart: $SOURCE_RESTART_POLICY' policy found in '$compose_file_path'. Skipping modification and deployment checks."
     continue
  fi

  # --- Modification and Deployment Section ---
  current_date=$(date +"$DATE_FORMAT")
  backup_file="$installdir_clean/docker-compose-bu-$current_date.yml"
  site_hostname=$(basename "$installdir_clean")
  # *** Assumption: Site URL derived from directory name, uses HTTP on port 80 ***
  site_url="http://$site_hostname"

  # 3. Create backup
  log_dry "Would back up '$compose_file_path' to '$backup_file'"
  if [ "$dry_run" = false ]; then
    log "Backing up '$compose_file_path' to '$backup_file'..."
    cp "$compose_file_path" "$backup_file" # set -e handles cp errors if not dry run
  fi

  # 4. Replace restart policy
  log_dry "Would replace 'restart: $SOURCE_RESTART_POLICY' with 'restart: $TARGET_RESTART_POLICY' in '$compose_file_path'"
  if [ "$dry_run" = false ]; then
    log "Replacing 'restart: $SOURCE_RESTART_POLICY' with 'restart: $TARGET_RESTART_POLICY' in '$compose_file_path'..."
    # Use double quotes for sed script to allow variable expansion
    sed "s/restart:[[:space:]]*$SOURCE_RESTART_POLICY/restart: $TARGET_RESTART_POLICY/g" "$compose_file_path" > "$compose_file_path.tmp" && mv "$compose_file_path.tmp" "$compose_file_path"
  fi

  # 5. Validate the modified docker-compose.yml file
  log_dry "Would validate modified '$compose_file_path' using '$DOCKER_COMPOSE_CMD config -q'"
  if [ "$dry_run" = false ]; then
    log "Validating modified '$compose_file_path'..."
    if ! (cd "$installdir_clean" && $DOCKER_COMPOSE_CMD config -q) ; then
        error_exit "Docker Compose validation failed for '$compose_file_path'. Restoring from backup '$backup_file' might be needed. Check the file for syntax errors."
        # Script exits here due to set -e or the explicit error_exit
    else
        log "Validation successful for '$compose_file_path'."
    fi
  fi

  # 6. Apply changes and start/recreate containers
  log_dry "Would apply changes using '$DOCKER_COMPOSE_CMD up -d --force-recreate --remove-orphans'"
  log_dry "Would wait $POST_DEPLOY_WAIT seconds."
  if [ "$dry_run" = false ]; then
    log "Applying changes with '$DOCKER_COMPOSE_CMD up -d --force-recreate --remove-orphans' in '$installdir_clean'..."
    # Run 'up' in a subshell to keep context clean
    if ! (cd "$installdir_clean" && $DOCKER_COMPOSE_CMD up -d --force-recreate --remove-orphans); then
         # Don't use error_exit here, allow script to continue with others, but log warning.
         log_warn "Command '$DOCKER_COMPOSE_CMD up -d' potentially failed for '$installdir_clean'. Check Docker logs. Skipping HTTP check for this site."
         continue # Skip HTTP check and proceed to the next directory
    fi
    log "Successfully applied changes. Waiting $POST_DEPLOY_WAIT seconds for containers to initialize..."
    sleep "$POST_DEPLOY_WAIT"
  fi

  # 7. Check HTTP Status Code
  log_dry "Would check for HTTP 200 status at '$site_url'"
  if [ "$dry_run" = false ]; then
    log "Attempting to check site status at '$site_url'..."
    log "Note: Assumes directory name '$site_hostname' is the correct, resolvable hostname and site uses HTTP."

    http_status=$(curl --silent --output /dev/null --write-out '%{http_code}' --location --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" "$site_url" || echo "curl_error")
    # The '|| echo "curl_error"' prevents set -e from exiting if curl itself fails (e.g., connection refused)

    if [ "$http_status" -eq 200 ]; then
        log "SUCCESS: Received HTTP 200 OK from '$site_url'."
    elif [ "$http_status" = "curl_error" ]; then
        log_warn "curl command failed to connect or execute properly for '$site_url'. Could be DNS resolution, network issue, or container not ready. Manual check required."
    else
        log_warn "Did not receive HTTP 200 OK from '$site_url'. Status code received: '$http_status'. Manual check recommended."
        # Consider making this an error_exit depending on how critical this check is
    fi
  fi
  # --- End Modification and Deployment Section ---

done

shopt -u nullglob # Restore default globbing behavior
log "Processing complete."
if [ "$dry_run" = true ]; then
    log "Dry run finished. No files were changed or containers deployed."
fi
exit 0