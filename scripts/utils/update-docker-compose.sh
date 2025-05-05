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
TARGET_RESTART_POLICY="" # Policy to set, provided via flag
process_wp_sites=false # Default: Skip directories containing wp-config.php in their own folder
WP_CONFIG_SEARCH_DIR="" # Optional directory to search for wp-config.php
# Array to hold exclusion patterns
declare -a EXCLUDE_PATTERNS=("wordpress-manager" "*cache*")
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
  echo "Usage: $0 [--dry-run] [--set-restart-policy <policy_value>] [--wp [--wp-config-dir <path>]] [--exclude-dir <pattern>]... <path_to_installations_directory>" >&2
  # Add specific instructions if yq is missing
  if [[ "$1" == *"yq"* ]]; then
    echo "" >&2
    echo "To install yq (required for YAML processing):" >&2
    echo "  sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq" >&2
    echo "Alternatively, check installation methods at: https://github.com/mikefarah/yq/#install" >&2
  fi
  exit 1
}

# Function to check for required commands
check_commands() {
  local missing_cmds=()
  if ! command -v docker &> /dev/null; then
    missing_cmds+=("docker")
  fi
  # Check for docker compose OR docker-compose
  if ! (docker compose version &> /dev/null || command -v docker-compose &> /dev/null) ; then
     missing_cmds+=("docker compose or docker-compose")
  fi
  if ! command -v yq &> /dev/null; then
     # Add 'yq' specifically so error_exit can detect it
     missing_cmds+=("yq")
  fi
   if ! command -v curl &> /dev/null; then
     missing_cmds+=("curl")
  fi
   if ! command -v wget &> /dev/null; then
     # Wget is needed for the suggested install command
     missing_cmds+=("wget")
  fi


  if [ ${#missing_cmds[@]} -ne 0 ]; then
    error_exit "Required command(s) not found: ${missing_cmds[*]}. Please install them and ensure they are in your PATH."
  fi
}


# Function to find the docker compose command
find_docker_compose_cmd() {
  if docker compose version &> /dev/null; then
    echo "docker compose"
  elif command -v docker-compose &> /dev/null; then
    echo "docker-compose"
  else
    # This case should ideally be caught by check_commands, but added as a safeguard
    error_exit "Neither 'docker compose' nor 'docker-compose' command found."
  fi
}

# --- Initial Checks ---
check_commands

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --dry-run)
      dry_run=true
      log "Dry run mode enabled. No changes will be made."
      shift # past argument
      ;;
    --set-restart-policy)
      if [[ -z "$2" || "$2" == -* ]]; then
        error_exit "Option '--set-restart-policy' requires a policy value (e.g., 'unless-stopped', 'always')."
      fi
      TARGET_RESTART_POLICY="$2"
      log "Target restart policy set to '$TARGET_RESTART_POLICY'."
      shift # past argument
      shift # past value
      ;;
    --wp)
      process_wp_sites=true
      # Log message updated in validation section once default dir is confirmed
      shift # past argument
      ;;
    --wp-config-dir)
      if [[ -z "$2" || "$2" == -* ]]; then
        error_exit "Option '--wp-config-dir' requires a directory path argument."
      fi
      WP_CONFIG_SEARCH_DIR="$2"
      # Basic validation moved to Argument Validation section
      log "Will search for '$WP_CONFIG_FILENAME' in '$WP_CONFIG_SEARCH_DIR' if --wp is active."
      shift # past argument
      shift # past value
      ;;
    --exclude-dir)
      if [[ -z "$2" || "$2" == -* ]]; then
        error_exit "Option '--exclude-dir' requires a pattern argument (e.g., 'temp-*', 'old-site')."
      fi
      EXCLUDE_PATTERNS+=("$2")
      log "Added exclusion pattern: '$2'"
      shift # past argument
      shift # past value
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

# Determine the effective wp-config search directory if --wp is used
EFFECTIVE_WP_CONFIG_SEARCH_DIR=""
if [ "$process_wp_sites" = true ]; then
    if [ -n "$WP_CONFIG_SEARCH_DIR" ]; then
        # --wp and --wp-config-dir provided
        EFFECTIVE_WP_CONFIG_SEARCH_DIR="$WP_CONFIG_SEARCH_DIR"
        log "Processing WP sites: Using specified directory for wp-config.php: $EFFECTIVE_WP_CONFIG_SEARCH_DIR"
    else
        # --wp provided, but --wp-config-dir not provided: default to current directory
        EFFECTIVE_WP_CONFIG_SEARCH_DIR="."
        log "Processing WP sites: Using current directory for wp-config.php: $(pwd)"
    fi

    # Validate the determined directory exists
    if [ ! -d "$EFFECTIVE_WP_CONFIG_SEARCH_DIR" ]; then
        error_exit "The directory specified or defaulted for wp-config.php ('$EFFECTIVE_WP_CONFIG_SEARCH_DIR') does not exist."
    fi

    # Validate wp-config.php exists in the determined directory
    wp_config_full_path="$EFFECTIVE_WP_CONFIG_SEARCH_DIR/$WP_CONFIG_FILENAME"
    # Use realpath to get the canonical path for the error message
    wp_config_real_path=$(realpath "$wp_config_full_path" 2>/dev/null || echo "$wp_config_full_path")
    if [ ! -f "$wp_config_full_path" ]; then
        error_exit "--wp flag specified, but '$WP_CONFIG_FILENAME' not found in '$wp_config_real_path'."
    fi
elif [ -n "$WP_CONFIG_SEARCH_DIR" ]; then
    # --wp-config-dir provided without --wp
    log_warn "Ignoring --wp-config-dir because --wp flag was not provided."
fi


# Enable exit on error only if NOT in dry run mode
if [ "$dry_run" = false ]; then
    set -e
fi

# Determine the correct docker compose command
DOCKER_COMPOSE_CMD=$(find_docker_compose_cmd)
log "Using '$DOCKER_COMPOSE_CMD' for Docker operations."
if [ -n "$TARGET_RESTART_POLICY" ]; then
    log "Will set 'restart: $TARGET_RESTART_POLICY' on 'wp_*' service if found."
else
    log "No --set-restart-policy provided. Restart policies will not be modified."
fi


# --- Main Processing Loop ---
log "Starting processing in directory: $TARGET_DIR"
shopt -s nullglob # Prevent loop from running if no subdirectories match

# Find subdirectories directly under TARGET_DIR
for installdir in "$TARGET_DIR"/*/; do
  # Remove trailing slash for cleaner paths
  installdir_clean="${installdir%/}"
  dir_basename=$(basename "$installdir_clean")
  log "Processing potential installation: $installdir_clean"

  # Check against exclusion patterns
  excluded=false
  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    if [[ "$dir_basename" == $pattern ]]; then
      log "Skipping '$installdir_clean': Directory name matches exclusion pattern '$pattern'."
      excluded=true
      break # No need to check other patterns
    fi
  done
  if [ "$excluded" = true ]; then
    continue # Move to the next directory
  fi

  compose_file_path="$installdir_clean/$COMPOSE_FILENAME"

  # Check 1: docker-compose.yml must always exist
  if [ ! -f "$compose_file_path" ]; then
    log "Skipping '$installdir_clean': '$COMPOSE_FILENAME' not found."
    continue
  fi

  # Check 2: Conditional skip based on --wp flag
  if [ "$process_wp_sites" = true ]; then
      # --wp flag is set: We already validated wp-config.php exists in EFFECTIVE_WP_CONFIG_SEARCH_DIR
      log "Found '$COMPOSE_FILENAME' in '$installdir_clean' (processing as WP site based on config in '$EFFECTIVE_WP_CONFIG_SEARCH_DIR')."
  else
      # --wp flag is NOT set: Check for wp-config.php *within the site dir*
      wp_config_in_site_dir_path="$installdir_clean/$WP_CONFIG_FILENAME"
      if [ -f "$wp_config_in_site_dir_path" ]; then
          log "Skipping '$installdir_clean': '$WP_CONFIG_FILENAME' found inside (run with --wp flag to process WP sites)."
          continue
      else
          log "Found '$COMPOSE_FILENAME' in '$installdir_clean' ('$WP_CONFIG_FILENAME' not found inside, processing non-WP site)."
      fi
  fi

  # If we reach here, the directory meets the criteria based on the --wp flag.

  # Check if modification is needed (only if --set-restart-policy was provided)
  if [ -z "$TARGET_RESTART_POLICY" ]; then
     log "Skipping restart policy modification for '$installdir_clean' as --set-restart-policy was not provided."
     continue # Skip modification and deployment checks if policy wasn't set
  fi

  # Find the service key starting with 'wp_' using yq
  # Use yq eval to handle potential errors gracefully within the command substitution
  wp_service_key=$(yq eval '.services | keys | .[] | select(. == "wp_*")' "$compose_file_path" 2>/dev/null || true)

  if [ -z "$wp_service_key" ]; then
      log_warn "Could not find a service key starting with 'wp_' in '$compose_file_path'. Skipping restart policy modification."
      continue
  fi
  log "Found 'wp_*' service key: '$wp_service_key'"


  # --- Modification and Deployment Section ---
  current_date=$(date +"$DATE_FORMAT")
  backup_file="$installdir_clean/docker-compose-bu-$current_date.yml"
  site_hostname=$(basename "$installdir_clean")
  # *** Assumption: Site URL derived from directory name, uses HTTPS on port 443 ***
  site_url="https://$site_hostname" # Keep HTTPS assumption or make configurable

  # 3. Create backup
  log_dry "Would back up '$compose_file_path' to '$backup_file'"
  if [ "$dry_run" = false ]; then
    log "Backing up '$compose_file_path' to '$backup_file'..."
    cp "$compose_file_path" "$backup_file" # set -e handles cp errors if not dry run
  fi

  # 4. Set restart policy using yq
  log_dry "Would set 'restart: $TARGET_RESTART_POLICY' for service '$wp_service_key' in '$compose_file_path' using yq"
  if [ "$dry_run" = false ]; then
      log "Setting 'restart: $TARGET_RESTART_POLICY' for service '$wp_service_key' in '$compose_file_path' using yq..."
      # Use yq eval with -i for in-place editing. Capture potential errors.
      if ! yq eval --inplace ".services[\"$wp_service_key\"].restart = \"$TARGET_RESTART_POLICY\"" "$compose_file_path"; then
          # Attempt to restore backup on yq failure
          log_warn "yq command failed to modify '$compose_file_path'. Attempting to restore backup..."
          if cp "$backup_file" "$compose_file_path"; then
              log_warn "Restored '$compose_file_path' from backup '$backup_file'."
          else
              log_warn "Failed to restore backup '$backup_file'. Manual check required for '$compose_file_path'."
          fi
          error_exit "yq failed to modify '$compose_file_path'. Check yq version and file syntax (backup restored if possible)."
      fi
  fi

  # 5. Validate the modified docker-compose.yml file
  log_dry "Would validate modified '$compose_file_path' using '$DOCKER_COMPOSE_CMD config -q'"
  if [ "$dry_run" = false ]; then
    log "Validating modified '$compose_file_path'..."
    # Use subshell for cd to avoid changing script's working directory
    if ! (cd "$installdir_clean" && $DOCKER_COMPOSE_CMD config -q) ; then
        # Attempt to restore backup on validation failure
        log_warn "Docker Compose validation failed for '$compose_file_path'. Attempting to restore backup..."
        if cp "$backup_file" "$compose_file_path"; then
            log_warn "Restored '$compose_file_path' from backup '$backup_file'."
        else
            log_warn "Failed to restore backup '$backup_file'. Manual check required for '$compose_file_path'."
        fi
        error_exit "Docker Compose validation failed. Check the file for syntax errors (backup restored if possible)."
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
    log "Note: Assumes directory name '$site_hostname' is the correct, resolvable hostname and site uses HTTPS." # Updated note

    # Use -k for curl to ignore certificate issues for local/staging environments if needed
    http_status=$(curl --silent --output /dev/null --write-out '%{http_code}' --location --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" -k "$site_url" || echo "curl_error")
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