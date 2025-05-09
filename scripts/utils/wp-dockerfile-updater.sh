#!/bin/bash

# --- Configuration ---
# Set the parent directory to search within. Use "." for the current directory.
PARENT_DIR="."
# Set the command to add to the Dockerfile
# WP_CLI_COMMAND="wp --allow-root package install wp-cli/doctor-command:@stable"
# --- End Configuration ---

# --- Argument Parsing ---
DRY_RUN="false"
APPEND_ONLY_MODE="false" # Initialize new flag

# Process arguments
# Use a loop to handle flags in any order
TEMP_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN="true"
      shift # past argument
      ;;
    --append-only)
      APPEND_ONLY_MODE="true"
      shift # past argument
      ;;
    *)
      # Unknown option or positional argument (if any were expected)
      # This script doesn't expect other positional args after flags
      # TEMP_ARGS+=("$1")
      echo "Unknown option: $1" >&2
      # exit 1 # Or handle as appropriate
      shift # past argument
      ;;
  esac
done
# Restore positional arguments if needed:
# set -- "${TEMP_ARGS[@]}"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "*** DRY RUN MODE ENABLED ***"
  echo "No files will be modified and no Docker commands will be executed."
  echo "-------------------------------------------------"
fi
if [[ "$APPEND_ONLY_MODE" == "true" ]]; then
  echo "*** APPEND-ONLY MODE ENABLED ***"
  echo "Existing lines will not be filtered; new commands will simply be appended."
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

    # The OLD utilities command string, with --no-install-recommends
    OLD_UTILITIES_CMD_CONTENT_VAL="apt-get update && apt-get install -y --no-install-recommends ca-certificates && apt-get update && apt-get install -y --no-install-recommends jq awk curl git && rm -rf /var/lib/apt/lists/*"
    # Create a grep pattern to specifically match and remove the OLD utilities line.
    # We need to escape the '*' character for it to be treated literally in the grep pattern.
    OLD_UTILITIES_CMD_CONTENT_ESCAPED_FOR_GREP="${OLD_UTILITIES_CMD_CONTENT_VAL//\*/\\*}"
    OLD_UTILITIES_LINE_REMOVAL_PATTERN="^RUN *$OLD_UTILITIES_CMD_CONTENT_ESCAPED_FOR_GREP"

    # The NEW utilities command string, without --no-install-recommends
    UTILITIES_CMD_CONTENT="apt-get update -y && apt-get install -y --no-install-recommends jq gawk curl git ca-certificates tar make wget && rm -rf /var/lib/apt/lists/*"
    FULL_UTILITIES_LINE="RUN $UTILITIES_CMD_CONTENT" # This is the new line to be added

    CURRENT_DATE=$(date)
    USER_ROOT_LINE="USER root" # Line to switch to root user
    COMMENT_LINE="# Utilities and WP-CLI packages ensured by update scrip# Choose a base image that uses apt (e.g., Ubuntu, Debian)
FROM ubuntu:latest

# It's a good practice to run apt-get update before installing packages.
# Combining update and install in one RUN command reduces image layers.
# The -y flag automatically confirms prompts during installation.
# --no-install-recommends can help keep the image size smaller by avoiding
# the installation of packages that are only recommended, not strictly required.
# Finally, clean up the apt cache to reduce image size.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        tar \
        make \
        wget && \
    rm -rf /var/lib/apt/lists/*

# Your other Dockerfile instructions would follow
# For example:
# WORKDIR /app
# COPY . /app
# RUN make myapplication
# CMD ["./myapplication"]t on $CURRENT_DATE"
    # WP_CLI_INSTALL_LINE="RUN ${WP_CLI_COMMAND}"

    # Define patterns to find and remove potentially existing old lines
    COMMENT_PATTERN_GREP="^# Utilities and WP-CLI packages ensured by update script"
    # WP_CLI_DOCTOR_PATTERN_GREP="RUN .*wp package install wp-cli/doctor-command"
    # USER_ROOT_PATTERN_GREP="^USER root" # This pattern is defined but not used in the current filter pipeline below

    if [[ "$DRY_RUN" == "true" ]]; then
        echo " [DRY RUN] Would process $DOCKERFILE to ensure specific lines are present/updated:"
        if [[ "$APPEND_ONLY_MODE" == "true" ]]; then
            echo " [DRY RUN]   Mode: Append-only. No lines would be removed by filtering."
        else
            echo " [DRY RUN]   Mode: Filter and Append."
            # Only list patterns that are actively used in the grep pipeline below
            echo " [DRY RUN]     - Would remove lines matching: $COMMENT_PATTERN_GREP"
            echo " [DRY RUN]     - Would remove lines matching specific old utilities pattern: $OLD_UTILITIES_LINE_REMOVAL_PATTERN"
            # If WP_CLI_DOCTOR_PATTERN_GREP is defined and non-empty, it would filter.
            # If its definition is commented out, the variable is empty, and grep -vE "" doesn't remove lines.
            if [[ -n "$WP_CLI_DOCTOR_PATTERN_GREP" ]]; then
                echo " [DRY RUN]     - Would remove lines matching: $WP_CLI_DOCTOR_PATTERN_GREP"
            else
                echo " [DRY RUN]     - WP_CLI_DOCTOR_PATTERN_GREP is not actively filtering (variable empty or undefined)."
            fi
        fi
        echo " [DRY RUN]   - Would append: $USER_ROOT_LINE"
        echo " [DRY RUN]   - Would append: $COMMENT_LINE"
        echo " [DRY RUN]   - Would append: $FULL_UTILITIES_LINE" # New utilities line
        # echo " [DRY RUN]   - Would append: $WP_CLI_INSTALL_LINE"
    else
        echo " [INFO] Updating Dockerfile: $DOCKERFILE"
        TEMP_DOCKERFILE=$(mktemp)
        if [[ -z "$TEMP_DOCKERFILE" ]]; then
            echo " [ERROR] Failed to create temporary file. Skipping $DOCKERFILE."
            if [[ -f "$BACKUP_FILE" ]] && ! mv "$BACKUP_FILE" "$DOCKERFILE"; then
                 echo " [CRITICAL] Failed to restore backup $BACKUP_FILE to $DOCKERFILE after mktemp failure!"
            fi
            continue # Skip this directory
        fi

        if [[ "$APPEND_ONLY_MODE" == "true" ]]; then
            echo " [INFO] Append-only mode: Copying original Dockerfile content to temporary file."
            if ! cp "$DOCKERFILE" "$TEMP_DOCKERFILE"; then
                echo " [ERROR] Failed to copy $DOCKERFILE to $TEMP_DOCKERFILE. Restoring backup."
                rm -f "$TEMP_DOCKERFILE"
                if [[ -f "$BACKUP_FILE" ]] && ! mv "$BACKUP_FILE" "$DOCKERFILE"; then
                    echo " [CRITICAL] Failed to restore backup $BACKUP_FILE to $DOCKERFILE after cp failure!"
                fi
                continue # Skip this directory
            fi
        else
            echo " [INFO] Filtering Dockerfile..."
            # Filter out old/existing lines using the specific pattern for the old utilities command
            # The WP_CLI_DOCTOR_PATTERN_GREP variable is used here. If its definition is commented out,
            # it will be empty, and `grep -vE ""` effectively doesn't filter anything for that step.
            grep -vE "$COMMENT_PATTERN_GREP" "$DOCKERFILE" | \
                grep -vE "$OLD_UTILITIES_LINE_REMOVAL_PATTERN" | \
                grep -vE "$WP_CLI_DOCTOR_PATTERN_GREP" > "$TEMP_DOCKERFILE"

            # Check if grep pipeline succeeded (at least the last grep)
            # $? is 1 if no lines matched (which is fine). Other errors are not.
            # This checks the exit status of the last command in the pipeline (the final grep).
            GREP_EXIT_STATUS=$?
            if [[ $GREP_EXIT_STATUS -ne 0 && $GREP_EXIT_STATUS -ne 1 ]]; then
                 echo " [ERROR] Failed to filter $DOCKERFILE (grep exit status: $GREP_EXIT_STATUS). Restoring backup."
                 rm -f "$TEMP_DOCKERFILE"
                 if ! mv "$BACKUP_FILE" "$DOCKERFILE"; then
                     echo " [CRITICAL] Failed to restore backup $BACKUP_FILE to $DOCKERFILE!"
                 fi
                 continue # Skip this directory
            fi
        fi

        # Append the new, correct block of commands
        echo "" >> "$TEMP_DOCKERFILE" # Add a newline just in case the file doesn't end with one
        echo "$USER_ROOT_LINE" >> "$TEMP_DOCKERFILE" # Add USER root before other commands
        echo "$COMMENT_LINE" >> "$TEMP_DOCKERFILE"
        echo "$FULL_UTILITIES_LINE" >> "$TEMP_DOCKERFILE"
        # echo "$WP_CLI_INSTALL_LINE" >> "$TEMP_DOCKERFILE"

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
        echo " [DRY RUN] Would run: $DOCKER_COMPOSE_CMD up -d --build"
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
        # Use -d to run in detached mode
        if $DOCKER_COMPOSE_CMD up -d --build; then
            echo " [SUCCESS] Successfully updated, rebuilt, and restarted services in $abs_dir."
        else
            echo " [ERROR] Failed to build or restart services via $DOCKER_COMPOSE_CMD in $abs_dir."
            echo " [ERROR] Dockerfile validation likely failed. Check Docker output above."
            echo " [INFO] Restoring Dockerfile from backup: $BACKUP_FILE"
            
            cp $DOCKERFILE "${DOCKERFILE}_COPY" # Create a temporary copy of the backup
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
