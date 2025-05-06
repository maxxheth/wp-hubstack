#!/bin/bash

# --- Configuration ---
# Set the parent directory to search within. Use "." for the current directory.
PARENT_DIR="."
# Set the command to add to the Dockerfile
WP_CLI_COMMAND="wp package install wp-cli/doctor-command:@stable"
# --- End Configuration ---

# --- Argument Parsing ---
DRY_RUN="false"
if [[ "$1" == "--dry-run" ]]; then
  DRY_RUN="true"
  echo "*** DRY RUN MODE ENABLED ***"
  echo "No files will be modified and no Docker commands will be executed."
  echo "-------------------------------------------------"
fi
# --- End Argument Parsing ---


# Function to detect docker compose command
get_docker_compose_cmd() {
  if command -v docker &> /dev/null && docker compose version &> /dev/null; then
    echo "docker compose"
  elif command -v docker-compose &> /dev/null; then
    echo "docker-compose"
  else
    echo "" # No command found
  fi
}

DOCKER_COMPOSE_CMD=$(get_docker_compose_cmd)

if [[ -z "$DOCKER_COMPOSE_CMD" ]]; then
    echo "ERROR: Neither 'docker compose' nor 'docker-compose' command found. Please install Docker and Docker Compose."
    exit 1
fi

echo "Starting WordPress Dockerfile update process..."
echo "Searching for WordPress installations in: $PARENT_DIR"
echo "Using Docker Compose command: $DOCKER_COMPOSE_CMD"
echo "-------------------------------------------------"

# Find potential WordPress project directories.
# Looks for wp-config.php up to 3 levels deep (e.g., ./project/wp-config.php or ./project/www/wp-config.php).
# Extracts the base project directory (removes /www if present).
# Uses sort -u to process each unique directory only once.
find "$PARENT_DIR" -maxdepth 3 -name 'wp-config.php' -printf '%h\n' | sed 's|/www$||' | sort -u | while IFS= read -r dir; do
    # Use realpath to get the absolute path and handle potential relative paths from find
    # Check if the directory exists before calling realpath
    if [[ ! -d "$dir" ]]; then
        echo " [WARN] Directory '$dir' found by 'find' no longer exists. Skipping."
        continue
    fi
    abs_dir=$(realpath "$dir")
    echo # Blank line for separation
    echo "--- Processing WordPress installation in: $abs_dir ---"

    DOCKERFILE="$abs_dir/Dockerfile"
    # Check for both .yml and .yaml extensions for Docker Compose file
    COMPOSE_FILE_YML="$abs_dir/docker-compose.yml"
    COMPOSE_FILE_YAML="$abs_dir/docker-compose.yaml"
    COMPOSE_FILE=""

    # Determine the correct compose file name
    if [[ -f "$COMPOSE_FILE_YML" ]]; then
        COMPOSE_FILE="$COMPOSE_FILE_YML"
    elif [[ -f "$COMPOSE_FILE_YAML" ]]; then
        COMPOSE_FILE="$COMPOSE_FILE_YAML"
    else
        echo " [SKIP] docker-compose.yml or docker-compose.yaml not found in $abs_dir"
        continue # Skip this directory
    fi

    # Check if Dockerfile exists
    if [[ ! -f "$DOCKERFILE" ]]; then
        echo " [SKIP] Dockerfile not found in $abs_dir"
        continue # Skip this directory
    fi

    # 1. Backup Dockerfile
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="${DOCKERFILE}.bak.${TIMESTAMP}"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo " [DRY RUN] Would backup $DOCKERFILE to $BACKUP_FILE"
    else
        echo " [INFO] Backing up $DOCKERFILE to $BACKUP_FILE..."
        if ! cp "$DOCKERFILE" "$BACKUP_FILE"; then
            echo " [ERROR] Failed to backup Dockerfile. Skipping this installation."
            continue # Skip this directory
        fi
    fi

    # 2. Update Dockerfile
    # Define the content for the Dockerfile lines
    UTILITIES_CMD_CONTENT="apt-get update && apt-get install -y --no-install-recommends ca-certificates && apt-get update && apt-get install -y --no-install-recommends jq awk curl git && rm -rf /var/lib/apt/lists/*"
    FULL_UTILITIES_LINE="RUN $UTILITIES_CMD_CONTENT"
    CURRENT_DATE=$(date)
    COMMENT_LINE="# Utilities and WP-CLI packages ensured by update script on $CURRENT_DATE"
    WP_CLI_INSTALL_LINE="RUN ${WP_CLI_COMMAND}"

    # Define patterns to find and remove potentially existing old lines
    # These patterns are heuristics. Adjust if they are too broad or too narrow.
    COMMENT_PATTERN_GREP="^# Utilities and WP-CLI packages ensured by update script"
    # Pattern for the utilities line we might have added or a similar one that installs these specific tools
    UTILITIES_PATTERN_GREP="RUN .*apt-get install.*(jq|awk|curl|git).*(ca-certificates|jq|awk|curl|git)"
    # Pattern for the specific WP-CLI doctor command installation
    WP_CLI_DOCTOR_PATTERN_GREP="RUN .*wp package install wp-cli/doctor-command"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo " [DRY RUN] Would process $DOCKERFILE to ensure specific lines are present/updated:"
        echo " [DRY RUN]   - Would remove lines matching: $COMMENT_PATTERN_GREP"
        echo " [DRY RUN]   - Would remove lines matching: $UTILITIES_PATTERN_GREP"
        echo " [DRY RUN]   - Would remove lines matching: $WP_CLI_DOCTOR_PATTERN_GREP"
        echo " [DRY RUN]   - Would append: $COMMENT_LINE"
        echo " [DRY RUN]   - Would append: $FULL_UTILITIES_LINE"
        echo " [DRY RUN]   - Would append: $WP_CLI_INSTALL_LINE"
    else
        echo " [INFO] Updating Dockerfile: $DOCKERFILE"
        TEMP_DOCKERFILE=$(mktemp)
        if [[ -z "$TEMP_DOCKERFILE" ]]; then
            echo " [ERROR] Failed to create temporary file. Skipping $DOCKERFILE."
            # Attempt to restore the backup if something went wrong before this point, though unlikely here.
            if [[ -f "$BACKUP_FILE" ]] && ! mv "$BACKUP_FILE" "$DOCKERFILE"; then
                 echo " [CRITICAL] Failed to restore backup $BACKUP_FILE to $DOCKERFILE after mktemp failure!"
            fi
            continue # Skip this directory
        fi

        # Filter out old/existing lines
        grep -vE "$COMMENT_PATTERN_GREP" "$DOCKERFILE" | \
            grep -vE "$UTILITIES_PATTERN_GREP" | \
            grep -vE "$WP_CLI_DOCTOR_PATTERN_GREP" > "$TEMP_DOCKERFILE"

        # Check if grep pipeline succeeded (at least the last grep)
        if [[ $? -ne 0 && $? -ne 1 ]]; then # $? is 1 if no lines matched, which is fine. Other errors are not.
             echo " [ERROR] Failed to filter $DOCKERFILE. Restoring backup."
             rm -f "$TEMP_DOCKERFILE"
             if ! mv "$BACKUP_FILE" "$DOCKERFILE"; then
                 echo " [CRITICAL] Failed to restore backup $BACKUP_FILE to $DOCKERFILE!"
             fi
             continue # Skip this directory
        fi

        # Append the new, correct block of commands
        echo "" >> "$TEMP_DOCKERFILE" # Add a newline just in case the file doesn't end with one
        echo "$COMMENT_LINE" >> "$TEMP_DOCKERFILE"
        echo "$FULL_UTILITIES_LINE" >> "$TEMP_DOCKERFILE"
        echo "$WP_CLI_INSTALL_LINE" >> "$TEMP_DOCKERFILE"

        # Replace the original Dockerfile with the modified temporary file
        if mv "$TEMP_DOCKERFILE" "$DOCKERFILE"; then
            echo " [INFO] Successfully updated $DOCKERFILE."
        else
            echo " [ERROR] Failed to move temporary file to $DOCKERFILE. Restoring backup."
            rm -f "$TEMP_DOCKERFILE" # Clean up temp file if mv failed
            if ! mv "$BACKUP_FILE" "$DOCKERFILE"; then
                 echo " [CRITICAL] Failed to restore backup $BACKUP_FILE to $DOCKERFILE!"
            fi
            continue # Skip this directory
        fi
    fi

    # 3. Validate (implicitly by build) and Restart/Build Docker Container
    if [[ "$DRY_RUN" == "true" ]]; then
        echo " [DRY RUN] Would change directory to $abs_dir"
        echo " [DRY RUN] Would run: $DOCKER_COMPOSE_CMD up -d --build --remove-orphans"
        echo " [DRY RUN] Would change directory back to original"
        echo " [DRY RUN] --- Finished processing $abs_dir ---"
    else
        echo " [INFO] Attempting to rebuild and restart services using $DOCKER_COMPOSE_CMD..."
        ORIG_DIR=$(pwd) # Store current directory

        # Change to the project directory to run docker-compose
        if ! cd "$abs_dir"; then
            echo " [ERROR] Failed to change directory to $abs_dir. Restoring backup."
            cd "$ORIG_DIR" || exit 1 # Go back to original dir
            # Attempt to restore the backup
            if ! mv "$BACKUP_FILE" "$DOCKERFILE"; then
                 echo " [CRITICAL] Failed to restore backup $BACKUP_FILE to $DOCKERFILE!"
            fi
            continue # Skip this directory
        fi

        # Run docker-compose up with build
        # Use --remove-orphans to clean up containers for services removed from the compose file
        # Use -d to run in detached mode
        if $DOCKER_COMPOSE_CMD up -d --build --remove-orphans; then
            echo " [SUCCESS] Successfully updated, rebuilt, and restarted services in $abs_dir."
        else
            echo " [ERROR] Failed to build or restart services via $DOCKER_COMPOSE_CMD in $abs_dir."
            echo " [ERROR] Dockerfile validation likely failed. Check Docker output above."
            echo " [INFO] Restoring Dockerfile from backup: $BACKUP_FILE"
            # Attempt to restore the backup
            if ! mv "$BACKUP_FILE" "$DOCKERFILE"; then
                echo " [CRITICAL] Failed to restore backup $BACKUP_FILE to $DOCKERFILE!"
            else
                echo " [INFO] Backup restored."
            fi
            # No need to explicitly stop containers here, as 'up --build' failure implies they didn't start correctly or are unchanged.
        fi

        # Return to the original directory
        if ! cd "$ORIG_DIR"; then
            echo " [CRITICAL] Failed to change back to the original directory $ORIG_DIR. Exiting."
            exit 1 # Exit script if we can't return
        fi

        echo "--- Finished processing $abs_dir ---"
    fi # End dry run check for step 3

done

echo # Blank line for separation
echo "-------------------------------------------------"
echo "--- All processing complete ---"
