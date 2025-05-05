#!/bin/bash

# Utility script to generate a batch execution script for wp-plugin-update.sh
# based on running Docker containers (assumes Docker Compose conventions).
# This version copies the update script into each container before running.

# --- Configuration ---
# Path to the batch runner script that will be invoked in the generated script
BATCH_RUNNER_SCRIPT="./batch-wp-plugin-update-runner-docker.sh" # Assumes it's in the current dir
# Name of the generated script
GENERATED_SCRIPT_NAME="run_all_updates.sh"
# Default path where WP files reside *inside* the containers
DEFAULT_CONTAINER_WP_PATH="/var/www/html"
# Default service name label to look for
DEFAULT_SERVICE_LABEL_VALUE="wordpress"

# --- Flags ---
HOST_PROJECTS_BASE="" # MANDATORY: Base directory on host containing WP project folders
UPDATE_SCRIPT_HOST_PATH="" # MANDATORY: Path to wp-plugin-update.sh on the HOST machine
SCRIPT_DEST_PATH_IN_CONTAINER="" # MANDATORY: Destination path for wp-plugin-update.sh INSIDE containers
CONTAINER_WP_PATH="$DEFAULT_CONTAINER_WP_PATH"
SERVICE_LABEL_VALUE="$DEFAULT_SERVICE_LABEL_VALUE"
DRY_RUN_MODE=false # Flag to add --dry-run to generated commands (set by --dry-run)

# --- Argument Parsing ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --host-projects-base)
            if [[ -z "$2" || "$2" == --* ]]; then echo "ERROR: Missing value for --host-projects-base flag." >&2; exit 1; fi
            HOST_PROJECTS_BASE="$2"; shift 2 ;;
        --update-script-host-path)
            if [[ -z "$2" || "$2" == --* ]]; then echo "ERROR: Missing value for --update-script-host-path flag." >&2; exit 1; fi
            UPDATE_SCRIPT_HOST_PATH="$2"; shift 2 ;;
        --script-dest-path-in-container)
            if [[ -z "$2" || "$2" == --* ]]; then echo "ERROR: Missing value for --script-dest-path-in-container flag." >&2; exit 1; fi
            SCRIPT_DEST_PATH_IN_CONTAINER="$2"; shift 2 ;;
        --container-wp-path)
            if [[ -z "$2" || "$2" == --* ]]; then echo "ERROR: Missing value for --container-wp-path flag." >&2; exit 1; fi
            CONTAINER_WP_PATH="$2"; shift 2 ;;
        --service-name) # Allow specifying the service name label value
            if [[ -z "$2" || "$2" == --* ]]; then echo "ERROR: Missing value for --service-name flag." >&2; exit 1; fi
            SERVICE_LABEL_VALUE="$2"; shift 2 ;;
        --dry-run) # Renamed flag from --add-dry-run
            DRY_RUN_MODE=true; shift ;; # Sets the flag to add --dry-run to generated commands
        --batch-runner-path) # Optional path to the batch runner script itself
             if [[ -z "$2" || "$2" == --* ]]; then echo "ERROR: Missing value for --batch-runner-path flag." >&2; exit 1; fi
            BATCH_RUNNER_SCRIPT="$2"; shift 2 ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            echo "Usage: $0 --host-projects-base <path> --update-script-host-path <path> --script-dest-path-in-container <path> \\" >&2
            echo "          [--container-wp-path <path>] [--service-name <name>] [--dry-run] [--batch-runner-path <path>]" >&2
            exit 1
            ;;
    esac
done

# --- Pre-flight Checks ---
if [[ -z "$HOST_PROJECTS_BASE" ]]; then echo "ERROR: --host-projects-base flag is required." >&2; exit 1; fi
if [[ -z "$UPDATE_SCRIPT_HOST_PATH" ]]; then echo "ERROR: --update-script-host-path flag is required." >&2; exit 1; fi
if [[ -z "$SCRIPT_DEST_PATH_IN_CONTAINER" ]]; then echo "ERROR: --script-dest-path-in-container flag is required." >&2; exit 1; fi

if [ ! -d "$HOST_PROJECTS_BASE" ]; then echo "ERROR: Host projects base directory not found: '$HOST_PROJECTS_BASE'" >&2; exit 1; fi
if [ ! -f "$UPDATE_SCRIPT_HOST_PATH" ]; then echo "ERROR: Update script not found on host at: '$UPDATE_SCRIPT_HOST_PATH'" >&2; exit 1; fi
if [ ! -x "$UPDATE_SCRIPT_HOST_PATH" ]; then echo "WARNING: Update script on host ('$UPDATE_SCRIPT_HOST_PATH') is not executable. Will attempt to chmod in container." >&2; fi

if ! command -v docker &> /dev/null; then echo "ERROR: 'docker' command not found." >&2; exit 1; fi
if ! command -v jq &> /dev/null; then echo "ERROR: 'jq' command not found." >&2; exit 1; fi # jq is needed for inspect parsing
if [ ! -x "$BATCH_RUNNER_SCRIPT" ]; then echo "ERROR: Batch runner script '$BATCH_RUNNER_SCRIPT' not found or not executable." >&2; exit 1; fi

# Ensure HOST_PROJECTS_BASE is absolute for consistency
HOST_PROJECTS_BASE_ABS=$(realpath "$HOST_PROJECTS_BASE")
# Ensure update script host path is absolute for docker cp
UPDATE_SCRIPT_HOST_PATH_ABS=$(realpath "$UPDATE_SCRIPT_HOST_PATH")


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
echo "Searching for running Docker containers with service label '$SERVICE_LABEL_VALUE'..."

# Find container IDs based on the service label
# Use Go template for cleaner output: ID<space>ProjectName<space>ServiceName
mapfile -t CONTAINER_INFO < <(docker ps \
    --filter "label=com.docker.compose.service=${SERVICE_LABEL_VALUE}" \
    --format '{{.ID}} {{.Label "com.docker.compose.project"}} {{.Label "com.docker.compose.service"}}')

if [ ${#CONTAINER_INFO[@]} -eq 0 ]; then
    echo "No running containers found with the label 'com.docker.compose.service=${SERVICE_LABEL_VALUE}'."
    exit 0
fi

echo "Found ${#CONTAINER_INFO[@]} potential container(s). Generating script '$GENERATED_SCRIPT_NAME'..."

# Start generating the script
echo "#!/bin/bash" > "$GENERATED_SCRIPT_NAME"
echo "# Auto-generated script by generate_batch_runner.sh on $(date)" >> "$GENERATED_SCRIPT_NAME"
echo "" >> "$GENERATED_SCRIPT_NAME"
echo "# Ensure the batch runner script is executable" >> "$GENERATED_SCRIPT_NAME"
echo "chmod +x \"$BATCH_RUNNER_SCRIPT\" || { echo \"ERROR: Failed to make batch runner executable.\"; exit 1; }" >> "$GENERATED_SCRIPT_NAME"
echo "" >> "$GENERATED_SCRIPT_NAME"


# Process each found container
processed_projects=()
for line in "${CONTAINER_INFO[@]}"; do
    # Parse the line (ID Project Service)
    read -r container_id project_name service_name <<< "$line"

    if [[ -z "$project_name" ]]; then
        echo "WARNING: Could not determine project name from labels for container ID '$container_id'. Skipping."
        continue
    fi

     # Avoid processing the same project multiple times if multiple containers match (e.g., scale > 1)
    found=0
    for processed in "${processed_projects[@]}"; do
        if [[ "$processed" == "$project_name" ]]; then
            found=1
            break
        fi
    done
    [[ $found -eq 1 ]] && continue
    processed_projects+=("$project_name")

    # Construct the expected host path based on the project name label
    host_project_path="$HOST_PROJECTS_BASE_ABS/$project_name"

    # Basic check if the derived host path exists
    if [ ! -d "$host_project_path" ]; then
        echo "WARNING: Derived host path '$host_project_path' for project '$project_name' does not exist. Skipping."
        continue
    fi

    echo "Adding commands for project: '$project_name' (Host: '$host_project_path', Container: '$container_id')"

    # --- Add commands to the generated script ---
    echo "# --- Project: $project_name ---" >> "$GENERATED_SCRIPT_NAME"

    # 1. Copy the update script into the container
    echo "echo \"[$project_name] Copying update script to container '$container_id'...\"" >> "$GENERATED_SCRIPT_NAME"
    # Use double quotes to allow variable expansion
    echo "docker cp \"$UPDATE_SCRIPT_HOST_PATH_ABS\" \"${container_id}:${SCRIPT_DEST_PATH_IN_CONTAINER}\" || echo \"WARNING: [$project_name] Failed to copy script to $container_id\"" >> "$GENERATED_SCRIPT_NAME"
    # 2. Make the script executable inside the container (important!)
    echo "echo \"[$project_name] Setting execute permissions on script in container '$container_id'...\"" >> "$GENERATED_SCRIPT_NAME"
    echo "docker exec \"$container_id\" chmod +x \"$SCRIPT_DEST_PATH_IN_CONTAINER\" || echo \"WARNING: [$project_name] Failed to chmod script in $container_id\"" >> "$GENERATED_SCRIPT_NAME"

    # 3. Build the command arguments for the batch runner script
    cmd_line="\"$BATCH_RUNNER_SCRIPT\" \\"
    cmd_line+="\n    --target-dir \"$host_project_path\" \\" # Batch runner still needs host path for context
    cmd_line+="\n    --script-path-in-container \"$SCRIPT_DEST_PATH_IN_CONTAINER\" \\" # Tell batch runner where script is in container
    cmd_line+="\n    --container-wp-path \"$CONTAINER_WP_PATH\" \\"
    cmd_line+="\n    --service-name \"$service_name\" \\" # Pass service name for container lookup within batch runner
    cmd_line+="\n    --container \"$container_id\"" # Explicitly pass the found container ID

    # Add optional flags if needed
    # Use the renamed DRY_RUN_MODE variable
    if [ "$DRY_RUN_MODE" = true ]; then
        cmd_line+=" \\ \n    --dry-run"
    fi
    # Note: --subdir could potentially be added here if it's consistent across projects,
    # otherwise it might need manual addition or a more complex discovery mechanism.

    # 4. Add the command to execute the batch runner script
    echo "echo \"[$project_name] Executing batch runner for container '$container_id'...\"" >> "$GENERATED_SCRIPT_NAME"
    echo -e "$cmd_line" >> "$GENERATED_SCRIPT_NAME"
    echo "echo \"[$project_name] Finished processing.\"" >> "$GENERATED_SCRIPT_NAME"
    echo "" >> "$GENERATED_SCRIPT_NAME"

done

# Make the generated script executable
chmod +x "$GENERATED_SCRIPT_NAME"

echo "---"
echo "Generated script '$GENERATED_SCRIPT_NAME' successfully."
echo "Review the script, then run it: ./$GENERATED_SCRIPT_NAME"

exit 0

