#!/bin/bash

# --- Configuration ---
LOCAL_UPDATE_SCRIPT_PATH="" 
CONTAINER_LIST_FILE="" 
SCRIPT_DEST_IN_CONTAINER="/tmp/wp-plugin-update-temp.sh" 
CONTAINER_WP_PATH="/var/www/html" 
DEFAULT_TARGET_DIR="."
REPORT_DIR_NAME="report-batch"
REPORT_FORMAT="md" 

# --- Flags ---
TARGET_DIR="$DEFAULT_TARGET_DIR"
SUBDIR_PATH=""     
EXCLUDE_CHECKS_ARG_BATCH="" 
EXCLUDE_CONTAINERS_ARG="" 
SKIP_WP_DOCTOR_BATCH_FLAG=false
SKIP_PLUGINS_BATCH_FLAG=false
SKIP_BACKUP_BATCH_FLAG=false
DRY_RUN_BATCH_FLAG=false # New flag
CUSTOM_PLUGINS_DIR="" # New flag for custom plugins directory

# --- Argument Parsing ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --target-dir)
            if [[ -z "$2" || "$2" == --* ]]; then echo "ERROR: Missing value for --target-dir flag." >&2; exit 1; fi
            TARGET_DIR="$2"; shift 2 ;;
        --subdir)
            if [[ -z "$2" || "$2" == --* ]]; then echo "ERROR: Missing value for --subdir flag." >&2; exit 1; fi
            SUBDIR_PATH="$2"; shift 2 ;;
        --local-update-script)
            if [[ -z "$2" || "$2" == --* ]]; then echo "ERROR: Missing value for --local-update-script flag." >&2; exit 1; fi
            LOCAL_UPDATE_SCRIPT_PATH="$2"; shift 2 ;;
        --container-list-file)
            if [[ -z "$2" || "$2" == --* ]]; then echo "ERROR: Missing value for --container-list-file flag." >&2; exit 1; fi
            CONTAINER_LIST_FILE="$2"; shift 2 ;;
        --script-dest-in-container)
            if [[ -z "$2" || "$2" == --* ]]; then echo "ERROR: Missing value for --script-dest-in-container flag." >&2; exit 1; fi
            SCRIPT_DEST_IN_CONTAINER="$2"; shift 2 ;;
        --container-wp-path)
            if [[ -z "$2" || "$2" == --* ]]; then echo "ERROR: Missing value for --container-wp-path flag." >&2; exit 1; fi
            CONTAINER_WP_PATH="$2"; shift 2 ;;
        --exclude-checks)
            if [[ -z "$2" || "$2" == --* ]]; then echo "ERROR: Missing value for --exclude-checks flag." >&2; exit 1; fi
            EXCLUDE_CHECKS_ARG_BATCH="$2"; shift 2 ;;
        --exclude-containers)
            if [[ -z "$2" || "$2" == --* ]]; then echo "ERROR: Missing value for --exclude-containers flag." >&2; exit 1; fi
            EXCLUDE_CONTAINERS_ARG="$2"; shift 2 ;;
        --skip-wp-doctor)
            SKIP_WP_DOCTOR_BATCH_FLAG=true; shift ;;
        --skip-plugins) 
            SKIP_PLUGINS_BATCH_FLAG=true; shift ;;
        --skip-backup) 
            SKIP_BACKUP_BATCH_FLAG=true; shift ;;
        --dry-run) # New flag
            DRY_RUN_BATCH_FLAG=true; shift ;;
        --custom-plugins-dir)
            if [[ -z "$2" || "$2" == --* ]]; then echo "ERROR: Missing value for --custom-plugins-dir flag." >&2; exit 1; fi
            CUSTOM_PLUGINS_DIR="$2"; shift 2 ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            echo "Usage: $0 [--target-dir <dir>] [--subdir <path>]" >&2
            echo "          --local-update-script <host_script_path> --container-list-file <list_file_path>" >&2
            echo "          [--script-dest-in-container <container_script_path>] [--container-wp-path <path>]" >&2
            echo "          [--exclude-checks <check1,check2|none>] [--exclude-containers <name1,name2>]" >&2
            echo "          [--skip-wp-doctor] [--skip-plugins] [--skip-backup] [--dry-run]" >&2
            echo "          [--custom-plugins-dir <host_plugins_path>]" >&2
            exit 1
            ;;
    esac
done

# --- Pre-flight Checks ---
if [[ -z "$LOCAL_UPDATE_SCRIPT_PATH" ]]; then echo "ERROR: --local-update-script flag is required." >&2; exit 1; fi
if [[ ! -f "$LOCAL_UPDATE_SCRIPT_PATH" ]]; then echo "ERROR: Local update script not found: $LOCAL_UPDATE_SCRIPT_PATH" >&2; exit 1; fi
if [[ ! -x "$LOCAL_UPDATE_SCRIPT_PATH" ]]; then echo "WARNING: Local update script '$LOCAL_UPDATE_SCRIPT_PATH' is not executable. Ensure it has execute permissions." >&2; fi
if [[ -z "$CONTAINER_LIST_FILE" ]]; then echo "ERROR: --container-list-file flag is required." >&2; exit 1; fi
if [[ ! -f "$CONTAINER_LIST_FILE" ]]; then echo "ERROR: Container list file not found: $CONTAINER_LIST_FILE" >&2; exit 1; fi
if [ ! -d "$TARGET_DIR" ]; then echo "ERROR: Target directory for reports not found: $TARGET_DIR" >&2; exit 1; fi
if ! command -v docker &> /dev/null; then echo "ERROR: 'docker' command not found." >&2; exit 1; fi
if ! command -v awk &> /dev/null; then echo "ERROR: 'awk' command not found." >&2; exit 1; fi
if ! command -v realpath &> /dev/null; then echo "ERROR: 'realpath' command not found." >&2; exit 1; fi
if [[ -n "$CUSTOM_PLUGINS_DIR" && ! -d "$CUSTOM_PLUGINS_DIR" ]]; then echo "ERROR: Custom plugins directory not found: $CUSTOM_PLUGINS_DIR" >&2; exit 1; fi

# --- Main Logic ---
echo "Starting batch WordPress update process (Docker Container Injection Mode)..."
echo "Host Target Directory for Reports: $TARGET_DIR"
if [[ -n "$SUBDIR_PATH" ]]; then echo "Subdirectory Path (within container WP path): '$SUBDIR_PATH'"; fi
echo "Local Update Script (Host Path): '$LOCAL_UPDATE_SCRIPT_PATH'"
echo "Container List File (Host Path): '$CONTAINER_LIST_FILE'"
echo "Update Script Destination (Container Path): '$SCRIPT_DEST_IN_CONTAINER'"
echo "WordPress Path in Container: '$CONTAINER_WP_PATH'"
if [[ -n "$EXCLUDE_CHECKS_ARG_BATCH" ]]; then echo "Pass-through: --exclude-checks '$EXCLUDE_CHECKS_ARG_BATCH'"; fi
if [[ -n "$EXCLUDE_CONTAINERS_ARG" ]]; then echo "Exclude Containers List: '$EXCLUDE_CONTAINERS_ARG'"; fi
if [ "$SKIP_WP_DOCTOR_BATCH_FLAG" = true ]; then echo "Pass-through: --skip-wp-doctor enabled"; fi
if [ "$SKIP_PLUGINS_BATCH_FLAG" = true ]; then echo "Pass-through: --skip-plugins enabled"; fi
if [ "$SKIP_BACKUP_BATCH_FLAG" = true ]; then echo "Pass-through: --skip-backup enabled"; fi
if [ "$DRY_RUN_BATCH_FLAG" = true ]; then echo "Pass-through: --dry-run enabled"; fi # New log line
if [[ -n "$CUSTOM_PLUGINS_DIR" ]]; then echo "Custom Plugins Directory (Host Path): '$CUSTOM_PLUGINS_DIR'"; fi

mapfile -t DOCKER_CONTAINER_NAMES < <(awk 'NR > 1 && $NF ~ /^wp_/ {print $NF}' "$CONTAINER_LIST_FILE")

TARGET_DIR_ABS=$(realpath "$TARGET_DIR")
echo "Absolute Host Target Directory for Reports: $TARGET_DIR_ABS"
REPORT_BATCH_DIR_HOST="$TARGET_DIR_ABS/$REPORT_DIR_NAME"
mkdir -p "$REPORT_BATCH_DIR_HOST" || { echo "ERROR: Could not create report directory: $REPORT_BATCH_DIR_HOST"; exit 1; }
echo "Host Report Directory: $REPORT_BATCH_DIR_HOST"

if [ ${#DOCKER_CONTAINER_NAMES[@]} -eq 0 ]; then
    echo "No relevant WordPress containers found in '$CONTAINER_LIST_FILE'."
    exit 0
fi
echo "Found ${#DOCKER_CONTAINER_NAMES[@]} WordPress containers to process:"
printf "  %s\n" "${DOCKER_CONTAINER_NAMES[@]}"
echo "---"

overall_success=true

for DOCKER_CONTAINER_NAME in "${DOCKER_CONTAINER_NAMES[@]}"; do
    if [[ -n "$EXCLUDE_CONTAINERS_ARG" ]]; then
        if [[ ",$EXCLUDE_CONTAINERS_ARG," == *",$DOCKER_CONTAINER_NAME,"* ]]; then
            echo "Skipping Container (excluded): $DOCKER_CONTAINER_NAME"; echo "---"; continue
        fi
    fi
    echo "Processing Container: $DOCKER_CONTAINER_NAME"
    sanitized_container_name=$(echo "$DOCKER_CONTAINER_NAME" | sed 's/[^a-zA-Z0-9_-]/_/g')

    # Check for WP-CLI and install if not present
    echo "  Checking for WP-CLI in container '$DOCKER_CONTAINER_NAME'..."
    if ! docker exec "$DOCKER_CONTAINER_NAME" command -v wp &>/dev/null; then
        echo "  WP-CLI not found in container '$DOCKER_CONTAINER_NAME'. Attempting to install..."
        
        HOST_TEMP_WP_CLI_PATH="/tmp/wp-cli.phar-$(date +%s%N)" # Unique temp file name
        echo "  Downloading WP-CLI to host at '$HOST_TEMP_WP_CLI_PATH'..."
        if curl -sSL -o "$HOST_TEMP_WP_CLI_PATH" https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar; then
            chmod +x "$HOST_TEMP_WP_CLI_PATH"
            echo "  Copying WP-CLI from host '$HOST_TEMP_WP_CLI_PATH' to container '$DOCKER_CONTAINER_NAME:/usr/local/bin/wp'..."
            if docker cp "$HOST_TEMP_WP_CLI_PATH" "$DOCKER_CONTAINER_NAME:/usr/local/bin/wp"; then
                echo "  Successfully installed WP-CLI in container '$DOCKER_CONTAINER_NAME'."
            else
                echo "  ERROR: Failed to copy WP-CLI to container '$DOCKER_CONTAINER_NAME'. Skipping this container." >&2
                overall_success=false
                echo "---"
                rm -f "$HOST_TEMP_WP_CLI_PATH" # Clean up temp file
                continue
            fi
            rm -f "$HOST_TEMP_WP_CLI_PATH" # Clean up temp file
        else
            echo "  ERROR: Failed to download WP-CLI to host. Skipping WP-CLI installation for '$DOCKER_CONTAINER_NAME'." >&2
            overall_success=false
            echo "---"
            # No temp file to clean if download failed, but check just in case part of it exists
            rm -f "$HOST_TEMP_WP_CLI_PATH" 
            continue
        fi
    else
        echo "  WP-CLI already installed in container '$DOCKER_CONTAINER_NAME'."
    fi

    echo "Injecting update script '$LOCAL_UPDATE_SCRIPT_PATH' to '$DOCKER_CONTAINER_NAME:$SCRIPT_DEST_IN_CONTAINER'..."
    if ! docker cp "$LOCAL_UPDATE_SCRIPT_PATH" "$DOCKER_CONTAINER_NAME:$SCRIPT_DEST_IN_CONTAINER"; then
        echo "ERROR: Failed to copy update script to container '$DOCKER_CONTAINER_NAME'. Skipping." >&2; echo "---"; overall_success=false; continue
    fi

    # Copy custom plugins if directory is specified
    if [[ -n "$CUSTOM_PLUGINS_DIR" ]]; then
        echo "Copying custom plugins from '$CUSTOM_PLUGINS_DIR' to '$DOCKER_CONTAINER_NAME:$CONTAINER_WP_PATH/wp-content/plugins/'..."
        if [ -d "$CUSTOM_PLUGINS_DIR" ] && [ -n "$(ls -A "$CUSTOM_PLUGINS_DIR")" ]; then
            for plugin_item in "$CUSTOM_PLUGINS_DIR"/*; do
                if [ -e "$plugin_item" ]; then # Check if item exists
                    plugin_item_name=$(basename "$plugin_item")
                    plugin_slug=""

                    if [[ -d "$plugin_item" ]]; then
                        plugin_slug="$plugin_item_name"
                    elif [[ -f "$plugin_item" && "$plugin_item_name" == *.zip ]]; then
                        plugin_slug="${plugin_item_name%.zip}"
                    else
                        echo "  Skipping '$plugin_item_name': not a recognized plugin directory or .zip file."
                        continue
                    fi

                    echo "  Checking status of plugin '$plugin_slug' in container '$DOCKER_CONTAINER_NAME'..."

                    # Check if the plugin is installed in the container
                    # `wp plugin list --field=name` outputs one plugin slug per line.
                    # `grep -Fxq "$plugin_slug"` checks for an exact, full line match, quietly.
                    # It returns 0 if found (installed), 1 if not found (not installed).
                    if docker exec "$DOCKER_CONTAINER_NAME" wp --allow-root --path="$CONTAINER_WP_PATH" plugin list --field=name --format=csv | grep -Fxq "$plugin_slug"; then
                        # Plugin is installed. The condition "(!installed AND !active) is false", so we proceed to copy.
                        echo "  Plugin '$plugin_slug' is installed in container. Proceeding with copy/update of '$plugin_item_name'..."
                        if docker cp "$plugin_item" "$DOCKER_CONTAINER_NAME:$CONTAINER_WP_PATH/wp-content/plugins/"; then
                            echo "  Successfully copied '$plugin_item_name' (slug: '$plugin_slug')."

                            # Check if the (copied/updated) plugin is active
                            echo "  Checking active status of plugin '$plugin_slug' in container..."
                            # Get status; output will be 'active', 'inactive', or empty/error if not determinable.
                            plugin_status_output=$(docker exec "$DOCKER_CONTAINER_NAME" wp --allow-root --path="$CONTAINER_WP_PATH" plugin list --name="$plugin_slug" --field=status --format=csv 2>/dev/null)

                            if [[ "$plugin_status_output" == "inactive" ]]; then
                                echo "  Plugin '$plugin_slug' is installed but inactive. Attempting to activate..."
                                if docker exec "$DOCKER_CONTAINER_NAME" wp --allow-root --path="$CONTAINER_WP_PATH" plugin activate "$plugin_slug"; then
                                    echo "  Successfully activated plugin '$plugin_slug'."
                                else
                                    echo "  WARNING: Failed to activate plugin '$plugin_slug' in container '$DOCKER_CONTAINER_NAME'." >&2
                                    # Consider if overall_success should be set to false here
                                fi
                            elif [[ "$plugin_status_output" == "active" ]]; then
                                echo "  Plugin '$plugin_slug' is already active."
                            else
                                echo "  Could not determine status or plugin '$plugin_slug' is not in a recognized state (status: '$plugin_status_output'). Manual check may be required." >&2
                            fi
                        else
                            echo "  WARNING: Failed to copy '$plugin_item_name' (slug: '$plugin_slug') to container '$DOCKER_CONTAINER_NAME'." >&2
                            # Decide if this should set overall_success to false or just be a warning
                        fi
                    else
                        # Plugin is not installed. Therefore, "is_installed is false" and "is_active is false" are both true.
                        # As per requirement "If both of those conditions are false, then DO NOT copy", we skip.
                        echo "  Plugin '$plugin_slug' ('$plugin_item_name') is not installed in container. Skipping copy."
                    fi
                fi
            done
        else
            echo "  Custom plugins directory is empty or not found. Skipping plugin copy."
        fi
    fi

    report_filename_in_container="update-results.$REPORT_FORMAT"
    # Report is generated in the WP_DIR inside the container, which is $CONTAINER_WP_PATH
    report_source_path_container="$CONTAINER_WP_PATH/$report_filename_in_container" 
    report_dest_path_host="$REPORT_BATCH_DIR_HOST/${sanitized_container_name}-${report_filename_in_container}"


    SCRIPT_ARGS=()
    SCRIPT_ARGS+=("--print-results" "$REPORT_FORMAT") 
    if [[ -n "$SUBDIR_PATH" ]]; then SCRIPT_ARGS+=("--subdir" "$SUBDIR_PATH"); fi
    if [[ -n "$EXCLUDE_CHECKS_ARG_BATCH" ]]; then SCRIPT_ARGS+=("--exclude-checks" "$EXCLUDE_CHECKS_ARG_BATCH"); fi
    if [ "$SKIP_WP_DOCTOR_BATCH_FLAG" = true ]; then SCRIPT_ARGS+=("--skip-wp-doctor"); fi
    if [ "$SKIP_PLUGINS_BATCH_FLAG" = true ]; then SCRIPT_ARGS+=("--skip-plugins"); fi
    if [ "$SKIP_BACKUP_BATCH_FLAG" = true ]; then SCRIPT_ARGS+=("--skip-backup"); fi 
    if [ "$DRY_RUN_BATCH_FLAG" = true ]; then SCRIPT_ARGS+=("--dry-run"); fi # Pass flag to inner script
    SCRIPT_ARGS+=("$CONTAINER_WP_PATH") # This is the WP_DIR for the script inside the container

    DOCKER_EXEC_CMD=(docker exec -i --user root "$DOCKER_CONTAINER_NAME" bash "$SCRIPT_DEST_IN_CONTAINER" "${SCRIPT_ARGS[@]}")

    echo "Running update script '$SCRIPT_DEST_IN_CONTAINER' inside container '$DOCKER_CONTAINER_NAME'..."
    if "${DOCKER_EXEC_CMD[@]}"; then
        echo "Update script finished successfully inside container for $DOCKER_CONTAINER_NAME."
    else
        script_exit_code=$?
        printf "WARNING: Update script failed or reported errors inside container for $DOCKER_CONTAINER_NAME (Exit Code: $script_exit_code)." >&2
        overall_success=false # Mark overall process as failed if any script fails
    fi

    echo "Attempting to copy report '$report_source_path_container' from container to '$report_dest_path_host'..."
    if docker cp "$DOCKER_CONTAINER_NAME:$report_source_path_container" "$report_dest_path_host"; then
        echo "Report file copied successfully to $report_dest_path_host."
    else
        echo "WARNING: Failed to copy report file from container for $DOCKER_CONTAINER_NAME. Path: '$report_source_path_container'" >&2
        # Not necessarily a failure of the overall batch, but good to note.
    fi

    echo "Removing injected script '$SCRIPT_DEST_IN_CONTAINER' from container '$DOCKER_CONTAINER_NAME'..."
    if ! docker exec "$DOCKER_CONTAINER_NAME" rm -f "$SCRIPT_DEST_IN_CONTAINER"; then
        echo "WARNING: Failed to remove injected script '$SCRIPT_DEST_IN_CONTAINER' from container '$DOCKER_CONTAINER_NAME'." >&2
    fi
    echo "---"
done

echo "Batch WordPress update process completed."
echo "Reports collected in: $REPORT_BATCH_DIR_HOST"

if [ "$overall_success" = true ]; then
    exit 0
else
    echo "One or more container scripts reported errors or failed."
    exit 1
fi