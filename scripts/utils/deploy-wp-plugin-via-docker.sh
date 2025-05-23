#!/bin/bash

# Bash Script to Deploy and Activate WordPress Plugin in Dockerized Sites
#
# Assumes:
# 1. WordPress sites are in individual Docker containers.
# 2. The name of the site's directory in SITES_BASE_DIR (e.g., "example.com")
#    is also the name of the Docker container.
# 3. WP-CLI is installed and accessible within each Docker container.
# 4. The user running this script has sudo privileges for Docker commands.

# --- Default Configuration ---
# These can be overridden by command-line flags.
DEFAULT_PLUGIN_SOURCE_DIR=""
DEFAULT_PLUGIN_SLUG=""
DEFAULT_SITES_BASE_DIR="/var/opt" # Default as per original request

# WP-CLI executable name or full path INSIDE the Docker container.
# This is not currently a flag but could be added if needed.
WP_CLI_COMMAND="wp"

# WordPress installation path INSIDE the Docker container.
WP_PATH_IN_CONTAINER="/var/www/html"
# WordPress plugins directory path INSIDE the Docker container.
# This is derived from WP_PATH_IN_CONTAINER.
WP_PLUGINS_DIR_IN_CONTAINER="${WP_PATH_IN_CONTAINER}/wp-content/plugins/"

# --- Script Variables ---
PLUGIN_SOURCE_DIR=""
PLUGIN_SLUG=""
SITES_BASE_DIR=""
DRY_RUN=0 # 0 for false, 1 for true

# --- Helper Functions ---
usage() {
    echo "Usage: $0 -p <plugin_source_dir> -s <plugin_slug> [-b <sites_base_dir>] [--dry-run]"
    echo ""
    echo "Arguments:"
    echo "  -p, --plugin-source DIR    Path to the UNZIPPED plugin directory on the HOST machine (Required)."
    echo "  -s, --plugin-slug SLUG     The slug of the plugin (directory name) (Required)."
    echo "  -b, --base-dir DIR         Base directory on the HOST containing site directories."
    echo "                             (Default: ${DEFAULT_SITES_BASE_DIR})"
    echo "      --wp-cli-command CMD   WP-CLI command/path in container (Default: ${WP_CLI_COMMAND})."
    echo "      --wp-path PATH         WordPress path in container (Default: ${WP_PATH_IN_CONTAINER})."
    echo "      --dry-run              Simulate execution without making changes."
    echo "  -h, --help                 Display this help message."
    exit 1
}

# Function to display error messages and exit
error_exit() {
    echo "Error: $1" >&2
    exit 1
}

# --- Argument Parsing ---
# Using getopt for robust argument parsing.
# Note: `getopt` utility might differ slightly between Linux and macOS.
# This script uses the Linux version of getopt. For macOS, you might need `brew install gnu-getopt`.
TEMP=$(getopt -o p:s:b:h --long plugin-source:,plugin-slug:,base-dir:,wp-cli-command:,wp-path:,dry-run,help \
             -n "$0" -- "$@")

if [ $? != 0 ] ; then echo "Terminating..." >&2 ; exit 1 ; fi

# Note the quotes around "$TEMP": they are essential!
eval set -- "$TEMP"

while true; do
  case "$1" in
    -p | --plugin-source ) PLUGIN_SOURCE_DIR="$2"; shift 2 ;;
    -s | --plugin-slug )   PLUGIN_SLUG="$2"; shift 2 ;;
    -b | --base-dir )      SITES_BASE_DIR="$2"; shift 2 ;;
    --wp-cli-command )     WP_CLI_COMMAND="$2"; shift 2;;
    --wp-path )            
        WP_PATH_IN_CONTAINER="$2";
        WP_PLUGINS_DIR_IN_CONTAINER="${WP_PATH_IN_CONTAINER}/wp-content/plugins/"; # Re-calculate
        shift 2 ;;
    --dry-run )            DRY_RUN=1; shift ;;
    -h | --help )          usage ;;
    -- )                   shift; break ;; # End of options
    * )                    break ;; # Default case
  esac
done

# Set defaults if not provided by flags
if [ -z "$SITES_BASE_DIR" ]; then
    SITES_BASE_DIR="$DEFAULT_SITES_BASE_DIR"
fi

# --- Configuration Validation ---
if [ -z "$PLUGIN_SOURCE_DIR" ]; then
    error_exit "Plugin source directory (-p or --plugin-source) is required. Use -h for help."
fi
if [ -z "$PLUGIN_SLUG" ]; then
    error_exit "Plugin slug (-s or --plugin-slug) is required. Use -h for help."
fi
if [ ! -d "$PLUGIN_SOURCE_DIR" ]; then
    error_exit "Plugin source directory '$PLUGIN_SOURCE_DIR' not found or is not a directory."
fi

# Sanity check: basename of PLUGIN_SOURCE_DIR should ideally match PLUGIN_SLUG
if [ "$(basename "$PLUGIN_SOURCE_DIR")" != "$PLUGIN_SLUG" ]; then
    echo "Warning: The basename of PLUGIN_SOURCE_DIR ('$(basename "$PLUGIN_SOURCE_DIR")') does not match PLUGIN_SLUG ('$PLUGIN_SLUG')."
    echo "The script will proceed, but ensure PLUGIN_SLUG ('$PLUGIN_SLUG') is the correct directory name for the plugin as it will appear in wp-content/plugins/ after copying."
    echo "The directory copied into the container will be named '$(basename "$PLUGIN_SOURCE_DIR")'."
    echo "If this is not '$PLUGIN_SLUG', WP-CLI might not find the plugin correctly by slug."
    echo "Consider renaming PLUGIN_SOURCE_DIR to match PLUGIN_SLUG or ensure PLUGIN_SLUG is $(basename "$PLUGIN_SOURCE_DIR")."
fi

# --- Script Logic ---
echo "Starting plugin deployment and activation process..."
if [ "$DRY_RUN" -eq 1 ]; then
    echo "*** DRY RUN MODE ENABLED - NO CHANGES WILL BE MADE ***"
fi
echo "Plugin Source Host Path: $PLUGIN_SOURCE_DIR"
echo "Plugin Slug (and target directory name in container): $PLUGIN_SLUG"
echo "Sites Base Directory (Host): $SITES_BASE_DIR"
echo "WP-CLI command in container: $WP_CLI_COMMAND"
echo "WordPress path in container: $WP_PATH_IN_CONTAINER"
echo "WordPress plugins path in container: $WP_PLUGINS_DIR_IN_CONTAINER"
echo "-----------------------------------------------------"

# Ensure SITES_BASE_DIR ends with a slash for the loop glob to work correctly if it was `/var/opt`
# This is not strictly necessary for the find command but good practice for path concatenation.
[[ "$SITES_BASE_DIR" != */ ]] && SITES_BASE_DIR="${SITES_BASE_DIR}/"

# Loop through directories in SITES_BASE_DIR using find for robustness (handles spaces, etc.)
# -maxdepth 1: Don't go into sub-subdirectories
# -mindepth 1: Don't include SITES_BASE_DIR itself
# -type d: Only find directories
find "$SITES_BASE_DIR" -maxdepth 1 -mindepth 1 -type d -print0 | while IFS= read -r -d $'\0' site_dir_host_path; do
    site_name=$(basename "$site_dir_host_path")

    # Check if the directory name contains ".com".
    if [[ "$site_name" == *".com"* ]]; then
        echo "Processing site directory (and assumed container name): $site_name"

        container_name="$site_name" # Assuming directory name is container name

        # Check if container exists and is running
        if [ "$DRY_RUN" -eq 0 ]; then # Only perform actual checks if not a dry run
            if ! sudo docker inspect "$container_name" &>/dev/null; then
                echo "Info: Container '$container_name' does not exist. Skipping."
                echo "-----------------------------------------------------"
                continue
            fi
            if ! sudo docker inspect -f '{{.State.Running}}' "$container_name" | grep -q "true"; then
                echo "Warning: Container '$container_name' exists but is not running. Skipping."
                echo "-----------------------------------------------------"
                continue
            fi
        else
            echo "[DRY RUN] Would check if container '$container_name' exists and is running."
        fi


        echo "Attempting to copy plugin from '$PLUGIN_SOURCE_DIR' to container '$container_name'..."
        # The copied directory will have the name `basename "$PLUGIN_SOURCE_DIR"`.
        # This should match $PLUGIN_SLUG for `wp plugin activate $PLUGIN_SLUG` to work.
        target_plugin_path_in_container="${WP_PLUGINS_DIR_IN_CONTAINER}$(basename "$PLUGIN_SOURCE_DIR")"

        if [ "$DRY_RUN" -eq 1 ]; then
            echo "[DRY RUN] Would execute: sudo docker cp \"${PLUGIN_SOURCE_DIR}\" \"${container_name}:${WP_PLUGINS_DIR_IN_CONTAINER}\""
            copy_success=true # Assume success for dry run to proceed to next step
        else
            if sudo docker cp "${PLUGIN_SOURCE_DIR}" "${container_name}:${WP_PLUGINS_DIR_IN_CONTAINER}"; then
                copy_success=true
            else
                copy_success=false
            fi
        fi

        if [ "$copy_success" = true ]; then
            echo "Plugin files copied (or would be copied) to '${target_plugin_path_in_container}' in container '$container_name'."

            echo "Attempting to activate plugin '$PLUGIN_SLUG' in '$container_name' as root..."
            
            # WP-CLI command to be executed
            wp_cli_full_command=("${WP_CLI_COMMAND}" plugin activate "${PLUGIN_SLUG}" --path="${WP_PATH_IN_CONTAINER}")
            
            echo "Executing (or would execute) in container: sudo docker exec -u root ${container_name} ${wp_cli_full_command[*]}"
            
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "[DRY RUN] Would execute WP-CLI command. Assuming success for simulation."
                # Simulate output for dry run
                echo "WP-CLI Output: [DRY RUN] Success: Plugin '$PLUGIN_SLUG' activated."
            else
                # Execute the command and capture combined stdout/stderr
                exec_output=$(sudo docker exec -u root "${container_name}" "${wp_cli_full_command[@]}" 2>&1)
                exec_status=$? # Capture exit status of the docker exec command

                if [ $exec_status -eq 0 ]; then
                    echo "SUCCESS: Plugin '$PLUGIN_SLUG' activation command successful for '$site_name'."
                    echo "WP-CLI Output: $exec_output"
                else
                    echo "ERROR: Failed to activate plugin '$PLUGIN_SLUG' for '$site_name'. WP-CLI Exit Status: $exec_status"
                    echo "WP-CLI Output: $exec_output"
                    echo "Please check:"
                    echo "1. If the plugin slug '$PLUGIN_SLUG' matches the directory name copied into the container: '$(basename "$PLUGIN_SOURCE_DIR")'."
                    echo "2. If the plugin files at '${target_plugin_path_in_container}' are valid."
                    echo "3. If WP-CLI ('${WP_CLI_COMMAND}') is correctly configured and working in container '$container_name'."
                fi
            fi
        else
            echo "ERROR: Failed to copy plugin from '$PLUGIN_SOURCE_DIR' to container '$container_name'."
            echo "Verify Docker permissions, host path, and container name/plugins path."
        fi
        echo "-----------------------------------------------------"
    else
        # This part is for directories that do not match the ".com" criteria
        # echo "Skipping directory (name '$site_name' does not contain '.com'): $site_dir_host_path"
        : # No-op, placeholder for skipped directories
    fi
done

echo "Plugin deployment and activation process finished."
if [ "$DRY_RUN" -eq 1 ]; then
    echo "*** DRY RUN MODE WAS ENABLED - NO ACTUAL CHANGES WERE MADE ***"
fi
