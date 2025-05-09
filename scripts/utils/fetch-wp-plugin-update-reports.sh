#!/bin/bash

# Default values
DEFAULT_HOST_REPORTS_BASE_DIR="wp-plugin-update-reports"
DEFAULT_REPORTS_PATH_IN_CONTAINER="/var/www/html"
DRY_RUN_FLAG=false

# --- Helper Functions ---
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --host-dir <path>         Set the base directory on the host for storing reports."
    echo "                            (Default: $DEFAULT_HOST_REPORTS_BASE_DIR)"
    echo "  --container-path <path>   Set the path inside Docker containers where reports are located."
    echo "                            (Default: $DEFAULT_REPORTS_PATH_IN_CONTAINER)"
    echo "  --dry-run                 Print actions that would be taken without performing them."
    echo "  -h, --help                Display this help message."
    exit 1
}

# --- Argument Parsing ---
HOST_REPORTS_BASE_DIR="$DEFAULT_HOST_REPORTS_BASE_DIR"
REPORTS_PATH_IN_CONTAINER="$DEFAULT_REPORTS_PATH_IN_CONTAINER"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --host-dir)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "ERROR: Missing value for --host-dir flag." >&2
                usage
            fi
            HOST_REPORTS_BASE_DIR="$2"
            shift 2
            ;;
        --container-path)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "ERROR: Missing value for --container-path flag." >&2
                usage
            fi
            REPORTS_PATH_IN_CONTAINER="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN_FLAG=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage
            ;;
    esac
done

# Files to copy
REPORT_FILES=("update-results.md" "health-check-results.log")

if [ "$DRY_RUN_FLAG" = true ]; then
    echo "*** DRY RUN MODE ENABLED ***"
fi

# 1. Create the base reports directory on the host if it doesn't exist
if [ "$DRY_RUN_FLAG" = true ]; then
    echo " [DRY RUN] Would create directory: $(pwd)/$HOST_REPORTS_BASE_DIR"
else
    mkdir -p "$HOST_REPORTS_BASE_DIR"
fi
echo "Reports will be stored in: $(pwd)/$HOST_REPORTS_BASE_DIR"
echo "Reports will be sourced from '$REPORTS_PATH_IN_CONTAINER' within containers."


# 2. Fetch all Docker container names
echo "Fetching Docker container names..."
# Using --format '{{.Names}}' is more reliable than awk for just names
docker_containers=$(docker ps --format '{{.Names}}')

if [ -z "$docker_containers" ]; then
    echo "No running Docker containers found."
    exit 0
fi

# 3. Iterate through containers and process those starting with "wp_"
found_wp_container=false
for container_name in $docker_containers; do
    # Grep for containers starting with wp_
    if [[ "$container_name" == wp_* ]]; then
        found_wp_container=true
        echo "Processing container: $container_name"

        # 4. Create a directory for this container's reports on the host
        container_report_dir="$HOST_REPORTS_BASE_DIR/$container_name"
        if [ "$DRY_RUN_FLAG" = true ]; then
            echo " [DRY RUN] Would create directory for container reports: $container_report_dir"
        else
            mkdir -p "$container_report_dir"
        fi

        # 5. Copy the report files
        for report_file in "${REPORT_FILES[@]}"; do
            source_path_in_container="${REPORTS_PATH_IN_CONTAINER}/${report_file}"
            destination_path_on_host="${container_report_dir}/${report_file}"

            echo "  Attempting to copy '$source_path_in_container' from '$container_name' to '$destination_path_on_host'..."
            if [ "$DRY_RUN_FLAG" = true ]; then
                echo "    [DRY RUN] Would copy '$source_path_in_container' from '$container_name' to '$destination_path_on_host'"
            else
                if docker cp "${container_name}:${source_path_in_container}" "$destination_path_on_host" &> /dev/null; then
                    echo "    Successfully copied $report_file."
                else
                    echo "    WARNING: Failed to copy $report_file from $container_name. It might not exist at $source_path_in_container, or there was a permissions issue."
                fi
            fi
        done
        echo "---"
    fi
done

if [ "$found_wp_container" = false ]; then
    echo "No Docker containers found starting with 'wp_'."
fi

echo "Report fetching process complete."