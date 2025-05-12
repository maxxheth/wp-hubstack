#!/bin/bash

# --- Configuration ---
# Full path to the update script *on the host machine*
LOCAL_UPDATE_SCRIPT_PATH="" # MANDATORY: Set this via --local-update-script
# Path to the file containing the list of Docker containers
CONTAINER_LIST_FILE="" # MANDATORY: Set this via --container-list-file
# Path where the update script will be copied TO and EXECUTED FROM inside the Docker containers
SCRIPT_DEST_IN_CONTAINER="/tmp/wp-plugin-update-temp.sh" # Default, override with --script-dest-in-container

# The standard path where WP files reside *inside* the containers
CONTAINER_WP_PATH="/var/www/html" # Default, override with --container-wp-path

# Default directory on the HOST to scan for WP project roots (now primarily for report output)
DEFAULT_TARGET_DIR="."
# Directory on the HOST to store the generated reports
REPORT_DIR_NAME="report-batch"
# Default report format for the underlying script
REPORT_FORMAT="md" # Use 'md' or 'html'

# --- Flags ---
TARGET_DIR="$DEFAULT_TARGET_DIR"
DRY_RUN_MODE=false # Initialize dry-run flag
SUBDIR_PATH=""     # Initialize subdir path flag (relative path *within* CONTAINER_WP_PATH)
EXCLUDE_CHECKS_ARG_BATCH="" # Added for --exclude-checks
EXCLUDE_CONTAINERS_ARG="" # Added for --exclude-containers
# Flags to pass through to the underlying wp-plugin-update.sh script
BEDROCK_MODE_BATCH=false
ALLOW_CHECK_ERRORS_BATCH=false
DISABLE_JQ_BATCH=false
DISABLE_WGET_BATCH=false
UPDATE_ALL_BATCH=false
SEO_RANK_ELEMENTOR_UPDATE_BATCH_FLAG=false   # <-- new

# --- Argument Parsing ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --target-dir)
            if [[ -z "$2" || "$2" == --* ]]; then echo "ERROR: Missing value for --target-dir flag." >&2; exit 1; fi
            TARGET_DIR="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN_MODE=true; shift ;;
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
        --bedrock)
            BEDROCK_MODE_BATCH=true; shift ;;
        --allow-check-errors)
            ALLOW_CHECK_ERRORS_BATCH=true; shift ;;
        --disable-jq)
            DISABLE_JQ_BATCH=true; shift ;;
        --disable-wget)
            DISABLE_WGET_BATCH=true; shift ;;
        --update-all)
            UPDATE_ALL_BATCH=true; shift ;;
        --seo-rank-elementor-update)           # <-- new
            SEO_RANK_ELEMENTOR_UPDATE_BATCH_FLAG=true; shift ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            echo "Usage: $0 [--target-dir <dir>] [--dry-run] [--subdir <path>]" >&2
            echo "          --local-update-script <host_script_path> --container-list-file <list_file_path>" >&2
            echo "          [--script-dest-in-container <container_script_path>] [--container-wp-path <path>]" >&2
            echo "          [--exclude-checks <check1,check2|none>] [--exclude-containers <name1,name2>]" >&2
            echo "          [--bedrock] [--allow-check-errors] [--disable-jq] [--disable-wget] [--update-all]" >&2
            echo "          [--seo-rank-elementor-update]" >&2 # <-- new
            exit 1
            ;;
    esac
done

# --- Pre-flight Checks ---

# Check mandatory flags
if [[ -z "$LOCAL_UPDATE_SCRIPT_PATH" ]]; then echo "ERROR: --local-update-script flag is required." >&2; exit 1; fi
if [[ ! -f "$LOCAL_UPDATE_SCRIPT_PATH" ]]; then echo "ERROR: Local update script not found: $LOCAL_UPDATE_SCRIPT_PATH" >&2; exit 1; fi
if [[ ! -x "$LOCAL_UPDATE_SCRIPT_PATH" ]]; then echo "WARNING: Local update script '$LOCAL_UPDATE_SCRIPT_PATH' is not executable on the host. Ensure it has execute permissions if issues arise." >&2; fi

if [[ -z "$CONTAINER_LIST_FILE" ]]; then echo "ERROR: --container-list-file flag is required." >&2; exit 1; fi
if [[ ! -f "$CONTAINER_LIST_FILE" ]]; then echo "ERROR: Container list file not found: $CONTAINER_LIST_FILE" >&2; exit 1; fi

# Check if the target directory exists on the host
if [ ! -d "$TARGET_DIR" ]; then
    echo "ERROR: Target directory for reports not found: $TARGET_DIR" >&2
    exit 1
fi

# Check if docker command exists
if ! command -v docker &> /dev/null; then
    echo "ERROR: 'docker' command not found. Please install Docker." >&2
    exit 1
fi

# Check if awk command exists
if ! command -v awk &> /dev/null; then
    echo "ERROR: 'awk' command not found. Please install it." >&2
    exit 1
fi

# --- Main Logic ---

echo "Starting batch WordPress update process (Docker Container Injection Mode)..."
echo "Host Target Directory for Reports: $TARGET_DIR"
if [ "$DRY_RUN_MODE" = true ]; then
    echo "Dry Run Mode: ENABLED (Will pass --dry-run to update script)"
fi
if [[ -n "$SUBDIR_PATH" ]]; then
    echo "Subdirectory Path (within container WP path): '$SUBDIR_PATH'"
fi
echo "Local Update Script (Host Path): '$LOCAL_UPDATE_SCRIPT_PATH'"
echo "Container List File (Host Path): '$CONTAINER_LIST_FILE'"
echo "Update Script Destination (Container Path): '$SCRIPT_DEST_IN_CONTAINER'"
echo "WordPress Path in Container: '$CONTAINER_WP_PATH'"
if [[ -n "$EXCLUDE_CHECKS_ARG_BATCH" ]]; then
    echo "WP Doctor Exclude Checks: '$EXCLUDE_CHECKS_ARG_BATCH'"
fi
if [[ -n "$EXCLUDE_CONTAINERS_ARG" ]]; then
    echo "Exclude Containers List: '$EXCLUDE_CONTAINERS_ARG'"
fi
if [ "$BEDROCK_MODE_BATCH" = true ]; then echo "Pass-through: --bedrock enabled"; fi
if [ "$ALLOW_CHECK_ERRORS_BATCH" = true ]; then echo "Pass-through: --allow-check-errors enabled"; fi
if [ "$DISABLE_JQ_BATCH" = true ]; then echo "Pass-through: --disable-jq enabled"; fi
if [ "$DISABLE_WGET_BATCH" = true ]; then echo "Pass-through: --disable-wget enabled"; fi
if [ "$UPDATE_ALL_BATCH" = true ]; then echo "Pass-through: --update-all enabled"; fi
if [ "$SEO_RANK_ELEMENTOR_UPDATE_BATCH_FLAG" = true ]; then echo "Pass-through: --seo-rank-elementor-update enabled"; fi  # <-- new

mapfile -t DOCKER_CONTAINER_NAMES < <(awk 'NR > 1 && $NF ~ /^wp_/ {print $NF}' "$CONTAINER_LIST_FILE")

# Get the absolute path of the target directory on the host
TARGET_DIR_ABS=$(realpath "$TARGET_DIR")
echo "Absolute Host Target Directory for Reports: $TARGET_DIR_ABS"

# Define and create the report batch directory on the HOST
REPORT_BATCH_DIR_HOST="$TARGET_DIR_ABS/$REPORT_DIR_NAME"
mkdir -p "$REPORT_BATCH_DIR_HOST" || { echo "ERROR: Could not create report directory: $REPORT_BATCH_DIR_HOST"; exit 1; }
echo "Host Report Directory: $REPORT_BATCH_DIR_HOST"

# Read and filter container names from the provided file
echo "Reading container names from '$CONTAINER_LIST_FILE'..."


if [ ${#DOCKER_CONTAINER_NAMES[@]} -eq 0 ]; then
    echo "No relevant WordPress containers found in '$CONTAINER_LIST_FILE' (expected image: ghcr.io/ciwebgroup/advanced-wordpress)."
    exit 0
fi

echo "Found ${#DOCKER_CONTAINER_NAMES[@]} WordPress containers to process:"
printf "  %s\n" "${DOCKER_CONTAINER_NAMES[@]}"
echo "---"

# Process each identified container
for DOCKER_CONTAINER_NAME in "${DOCKER_CONTAINER_NAMES[@]}"; do

    # Check if this container should be excluded
    if [[ -n "$EXCLUDE_CONTAINERS_ARG" ]]; then
        # Pad the exclude list and container name with commas for exact matching
        if [[ ",$EXCLUDE_CONTAINERS_ARG," == *",$DOCKER_CONTAINER_NAME,"* ]]; then
            echo "Skipping Container (excluded): $DOCKER_CONTAINER_NAME"
            echo "---"
            continue
        fi
    fi

    echo "Processing Container: $DOCKER_CONTAINER_NAME"

    # Sanitize container name for use in report filenames on the host
    sanitized_container_name=$(echo "$DOCKER_CONTAINER_NAME" | sed 's/[^a-zA-Z0-9_-]/_/g')

    # --- Inject Script into Container ---
    echo "Injecting update script '$LOCAL_UPDATE_SCRIPT_PATH' to '$DOCKER_CONTAINER_NAME:$SCRIPT_DEST_IN_CONTAINER'..."
    if ! docker cp "$LOCAL_UPDATE_SCRIPT_PATH" "$DOCKER_CONTAINER_NAME:$SCRIPT_DEST_IN_CONTAINER"; then
        echo "ERROR: Failed to copy update script to container '$DOCKER_CONTAINER_NAME'. Skipping." >&2
        echo "---"
        continue
    fi

    # --- Prepare for Execution ---
    report_filename_in_container="update-results.$REPORT_FORMAT"
    report_dest_path_host="$REPORT_BATCH_DIR_HOST/${sanitized_container_name}-${report_filename_in_container}"
    report_source_path_container="$CONTAINER_WP_PATH/$report_filename_in_container"

    SCRIPT_ARGS=() # Initialize as an empty array
    SCRIPT_ARGS+=("--print-results" "$REPORT_FORMAT") # Pass option and its value as separate arguments

    if [ "$DRY_RUN_MODE" = true ]; then
        SCRIPT_ARGS+=("--dry-run")
    fi
    if [[ -n "$SUBDIR_PATH" ]]; then
        SCRIPT_ARGS+=("--subdir" "$SUBDIR_PATH")
    fi
    if [[ -n "$EXCLUDE_CHECKS_ARG_BATCH" ]]; then
        SCRIPT_ARGS+=("--exclude-checks" "$EXCLUDE_CHECKS_ARG_BATCH")
    fi
    if [ "$BEDROCK_MODE_BATCH" = true ]; then
        SCRIPT_ARGS+=("--bedrock")
    fi
    if [ "$ALLOW_CHECK_ERRORS_BATCH" = true ]; then
        SCRIPT_ARGS+=("--allow-check-errors")
    fi
    if [ "$DISABLE_JQ_BATCH" = true ]; then
        SCRIPT_ARGS+=("--disable-jq")
    fi
    if [ "$DISABLE_WGET_BATCH" = true ]; then
        SCRIPT_ARGS+=("--disable-wget")
    fi
    if [ "$UPDATE_ALL_BATCH" = true ]; then
        SCRIPT_ARGS+=("--update-all")
    fi
    if [ "$SEO_RANK_ELEMENTOR_UPDATE_BATCH_FLAG" = true ]; then       # <-- new
        SCRIPT_ARGS+=("--seo-rank-elementor-update")
    fi
    SCRIPT_ARGS+=("$CONTAINER_WP_PATH") # Add the positional WordPress path last

    DOCKER_EXEC_CMD=(docker exec -i "$DOCKER_CONTAINER_NAME" bash "$SCRIPT_DEST_IN_CONTAINER" "${SCRIPT_ARGS[@]}")

    # --- Run Script in Container ---
    echo "Running update script '$SCRIPT_DEST_IN_CONTAINER' inside container '$DOCKER_CONTAINER_NAME'..."
    if "${DOCKER_EXEC_CMD[@]}"; then
        echo "Update script finished successfully inside container for $DOCKER_CONTAINER_NAME."
        echo "Attempting to copy report '$report_source_path_container' from container to '$report_dest_path_host'..."
        if docker cp "$DOCKER_CONTAINER_NAME:$report_source_path_container" "$report_dest_path_host"; then
            echo "Report file copied successfully to $report_dest_path_host."
        else
            echo "WARNING: Failed to copy report file from container for $DOCKER_CONTAINER_NAME. Does it exist at '$report_source_path_container' inside the container?" >&2
        fi
    else
        script_exit_code=$?
        echo "WARNING: Update script failed inside container for $DOCKER_CONTAINER_NAME (Exit Code: $script_exit_code). Check container logs or output above." >&2
        echo "Attempting to copy potentially incomplete report '$report_source_path_container' from container..."
        if docker cp "$DOCKER_CONTAINER_NAME:$report_source_path_container" "$report_dest_path_host"; then
            echo "Potentially incomplete report file copied to $report_dest_path_host."
        else
            echo "WARNING: Failed to copy report file from container after script failure for $DOCKER_CONTAINER_NAME." >&2
        fi
    fi

    # --- Cleanup Injected Script ---
    echo "Removing injected script '$SCRIPT_DEST_IN_CONTAINER' from container '$DOCKER_CONTAINER_NAME'..."
    if ! docker exec "$DOCKER_CONTAINER_NAME" rm -f "$SCRIPT_DEST_IN_CONTAINER"; then
        echo "WARNING: Failed to remove injected script '$SCRIPT_DEST_IN_CONTAINER' from container '$DOCKER_CONTAINER_NAME'." >&2
    fi

    echo "---"
done

echo "Batch WordPress update process completed."
echo "Reports collected in: $REPORT_BATCH_DIR_HOST"
exit 0

