#!/bin/bash

# --- Configuration ---
# Full path to the update script *inside* the Docker containers
UPDATE_SCRIPT_CONTAINER_PATH="" # MANDATORY: Set this via flag
# The standard path where WP files reside *inside* the containers
CONTAINER_WP_PATH="/var/www/html" # Default, override with --container-wp-path
# The typical service name in docker-compose for the container running WP-CLI
SERVICE_NAME="wordpress" # Default, override with --service-name

# Default directory on the HOST to scan for WP project roots
DEFAULT_TARGET_DIR="."
# Directory on the HOST to store the generated reports
REPORT_DIR_NAME="report-batch"
# Default report format for the underlying script
REPORT_FORMAT="md" # Use 'md' or 'html'

# --- Flags ---
TARGET_DIR="$DEFAULT_TARGET_DIR"
DRY_RUN_MODE=false # Initialize dry-run flag
SUBDIR_PATH=""     # Initialize subdir path flag (relative path *within* CONTAINER_WP_PATH)

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
        --script-path-in-container)
             if [[ -z "$2" || "$2" == --* ]]; then echo "ERROR: Missing value for --script-path-in-container flag." >&2; exit 1; fi
            UPDATE_SCRIPT_CONTAINER_PATH="$2"; shift 2 ;;
        --container-wp-path)
             if [[ -z "$2" || "$2" == --* ]]; then echo "ERROR: Missing value for --container-wp-path flag." >&2; exit 1; fi
            CONTAINER_WP_PATH="$2"; shift 2 ;;
        --service-name)
             if [[ -z "$2" || "$2" == --* ]]; then echo "ERROR: Missing value for --service-name flag." >&2; exit 1; fi
            SERVICE_NAME="$2"; shift 2 ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            echo "Usage: $0 [--target-dir <dir>] [--dry-run] [--subdir <path>]" >&2
            echo "          --script-path-in-container <path> [--container-wp-path <path>] [--service-name <name>]" >&2
            exit 1
            ;;
    esac
done

# --- Pre-flight Checks ---

# Check mandatory flags
if [[ -z "$UPDATE_SCRIPT_CONTAINER_PATH" ]]; then echo "ERROR: --script-path-in-container flag is required." >&2; exit 1; fi

# Check if the target directory exists on the host
if [ ! -d "$TARGET_DIR" ]; then
    echo "ERROR: Target directory not found: $TARGET_DIR" >&2
    exit 1
fi

# Check if docker command exists
if ! command -v docker &> /dev/null; then
    echo "ERROR: 'docker' command not found. Please install Docker." >&2
    exit 1
fi

# --- Helper Function ---
find_container_for_project() {
    local project_dir_name="$1"
    local service_name="$2"
    local container_name=""

    # Try common docker-compose naming conventions
    local potential_names=(
        "${project_dir_name}_${service_name}_1"
        "${project_dir_name}-${service_name}-1"
        "${project_dir_name}_${service_name}-1" # Handle potential hyphen in service name from compose file
        "${project_dir_name}-${service_name}_1" # Handle potential hyphen in project name
        "${service_name}" # Sometimes used in simpler setups or non-compose
    )

    for name in "${potential_names[@]}"; do
        # Use docker ps to check if a container with this name is running
        container_name=$(docker ps --filter "name=^/${name}$" --format '{{.Names}}' | head -n 1)
        if [[ -n "$container_name" ]]; then
            echo "$container_name" # Return the found name
            return 0 # Success
        fi
    done

    # If no match found with conventions, try filtering by label if applicable (requires labels to be set)
    # Example label: com.docker.compose.project=project_dir_name and com.docker.compose.service=service_name
    # container_name=$(docker ps --filter "label=com.docker.compose.project=${project_dir_name}" --filter "label=com.docker.compose.service=${service_name}" --format '{{.Names}}' | head -n 1)
    # if [[ -n "$container_name" ]]; then
    #     echo "$container_name"
    #     return 0
    # fi

    return 1 # Failure
}


# --- Main Logic ---

echo "Starting batch WordPress update process (Per-Site Docker Mode)..."
echo "Host Target Directory: $TARGET_DIR"
if [ "$DRY_RUN_MODE" = true ]; then
    echo "Dry Run Mode: ENABLED (Will pass --dry-run to update script)"
fi
if [[ -n "$SUBDIR_PATH" ]]; then
    echo "Subdirectory Path (within container WP path): '$SUBDIR_PATH'"
fi
echo "Script Path in Container: '$UPDATE_SCRIPT_CONTAINER_PATH'"
echo "WordPress Path in Container: '$CONTAINER_WP_PATH'"
echo "WP-CLI Service Name Hint: '$SERVICE_NAME'"


# Get the absolute path of the target directory on the host
TARGET_DIR_ABS=$(realpath "$TARGET_DIR")
echo "Absolute Host Target Directory: $TARGET_DIR_ABS"

# Define and create the report batch directory on the HOST
REPORT_BATCH_DIR="$TARGET_DIR_ABS/$REPORT_DIR_NAME"
mkdir -p "$REPORT_BATCH_DIR" || { echo "ERROR: Could not create report directory: $REPORT_BATCH_DIR"; exit 1; }
echo "Host Report Directory: $REPORT_BATCH_DIR"

# Find potential project root directories on the HOST (containing docker-compose.yml or just subdirs)
# We look for directories one level down from the target dir
echo "Searching for potential project directories in '$TARGET_DIR_ABS'..."
mapfile -t WP_HOST_DIRS < <(find "$TARGET_DIR_ABS" -maxdepth 1 -mindepth 1 -type d) # Find immediate subdirectories

# Also consider the target directory itself if it might be a single project root
if [[ $(find "$TARGET_DIR_ABS" -maxdepth 1 -name "wp-config.php" -type f -printf '%h\n' | wc -l) -gt 0 || $(find "$TARGET_DIR_ABS" -maxdepth 1 -name "docker-compose.yml" -type f -printf '%h\n' | wc -l) -gt 0 ]]; then
    WP_HOST_DIRS+=("$TARGET_DIR_ABS")
fi


if [ ${#WP_HOST_DIRS[@]} -eq 0 ]; then
    echo "No potential WordPress project directories found in '$TARGET_DIR_ABS'."
    exit 0
fi

echo "Found ${#WP_HOST_DIRS[@]} potential WordPress project root(s):"
printf "  %s\n" "${WP_HOST_DIRS[@]}" | sort -u # Print unique paths
echo "---"

# Process unique directories
processed_dirs=()
for wp_host_dir_raw in "${WP_HOST_DIRS[@]}"; do
    wp_host_dir=$(realpath "$wp_host_dir_raw") # Ensure absolute path

    # Skip if already processed (handles duplicates if target dir itself was added)
    found=0
    for processed in "${processed_dirs[@]}"; do
        if [[ "$processed" == "$wp_host_dir" ]]; then
            found=1
            break
        fi
    done
    [[ $found -eq 1 ]] && continue
    processed_dirs+=("$wp_host_dir")


    echo "Processing Host Project Root: $wp_host_dir"

    # --- Find the Container ---
    dir_basename=$(basename "$wp_host_dir")
    # Sanitize directory name for container lookup (replace non-alphanumeric with underscore)
    sanitized_dir_basename=$(echo "$dir_basename" | sed 's/[^a-zA-Z0-9_]/_/g')

    echo "Attempting to find container for project '$dir_basename' with service name '$SERVICE_NAME'..."
    DOCKER_CONTAINER=$(find_container_for_project "$sanitized_dir_basename" "$SERVICE_NAME")

    if [[ -z "$DOCKER_CONTAINER" ]]; then
        echo "WARNING: Could not find a running container for project '$dir_basename' using service name '$SERVICE_NAME' and common naming conventions. Skipping."
        echo "---"
        continue
    fi
    echo "INFO: Found container '$DOCKER_CONTAINER' for project '$dir_basename'."

    # --- Verify Script in Container ---
    if ! docker exec "$DOCKER_CONTAINER" test -x "$UPDATE_SCRIPT_CONTAINER_PATH"; then
         echo "ERROR: Update script '$UPDATE_SCRIPT_CONTAINER_PATH' not found or not executable INSIDE the container '$DOCKER_CONTAINER'. Skipping."
         echo "---"
         continue
    fi

    # --- Prepare for Execution ---
    # Report filename uses the host directory basename
    report_filename="update-results.$REPORT_FORMAT"
    report_dest_path_host="$REPORT_BATCH_DIR/${sanitized_dir_basename}-${report_filename}" # Destination on host
    # Expected report location *inside the container* (relative to container WP path)
    report_source_path_container="$CONTAINER_WP_PATH/$report_filename"

    # Construct the arguments for the update script INSIDE the container
    # The main path argument is the *container's* WP path
    SCRIPT_ARGS=("--print-results=$REPORT_FORMAT")
    if [ "$DRY_RUN_MODE" = true ]; then
        SCRIPT_ARGS+=("--dry-run")
    fi
    if [[ -n "$SUBDIR_PATH" ]]; then
        # Pass the subdir relative to the container's WP path
        SCRIPT_ARGS+=("--subdir" "$SUBDIR_PATH")
    fi
    SCRIPT_ARGS+=("$CONTAINER_WP_PATH") # Pass the CONTAINER's WP path as the main argument

    # Construct the full docker exec command
    # Use bash -c to properly handle argument expansion inside the container shell
    DOCKER_CMD=(docker exec -i "$DOCKER_CONTAINER" bash -c "$UPDATE_SCRIPT_CONTAINER_PATH ${SCRIPT_ARGS[*]@Q}") # @Q quotes args for the remote shell

    # --- Run Script in Container ---
    echo "Running update script inside container '$DOCKER_CONTAINER'..."
    if "${DOCKER_CMD[@]}"; then
        echo "Update script finished successfully inside container for $wp_host_dir."
        # Copy the report file FROM the container TO the host
        echo "Attempting to copy report '$report_source_path_container' from container to '$report_dest_path_host'..."
        if docker cp "$DOCKER_CONTAINER:$report_source_path_container" "$report_dest_path_host"; then
            echo "Report file copied successfully."
            # Optional: Remove the report file from inside the container
            # docker exec "$DOCKER_CONTAINER" rm -f "$report_source_path_container"
        else
            echo "WARNING: Failed to copy report file from container for $wp_host_dir. Does it exist at '$report_source_path_container' inside the container?"
        fi
    else
        warning_msg "Update script failed inside container for $wp_host_dir (Exit Code: $?). Check container logs or output above. Report file might not be generated or copied."
        # Attempt to copy report file even on failure
        echo "Attempting to copy potentially incomplete report '$report_source_path_container' from container..."
         if docker cp "$DOCKER_CONTAINER:$report_source_path_container" "$report_dest_path_host"; then
            echo "Potentially incomplete report file copied."
        else
            echo "WARNING: Failed to copy report file from container after script failure."
        fi
    fi
    echo "---"
done

echo "Batch WordPress update process completed."
echo "Reports collected in: $REPORT_BATCH_DIR"
exit 0

