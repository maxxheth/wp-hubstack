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
        *)
            echo "ERROR: Unknown option: $1" >&2
            echo "Usage: $0 [--target-dir <dir>] [--subdir <path>]" >&2
            echo "          --local-update-script <host_script_path> --container-list-file <list_file_path>" >&2
            echo "          [--script-dest-in-container <container_script_path>] [--container-wp-path <path>]" >&2
            echo "          [--exclude-checks <check1,check2|none>] [--exclude-containers <name1,name2>]" >&2
            echo "          [--skip-wp-doctor] [--skip-plugins] [--skip-backup] [--dry-run]" >&2
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

    echo "Injecting update script '$LOCAL_UPDATE_SCRIPT_PATH' to '$DOCKER_CONTAINER_NAME:$SCRIPT_DEST_IN_CONTAINER'..."
    if ! docker cp "$LOCAL_UPDATE_SCRIPT_PATH" "$DOCKER_CONTAINER_NAME:$SCRIPT_DEST_IN_CONTAINER"; then
        echo "ERROR: Failed to copy update script to container '$DOCKER_CONTAINER_NAME'. Skipping." >&2; echo "---"; overall_success=false; continue
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

    DOCKER_EXEC_CMD=(docker --user root exec -i "$DOCKER_CONTAINER_NAME" bash "$SCRIPT_DEST_IN_CONTAINER" "${SCRIPT_ARGS[@]}")

    echo "Running update script '$SCRIPT_DEST_IN_CONTAINER' inside container '$DOCKER_CONTAINER_NAME'..."
    if "${DOCKER_EXEC_CMD[@]}"; then
        echo "Update script finished successfully inside container for $DOCKER_CONTAINER_NAME."
    else
        script_exit_code=$?
        echo "WARNING: Update script failed or reported errors inside container for $DOCKER_CONTAINER_NAME (Exit Code: $script_exit_code)." >&2
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