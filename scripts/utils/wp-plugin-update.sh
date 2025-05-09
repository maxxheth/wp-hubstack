#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
# set -e # Keep disabled for detailed WP Doctor debugging

# --- Configuration ---
# Default values
BEDROCK_MODE=false
WP_DIR=""
SUBDIR_PATH="" # Relative path to WP install within WP_DIR
ALLOW_CHECK_ERRORS=false # Default: Exit on WP Doctor errors
PRINT_RESULTS_FORMAT="" # md, html, or empty (no report)
DRY_RUN_FLAG=false # Default: Perform actual updates and backups
# Default checks to exclude from WP Doctor error check
# Can be overridden by --exclude-checks flag. Use "none" to exclude nothing.
EXCLUDE_CHECKS_ARG="core-update"
# Log file for update status
UPDATE_STATUS_FILE="plugin-updates.txt"
# Health check results file (will store raw results from individual checks)
HEALTH_CHECK_FILE="health-check-results.log"
# Log file for successful updates (temporary - used even in dry run for reporting)
UPDATES_NEEDED_LOG="updates_needed.log" # Renamed for clarity
# Results file names
MARKDOWN_RESULTS_FILE="update-results.md"
HTML_RESULTS_FILE="update-results.html"

# Arrays to store update results for reporting
PLUGINS_TO_UPDATE=() # Store plugins identified as needing updates
SUCCESSFUL_PLUGINS=() # Store plugins successfully updated (only in non-dry-run)
FAILED_PLUGINS=()     # Store plugins that failed to update (only in non-dry-run)
FAILED_MESSAGES=()    # Store corresponding error messages for failures

# Arrays to store doctor check results for reporting
DOCTOR_CHECK_NAMES_RUN=()
DOCTOR_CHECK_STATUSES=()
DOCTOR_CHECK_MESSAGES=()

# --- Helper Functions ---
error_exit() {
    echo "ERROR: $1" >&2
    # Optional: Add cleanup steps here if needed before exiting
    exit 1
}

warning_msg() {
    echo "WARNING: $1" >&2
}

# Helper function to attempt to resolve apt/dpkg lock issues
resolve_apt_locks() {
    echo "INFO: Checking for apt/dpkg lock issues and attempting resolution..."
    local pgrep_procs
    # Check for running apt/dpkg processes
    pgrep_procs=$(pgrep -afx "apt|apt-get|dpkg")

    if [ -n "$pgrep_procs" ]; then
        warning_msg "Other apt/dpkg processes appear to be running. This can cause lock conflicts."
        echo "INFO: Detected processes:"
        echo "$pgrep_procs"
        echo "INFO: Waiting for 5 seconds to see if they complete..."
        sleep 5
        # Re-check
        pgrep_procs=$(pgrep -afx "apt|apt-get|dpkg")
        if [ -n "$pgrep_procs" ]; then
            warning_msg "apt/dpkg processes still seem to be running. Installation may fail. Manual intervention might be required if locks persist."
            # If processes are still running, we might choose not to remove locks to avoid interfering with a legitimate operation.
            # However, the original problem implies locks might be stale even if a process is detected (e.g. hung).
            # For this integration, we'll proceed with caution and attempt cleanup, as stale locks are the primary target.
            echo "INFO: Proceeding with lock cleanup despite detected processes, assuming they might be stale or hung."
        else
            echo "INFO: apt/dpkg processes seem to have finished."
        fi
    else
        echo "INFO: No other conflicting apt/dpkg processes detected."
    fi

    echo "INFO: Attempting to remove stale lock files (if any)..."
    rm -f /var/lib/dpkg/lock
    rm -f /var/lib/dpkg/lock-frontend
    rm -f /var/cache/apt/archives/lock
    rm -f /var/lib/apt/lists/lock
    echo "INFO: Stale lock file removal attempted."

    echo "INFO: Attempting to reconfigure dpkg packages (dpkg --configure -a)..."
    if dpkg --configure -a >/dev/null 2>&1; then
        echo "INFO: dpkg reconfigure successful or no action needed."
    else
        # Capture output only on error for brevity
        local dpkg_error
        dpkg_error=$(dpkg --configure -a 2>&1)
        warning_msg "dpkg --configure -a encountered issues. Output: $dpkg_error"
    fi

    echo "INFO: Running apt-get update -qq to refresh package lists..."
    if apt-get update -qq; then
        echo "INFO: apt-get update -qq successful."
    else
        warning_msg "apt-get update -qq failed after attempting lock resolution. Subsequent package installations will likely fail."
        # We don't error_exit here; let the install command fail and be caught by existing logic.
    fi
    echo "INFO: apt/dpkg lock resolution attempt finished."
}

# --- Argument Parsing ---
# Use a loop to handle flags before the directory argument
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --bedrock) BEDROCK_MODE=true; shift ;; # Set bedrock mode and remove the flag
        --allow-check-errors) ALLOW_CHECK_ERRORS=true; shift ;; # Allow script to continue despite WP Doctor errors
        --dry-run) DRY_RUN_FLAG=true; shift ;; # Enable dry run mode
        --subdir) # Handle subdir path
             if [[ -z "$2" || "$2" == --* ]]; then
                 error_exit "Missing value for --subdir flag."
            fi
            SUBDIR_PATH="$2"
            shift 2 ;; # Consume flag and value
        --exclude-checks) # Handle exclusion list
            # Check if the next argument ($2) exists and is not another flag starting with --
            if [[ -z "$2" || "$2" == --* ]]; then
                 error_exit "Missing value for --exclude-checks flag."
            fi
            EXCLUDE_CHECKS_ARG="$2"
            shift 2 ;; # Consume flag (--exclude-checks) and its value ($2)
        --print-results) # Handle results printing
            # Check if the next argument ($2) exists and is not another flag starting with --
            if [[ -n "$2" && "$2" != --* ]]; then
                # Check if the value is valid (md or html)
                if [[ "$2" == "md" || "$2" == "html" ]]; then
                    PRINT_RESULTS_FORMAT="$2"
                    shift 2 # Consume flag (--print-results) and its value ($2)
                else
                    # Value provided but invalid, treat as flag only (default to md)
                    warning_msg "Invalid format '$2' for --print-results. Defaulting to Markdown."
                    PRINT_RESULTS_FORMAT="md"
                    shift # Consume only the flag (--print-results)
                fi
            else
                # Flag provided without a value, default to md
                PRINT_RESULTS_FORMAT="md"
                shift # Consume only the flag (--print-results)
            fi
             ;;
        *) # Assume the first non-flag argument is the directory
           if [ -z "$WP_DIR" ]; then
               WP_DIR="$1"
           else
               # Handle unexpected extra arguments if necessary
               warning_msg "Ignoring unexpected argument: $1"
           fi
           shift ;; # Consume the directory path or the unexpected argument
    esac
done

# --- Pre-flight Checks ---
# Check if WP_DIR argument was captured
if [ -z "$WP_DIR" ]; then
    error_exit "Usage: $0 [--bedrock] [--dry-run] [--subdir <relative_path>] [--allow-check-errors] [--exclude-checks <check1,check2|none>] [--print-results[=md|html]] <path_to_wordpress_directory>"
fi

# Check if WP_DIR is a directory
if [ ! -d "$WP_DIR" ]; then
    error_exit "WordPress directory not found: $WP_DIR"
fi

# Check if wp-cli is installed
if ! command -v wp &> /dev/null; then
    error_exit "WP-CLI command 'wp' not found. Please install it."
fi

# Check if jq is installed (needed for wp doctor list and plugin checks)
if ! command -v jq &> /dev/null; then
    echo "INFO: 'jq' command not found. Attempting to install from source..."
    # Assuming script is run as root, sudo is not needed for apt-get or make install.

    # Check for wget
    if ! command -v wget &> /dev/null; then
        echo "INFO: 'wget' not found. Attempting to install via apt-get..."
        if ! command -v apt-get &> /dev/null; then
            error_exit "wget is not installed, and apt-get is not available. Please install wget manually."
        fi
        resolve_apt_locks
        if ! apt-get install -y wget; then
            error_exit "Failed to install wget using apt-get. Please install it manually."
        fi
        echo "INFO: wget installed successfully."
    fi

    # Check for tar
    if ! command -v tar &> /dev/null; then
        echo "INFO: 'tar' not found. Attempting to install via apt-get..."
        if ! command -v apt-get &> /dev/null; then
            error_exit "tar is not installed, and apt-get is not available. Please install tar manually."
        fi
        resolve_apt_locks
        if ! apt-get install -y tar; then
            error_exit "Failed to install tar using apt-get. Please install it manually."
        fi
        echo "INFO: tar installed successfully."
    fi

    # Check for make and build essentials (common for ./configure && make)
    if ! command -v make &> /dev/null; then
        echo "INFO: 'make' not found. Attempting to install 'make' and 'build-essential' via apt-get..."
        if ! command -v apt-get &> /dev/null; then
            error_exit "make is not installed, and apt-get is not available. Please install make and build tools (e.g., build-essential) manually."
        fi
        resolve_apt_locks
        # build-essential usually includes gcc, etc. needed for ./configure
        if ! apt-get install -y make build-essential; then
            error_exit "Failed to install make/build-essential using apt-get. Please install them manually."
        fi
        echo "INFO: make and build-essential installed successfully."
    fi

    JQ_VERSION="1.7.1"
    JQ_DOWNLOAD_URL="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-${JQ_VERSION}.tar.gz"
    JQ_TARBALL="jq-${JQ_VERSION}.tar.gz"
    JQ_SOURCE_DIR="jq-${JQ_VERSION}"
    TEMP_BUILD_DIR=$(mktemp -d)

    echo "INFO: Downloading jq from $JQ_DOWNLOAD_URL..."
    if ! wget -O "$TEMP_BUILD_DIR/$JQ_TARBALL" "$JQ_DOWNLOAD_URL"; then
        rm -rf "$TEMP_BUILD_DIR"
        error_exit "Failed to download jq tarball."
    fi

    echo "INFO: Extracting jq tarball..."
    if ! tar -xzf "$TEMP_BUILD_DIR/$JQ_TARBALL" -C "$TEMP_BUILD_DIR"; then
        rm -rf "$TEMP_BUILD_DIR"
        error_exit "Failed to extract jq tarball."
    fi

    cd "$TEMP_BUILD_DIR/$JQ_SOURCE_DIR" || { rm -rf "$TEMP_BUILD_DIR"; error_exit "Failed to change directory to jq source."; }

    echo "INFO: Configuring jq..."
    if ! ./configure --with-oniguruma=builtin; then # Add --with-oniguruma=builtin to avoid libonig-dev dependency
        cd "$WP_DIR" # Go back to original WP_DIR on failure
        rm -rf "$TEMP_BUILD_DIR"
        error_exit "Failed to configure jq. Check if build tools (gcc, autoconf, automake, libtool) are installed."
    fi

    echo "INFO: Compiling jq (make)..."
    if ! make -j"$(nproc)"; then
        cd "$WP_DIR"
        rm -rf "$TEMP_BUILD_DIR"
        error_exit "Failed to compile jq using make."
    fi

    echo "INFO: Installing jq (make install)..."
    if ! make install; then
        cd "$WP_DIR"
        rm -rf "$TEMP_BUILD_DIR"
        error_exit "Failed to install jq using make install."
    fi

    cd "$WP_DIR" # Change back to the original WordPress directory
    rm -rf "$TEMP_BUILD_DIR" # Clean up

    if ! command -v jq &> /dev/null; then
        error_exit "jq installation from source completed, but 'jq' command still not found. Check PATH or installation."
    fi
    echo "INFO: jq installed successfully from source."
else
    echo "INFO: 'jq' command found."
fi

# Check if awk is installed (needed for preparing exclusion list), try to install gawk if not
if ! command -v awk &> /dev/null; then
    echo "INFO: 'awk' command not found. Attempting to install 'gawk'..."
    if ! command -v apt-get &> /dev/null; then
        error_exit "awk is not installed, and apt-get is not available. Please install gawk manually."
    fi
    # Assuming script is run as root, sudo is not needed for apt-get.
    echo "INFO: Running: apt-get install -y gawk (after lock resolution)"
    resolve_apt_locks
    if apt-get install -y gawk; then
        echo "INFO: gawk installed successfully."
        if ! command -v awk &> /dev/null; then # Verify awk is now available
             error_exit "Verification failed after attempting to install gawk (awk command still not found). Please check the installation."
        fi
    else
        error_exit "Failed to install gawk using apt-get. Please install it manually."
    fi
else
    echo "INFO: 'awk' command found."
fi

# --- Set Paths Based on Mode ---
# These paths are relative to the PROJECT ROOT ($WP_DIR)
if [ "$BEDROCK_MODE" = true ]; then
    echo "Bedrock mode enabled."
    # Typical Bedrock structure paths (relative to project root WP_DIR)
    PLUGINS_DIR="web/app/plugins"
    BACKUP_PARENT_DIR="web/app" # Backup will be created inside this directory
    # Check if these directories exist within WP_DIR
    if [ ! -d "$WP_DIR/$PLUGINS_DIR" ]; then
        error_exit "Bedrock plugins directory not found at expected location: $WP_DIR/$PLUGINS_DIR"
    fi
else
    echo "Standard WordPress mode enabled."
    # Standard WordPress structure paths (relative to project root WP_DIR)
    PLUGINS_DIR="wp-content/plugins"
    BACKUP_PARENT_DIR="wp-content" # Backup will be created inside this directory
     # Check if these directories exist within WP_DIR
    if [ ! -d "$WP_DIR/$PLUGINS_DIR" ]; then
        error_exit "Standard plugins directory not found at expected location: $WP_DIR/$PLUGINS_DIR"
    fi
fi

# --- Result Generation Function ---
generate_results_file() {
    local format="$1"
    local filename=""
    local total_attempted=${#PLUGINS_TO_UPDATE[@]} # Based on plugins needing update
    local success_count=${#SUCCESSFUL_PLUGINS[@]} # Only populated in non-dry-run
    local failed_count=${#FAILED_PLUGINS[@]}     # Only populated in non-dry-run
    local doctor_checks_run_count=${#DOCTOR_CHECK_NAMES_RUN[@]}
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S %Z")
    # Use WP_CMD which includes --path and --allow-root if needed
    local site_url=$(${WP_CMD} option get home 2>/dev/null || echo 'N/A')
    local current_dir=$(pwd) # Get current directory where script is run (project root)

    if [[ "$format" == "md" ]]; then
        filename="$MARKDOWN_RESULTS_FILE"
        echo "Generating Markdown results file: $filename"
        {
            echo "# WordPress Maintenance Results"
            if [ "$DRY_RUN_FLAG" = true ]; then echo "**DRY RUN MODE ENABLED**"; fi
            echo ""
            echo "**Timestamp:** $timestamp"
            echo "**Site:** $site_url"
            echo "**Directory:** \`$current_dir\`" # Use backticks for directory
            if [[ -n "$SUBDIR_PATH" ]]; then echo "**Subdirectory:** \`$SUBDIR_PATH\`"; fi
            echo ""
            echo "## Plugin Update Summary"
            echo "- Total Plugins Identified for Update: $total_attempted"
            if [ "$DRY_RUN_FLAG" = true ]; then
                echo "- Updates Skipped (Dry Run): $total_attempted"
            else
                echo "- Successfully Updated: $success_count"
                echo "- Failed Updates: $failed_count"
            fi
            echo ""

            if [ "$DRY_RUN_FLAG" = true ]; then
                 if [[ $total_attempted -gt 0 ]]; then
                    echo "### Plugins Needing Update (Dry Run)"
                    for plugin in "${PLUGINS_TO_UPDATE[@]}"; do
                        echo "- \`$plugin\`"
                    done
                    echo ""
                 fi
            else
                if [[ $success_count -gt 0 ]]; then
                    echo "### Successful Plugin Updates"
                    for plugin in "${SUCCESSFUL_PLUGINS[@]}"; do
                        echo "- \`$plugin\`"
                    done
                    echo ""
                fi

                if [[ $failed_count -gt 0 ]]; then
                    echo "### Failed Plugin Updates"
                    for i in "${!FAILED_PLUGINS[@]}"; do
                        echo "- **\`${FAILED_PLUGINS[$i]}\`**"
                        # Indent error message slightly
                        echo "  - **Error:** \`${FAILED_MESSAGES[$i]:-Unknown error}\`"
                    done
                    echo ""
                fi
            fi


            echo "## WP Doctor Health Checks"
            echo "- Total Checks Run: $doctor_checks_run_count"
            echo ""
            if [[ $doctor_checks_run_count -gt 0 ]]; then
                 echo "| Check Name | Status | Message |"
                 echo "|------------|--------|---------|"
                 for (( i=0; i<${#DOCTOR_CHECK_NAMES_RUN[@]}; i++ )); do
                     # Escape pipe characters in message for Markdown table
                     local msg_escaped=${DOCTOR_CHECK_MESSAGES[$i]//\|/\\|}
                     echo "| \`${DOCTOR_CHECK_NAMES_RUN[$i]}\` | **${DOCTOR_CHECK_STATUSES[$i]}** | ${msg_escaped:-N/A} |"
                 done
            else
                 echo "No WP Doctor checks were run."
            fi
            echo ""

        } > "$filename"
    elif [[ "$format" == "html" ]]; then
        filename="$HTML_RESULTS_FILE"
        echo "Generating HTML results file: $filename"
        {
            echo "<!DOCTYPE html>"
            echo "<html lang=\"en\">"
            echo "<head>"
            echo "  <meta charset=\"UTF-8\">"
            echo "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">"
            echo "  <title>WordPress Maintenance Results</title>"
            echo "  <style>"
            echo "    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen-Sans, Ubuntu, Cantarell, 'Helvetica Neue', sans-serif; line-height: 1.6; padding: 20px; color: #333; }"
            echo "    h1, h2, h3 { border-bottom: 1px solid #eee; padding-bottom: 8px; margin-top: 30px; }"
            echo "    h1 { font-size: 1.8em; }"
            echo "    h2 { font-size: 1.4em; }"
            echo "    h3 { font-size: 1.2em; border-bottom: none; }"
            echo "    ul { list-style: none; padding-left: 0; }"
            echo "    li { margin-bottom: 10px; padding-left: 25px; position: relative; }"
            echo "    code { background-color: #f0f0f0; padding: 3px 6px; border-radius: 4px; font-family: monospace; }"
            echo "    .status-error { color: #d9534f; font-weight: bold; }"
            echo "    .status-success { color: #5cb85c; font-weight: bold; }"
            echo "    .status-warning { color: #f0ad4e; font-weight: bold; }"
            echo "    .status-skipped { color: #777; font-style: italic; }"
            echo "    .status-failed_to_run { color: #d9534f; font-weight: bold; }"
            echo "    .status-unknown { color: #777; font-weight: bold; }"
            echo "    .summary-item { margin-bottom: 5px; }"
            echo "    .dry-run-notice { background-color: #fff3cd; border: 1px solid #ffeeba; color: #856404; padding: 10px; border-radius: 4px; margin-bottom: 20px; }"
            echo "    .icon::before { position: absolute; left: 0; top: 1px; font-size: 1.1em; }"
            echo "    .icon-success::before { content: '✔'; color: #5cb85c; }"
            echo "    .icon-error::before { content: '✘'; color: #d9534f; }"
            echo "    .icon-warning::before { content: '⚠'; color: #f0ad4e; }" # Warning icon
            echo "    .icon-skipped::before { content: '»'; color: #777; }" # Skipped icon
            echo "    .icon-unknown::before { content: '?'; color: #777; }" # Unknown icon
            echo "    table { width: 100%; border-collapse: collapse; margin-top: 15px; }"
            echo "    th, td { border: 1px solid #ddd; padding: 8px; text-align: left; word-wrap: break-word; }"
            echo "    th { background-color: #f9f9f9; }"
            echo "    pre { display: inline; margin: 0; padding: 0; white-space: pre-wrap; word-wrap: break-word; }"
            echo "  </style>"
            echo "</head>"
            echo "<body>"
            echo "  <h1>WordPress Maintenance Results</h1>"
            if [ "$DRY_RUN_FLAG" = true ]; then echo "  <p class='dry-run-notice'><strong>DRY RUN MODE ENABLED</strong> - No changes were made.</p>"; fi
            echo "  <p><strong>Timestamp:</strong> $timestamp</p>"
            echo "  <p><strong>Site:</strong> <a href=\"$site_url\" target=\"_blank\">$site_url</a></p>"
            echo "  <p><strong>Directory:</strong> <code>$current_dir</code></p>"
            if [[ -n "$SUBDIR_PATH" ]]; then echo "  <p><strong>Subdirectory:</strong> <code>$SUBDIR_PATH</code></p>"; fi

            echo "  <h2>Plugin Update Summary</h2>"
            echo "  <ul>"
            echo "    <li class='summary-item'>Total Plugins Identified for Update: $total_attempted</li>"
             if [ "$DRY_RUN_FLAG" = true ]; then
                echo "    <li class='summary-item'><span class='status-skipped'>Updates Skipped (Dry Run): $total_attempted</span></li>"
            else
                echo "    <li class='summary-item'><span class='status-success'>Successfully Updated: $success_count</span></li>"
                echo "    <li class='summary-item'><span class='status-error'>Failed Updates: $failed_count</span></li>"
            fi
            echo "  </ul>"

            if [ "$DRY_RUN_FLAG" = true ]; then
                 if [[ $total_attempted -gt 0 ]]; then
                    echo "  <h3>Plugins Needing Update (Dry Run)</h3>"
                    echo "  <ul>"
                    for plugin in "${PLUGINS_TO_UPDATE[@]}"; do
                        echo "    <li class='icon icon-skipped'><code>$plugin</code></li>"
                    done
                    echo "  </ul>"
                 fi
            else
                if [[ $success_count -gt 0 ]]; then
                    echo "  <h3>Successful Plugin Updates</h3>"
                    echo "  <ul>"
                    echo "  </ul>"
                fi

                if [[ $failed_count -gt 0 ]]; then
                    echo "  <h3>Failed Plugin Updates</h3>"
                    echo "  <ul>"
                    for i in "${!FAILED_PLUGINS[@]}"; do
                        echo "    <li class='icon icon-error'>"
                        echo "      <strong><code>${FAILED_PLUGINS[$i]}</code></strong><br>"
                        # Use pre for potentially multi-line errors
                        echo "      &nbsp;&nbsp;<strong>Error:</strong> <pre><code>${FAILED_MESSAGES[$i]:-Unknown error}</code></pre>"
                        echo "    </li>"
                    done
                    echo "  </ul>"
                fi
            fi


            echo "  <h2>WP Doctor Health Checks</h2>"
            echo "  <p>Total Checks Run: $doctor_checks_run_count</p>"
             if [[ $doctor_checks_run_count -gt 0 ]]; then
                 echo "  <table>"
                 echo "    <thead><tr><th>Check Name</th><th>Status</th><th>Message</th></tr></thead>"
                 echo "    <tbody>"
                 for (( i=0; i<${#DOCTOR_CHECK_NAMES_RUN[@]}; i++ )); do
                     local status_class="status-${DOCTOR_CHECK_STATUSES[$i]}"
                     # Basic HTML escaping for the message
                     local msg_html=$(echo "${DOCTOR_CHECK_MESSAGES[$i]:-N/A}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g')
                     echo "      <tr>"
                     echo "        <td><code>${DOCTOR_CHECK_NAMES_RUN[$i]}</code></td>"
                     echo "        <td><span class='$status_class'>${DOCTOR_CHECK_STATUSES[$i]}</span></td>"
                     echo "        <td>${msg_html}</td>"
                     echo "      </tr>"
                 done
                 echo "    </tbody>"
                 echo "  </table>"
            else
                 echo "  <p>No WP Doctor checks were run or recorded.</p>"
            fi

            echo "</body>"
            echo "</html>"
        } > "$filename"
    fi
    echo "Results file generated: $filename"
}


# --- Main Script Logic ---

echo "Starting WordPress maintenance process for Project Root: $WP_DIR"
if [ "$DRY_RUN_FLAG" = true ]; then
    echo "*** DRY RUN MODE ENABLED ***"
fi
if [[ -n "$SUBDIR_PATH" ]]; then
    echo "Using WordPress Subdirectory: $SUBDIR_PATH"
fi

# Navigate to the WordPress project directory (WP_DIR)
# WP-CLI commands will be run from here, using --path if --subdir is set
cd "$WP_DIR" || error_exit "Could not change directory to $WP_DIR"
echo "Changed directory to $(pwd)" # Should be the WP_DIR provided

# Construct the base WP-CLI command with path and --allow-root
# Always add --allow-root
WP_CMD="wp --allow-root"
if [[ -n "$SUBDIR_PATH" ]]; then
    WP_INSTALL_PATH="$WP_DIR/$SUBDIR_PATH"
    # Basic validation for the subdir path relative to current dir (project root)
    if [ ! -d "$SUBDIR_PATH" ]; then
        # Check relative to WP_DIR as well, in case $WP_DIR was relative
        if [ ! -d "$WP_INSTALL_PATH" ]; then
            error_exit "Specified subdirectory '$SUBDIR_PATH' not found within project root '$WP_DIR'."
        fi
    fi
    # Use absolute path for --path to be safe
    WP_INSTALL_PATH_ABS=$(realpath "$SUBDIR_PATH")
    # Prepend --path before other flags
    WP_CMD="wp --path=$WP_INSTALL_PATH_ABS --allow-root"
    echo "WP-CLI commands will use path: $WP_INSTALL_PATH_ABS"
fi
echo "WP-CLI Base Command: $WP_CMD"

# Check and install WP Doctor if necessary
echo "Checking if WP Doctor (wp-cli/doctor-command) is installed..."
# Use WP_CMD which includes --path and --allow-root
if ! ${WP_CMD} package list --fields=name --format=csv | grep -q "wp-cli/doctor-command"; then
    echo "WP Doctor not found. Attempting to install..."
    if [ "$DRY_RUN_FLAG" = true ]; then
        echo " [DRY RUN] Would run: ${WP_CMD} package install wp-cli/doctor-command:@stable"
    else
        # Use WP_CMD
        if ${WP_CMD} package install wp-cli/doctor-command:@stable; then
            echo "WP Doctor (wp-cli/doctor-command) installed successfully."
        else
            error_exit "Failed to install WP Doctor (wp-cli/doctor-command). Please install it manually."
        fi
    fi
else
    echo "WP Doctor is already installed."
fi

# 1. Identify Plugins and Check for Updates
echo "Checking for plugin updates..."
# Clear previous update status file (relative to WP_DIR)
> "$UPDATE_STATUS_FILE"

# Get plugin slugs directly from WP-CLI for accuracy
# Use WP_CMD which includes --path and --allow-root if needed
PLUGIN_LIST_STDERR_FILE=$(mktemp)
if ! mapfile -t PLUGIN_SLUGS < <(${WP_CMD} plugin list --field=name --status=active,inactive 2> "$PLUGIN_LIST_STDERR_FILE"); then
    PLUGIN_LIST_ERROR_MSG=$(<"$PLUGIN_LIST_STDERR_FILE")
    rm -f "$PLUGIN_LIST_STDERR_FILE"
    error_exit $"Failed to list plugins using WP-CLI. Ensure WP-CLI is configured correctly for this site. WP-CLI stderr:\n${PLUGIN_LIST_ERROR_MSG}"
fi
rm -f "$PLUGIN_LIST_STDERR_FILE" # Clean up if successful

if [ ${#PLUGIN_SLUGS[@]} -eq 0 ]; then
  echo "No plugins found or WP-CLI failed to list them."
else
  echo "Found plugins: ${PLUGIN_SLUGS[*]}"
  for plugin_slug in "${PLUGIN_SLUGS[@]}"; do
      echo "Checking update status for: $plugin_slug"
      # Use --dry-run with JSON output to check for updates without applying them
      # Capture stderr for this command too
      PLUGIN_UPDATE_CHECK_STDERR_FILE=$(mktemp)
      # Use WP_CMD
      update_info=$(${WP_CMD} plugin update "$plugin_slug" --dry-run --format=json 2> "$PLUGIN_UPDATE_CHECK_STDERR_FILE" || echo "[]") # Default to empty JSON array on error
      PLUGIN_UPDATE_CHECK_ERROR_MSG=$(<"$PLUGIN_UPDATE_CHECK_STDERR_FILE")
      rm -f "$PLUGIN_UPDATE_CHECK_STDERR_FILE"
      if [[ -n "$PLUGIN_UPDATE_CHECK_ERROR_MSG" && "$update_info" == "[]" ]]; then
          # If there was an error and no update info was returned, log it
          warning_msg "Could not check update status for '$plugin_slug'. WP-CLI stderr:\n${PLUGIN_UPDATE_CHECK_ERROR_MSG}"
      fi


      # Check if the JSON array returned by --dry-run is empty or not
      update_available=0
      # Use jq to safely check length
      if echo "$update_info" | jq 'length > 0' &>/dev/null; then
          update_available=1
          echo "  Update available for $plugin_slug."
      else
          echo "  No update needed for $plugin_slug."
      fi
      # Append status to the file: plugin-name|status (1 for update available, 0 otherwise)
      echo "${plugin_slug}|${update_available}" >> "$UPDATE_STATUS_FILE"
  done
fi
echo "Plugin update check complete. Status saved to $UPDATE_STATUS_FILE"

# 3. Create Backup (Conditional)
# Backup paths remain relative to the project root ($WP_DIR)
if [ "$DRY_RUN_FLAG" = false ]; then
    BACKUP_DIR_NAME="plugins_bu_$(date +%Y%m%d_%H%M%S)"
    # Construct the full path for the backup directory relative to WP_DIR
    BACKUP_PATH="$BACKUP_PARENT_DIR/$BACKUP_DIR_NAME"
    # Construct the full path for the source plugins directory relative to WP_DIR
    SOURCE_PLUGINS_PATH="$PLUGINS_DIR"

    echo "Creating backup of plugins directory ($SOURCE_PLUGINS_PATH)..."
    # Ensure source path exists before copying
    if [ ! -d "$SOURCE_PLUGINS_PATH" ]; then
        error_exit "Plugins directory to backup not found at '$SOURCE_PLUGINS_PATH'. Check --bedrock flag if needed."
    fi
    cp -r "$SOURCE_PLUGINS_PATH" "$BACKUP_PATH" || error_exit "Failed to create backup directory at $BACKUP_PATH from $SOURCE_PLUGINS_PATH"
    echo "Backup created successfully at $BACKUP_PATH"
else
    echo "Skipping backup creation (Dry Run)."
fi

# 4. Perform Health Checks
echo "Performing site health checks..."

# 4a. HTTP Status Check
# Use WP_CMD
SITE_URL=$(${WP_CMD} option get home 2>/dev/null) || error_exit "Failed to get site URL using 'wp option get home'."
if [ -z "$SITE_URL" ]; then
    error_exit "Site URL is empty. Cannot perform HTTP check."
fi
echo "Checking HTTP status for $SITE_URL..."
# Use curl with -L to follow redirects, common in WP setups
HTTP_STATUS=$(curl -L -o /dev/null -s -w "%{http_code}" --max-time 15 --retry 3 --retry-delay 2 "$SITE_URL")

if [ "$HTTP_STATUS" -ne 200 ]; then
    # In dry run, only warn about HTTP failure, don't exit
    if [ "$DRY_RUN_FLAG" = true ]; then
        warning_msg "HTTP status check failed! Expected 200, got $HTTP_STATUS for $SITE_URL (Dry Run - Not exiting)."
    else
        error_exit "HTTP status check failed! Expected 200, but got $HTTP_STATUS for $SITE_URL after following redirects. Aborting updates."
    fi
else
    echo "HTTP status check passed (Code: $HTTP_STATUS)."
fi

# 4b. WP Doctor Check (Individual Checks)
echo "Running WP Doctor checks individually..."
# Clear previous results log
> "$HEALTH_CHECK_FILE"
DOCTOR_ERRORS_FOUND=() # Array to store error messages

# Prepare the list of excluded checks (using awk for robustness with comma/spaces)
EXCLUDED_CHECKS_ARRAY=()
if [[ "$EXCLUDE_CHECKS_ARG" != "none" ]]; then
    IFS=',' read -r -a EXCLUDED_CHECKS_ARRAY <<< "$(echo "$EXCLUDE_CHECKS_ARG" | sed 's/ *, */,/g')" # Normalize commas and read into array
    echo "WP Doctor: Excluding checks from error report: ${EXCLUDED_CHECKS_ARRAY[*]}"
else
     echo "WP Doctor: Checking status for all checks (no exclusions)."
fi

# Function to check if an element is in an array
containsElement () {
  local e match="$1"
  shift
  for e; do [[ "$e" == "$match" ]] && return 0; done
  return 1
}

# Get list of available checks using JSON format
# Use WP_CMD
DOCTOR_CHECKS_JSON=$(${WP_CMD} doctor list --format=json 2>/dev/null) || error_exit "Failed to get list of WP Doctor checks."
mapfile -t DOCTOR_CHECK_NAMES < <(echo "$DOCTOR_CHECKS_JSON" | jq -r '.[].name')

# Loop through each check
for check_name in "${DOCTOR_CHECK_NAMES[@]}"; do
    # Store check name regardless of whether it's excluded, for potential reporting
    DOCTOR_CHECK_NAMES_RUN+=("$check_name")

    # Check if this check is excluded (using bash array check)
    if containsElement "$check_name" "${EXCLUDED_CHECKS_ARRAY[@]}"; then
        echo "  Running check: $check_name... Skipped (excluded)."
        # Add placeholder status/message for skipped checks
        DOCTOR_CHECK_STATUSES+=("skipped")
        DOCTOR_CHECK_MESSAGES+=("Excluded by --exclude-checks flag.")
        continue
    fi

    echo -n "  Running check: $check_name... "

    # Run the individual check with JSON format, capture stdout and stderr
    CHECK_STDERR_FILE=$(mktemp)
    CHECK_RESULT_JSON=""
    # Add higher memory limit attempt
    # Use --format=json and WP_CMD
    if ! CHECK_RESULT_JSON=$(WP_CLI_PHP_ARGS="-d memory_limit=512M" ${WP_CMD} doctor check "$check_name" --format=json 2> "$CHECK_STDERR_FILE"); then
        CHECK_ERROR_MSG=$(<"$CHECK_STDERR_FILE")
        # If the command itself failed, record this as a critical error
        ERROR_DETAIL="WP Doctor command failed for check '$check_name'. WP-CLI stderr:\n${CHECK_ERROR_MSG}"
        echo "FAILED!"
        echo "$ERROR_DETAIL" >> "$HEALTH_CHECK_FILE" # Log failure
        DOCTOR_ERRORS_FOUND+=("$ERROR_DETAIL") # Add to array for final report
        # Store failure status for reporting
        DOCTOR_CHECK_STATUSES+=("failed_to_run")
        DOCTOR_CHECK_MESSAGES+=("$ERROR_DETAIL")
        rm -f "$CHECK_STDERR_FILE"
        continue # Continue to next check even if one fails to run
    fi
    rm -f "$CHECK_STDERR_FILE" # Clean up temp stderr file on success

    # Log the raw JSON result
    echo "$CHECK_RESULT_JSON" >> "$HEALTH_CHECK_FILE"

    # Check the status within the JSON result using jq
    # Filter the array for the object with the matching name, then get status/message
    # Use --arg to safely pass the shell variable to jq
    check_status=$(echo "$CHECK_RESULT_JSON" | jq --arg check_name "$check_name" -r '.[] | select(.name == $check_name) | .status // "unknown"')
    check_message=$(echo "$CHECK_RESULT_JSON" | jq --arg check_name "$check_name" -r '.[] | select(.name == $check_name) | .message // "No message found for this check."')

    # Handle cases where the check name might not be found in the output
    check_status=${check_status:-unknown}
    check_message=${check_message:-"Check result not found in JSON output."}

    # Store results for reporting
    DOCTOR_CHECK_STATUSES+=("$check_status")
    DOCTOR_CHECK_MESSAGES+=("$check_message")

    if [[ "$check_status" == "error" ]]; then
        echo "Error!"
        ERROR_DETAIL="- $check_name ($check_status): $check_message"
        DOCTOR_ERRORS_FOUND+=("$ERROR_DETAIL")
    elif [[ "$check_status" == "warning" ]]; then
        echo "Warning." # Treat warnings as informational for now
    elif [[ "$check_status" == "success" ]]; then
         echo "Passed."
    else
        # Handle cases where status is unexpected or missing
        echo "Status Unknown/Unexpected ('$check_status')."
        ERROR_DETAIL="- $check_name ($check_status): $check_message"
        DOCTOR_ERRORS_FOUND+=("$ERROR_DETAIL") # Treat unknown as potential issue
    fi
done

echo "WP Doctor individual checks complete. Results logged to $HEALTH_CHECK_FILE"

# Check if any errors were found (and not excluded)
if [ ${#DOCTOR_ERRORS_FOUND[@]} -gt 0 ]; then
    # Join errors with newline characters
    FORMATTED_ERRORS=$(printf "%s\n" "${DOCTOR_ERRORS_FOUND[@]}")
    # In dry run, only warn about doctor errors, don't exit (unless --allow-check-errors is also false)
    if [ "$DRY_RUN_FLAG" = true ] || [ "$ALLOW_CHECK_ERRORS" = true ]; then
        # If flag is set, print a warning but continue
        warning_msg $"WP Doctor found errors/issues (after exclusions), but proceeding due to --allow-check-errors or --dry-run flag:\n${FORMATTED_ERRORS}"
    else
        # Default behavior: print errors and exit
        error_exit $"WP Doctor found critical errors/issues (after exclusions). Aborting updates:\n${FORMATTED_ERRORS}"
    fi
else
    echo "WP Doctor checks passed (no critical errors found after exclusions)."
fi

# Re-enable exit on error if it was disabled and you want it back on
# set -e

# 5. Perform Updates (Conditional)
if [ "$DRY_RUN_FLAG" = false ]; then
    echo "Starting plugin updates based on $UPDATE_STATUS_FILE..."
    # Clear temporary success log
    > "$UPDATES_NEEDED_LOG" # Use this log for actual updates

    # Read the status file line by line (file is in WP_DIR)
    while IFS='|' read -r plugin_slug update_flag || [[ -n "$plugin_slug" ]]; do
        # Ensure plugin_slug is not empty before proceeding
        if [ -z "$plugin_slug" ]; then
            continue
        fi

        if [ "$update_flag" -eq 1 ]; then
            PLUGINS_TO_UPDATE+=("$plugin_slug") # Track plugins needing updates for report
            echo "Attempting to update plugin: $plugin_slug"
            # Run update from project root (WP_DIR)
            # Capture stderr for update command
            UPDATE_STDERR_FILE=$(mktemp)
            # Use WP_CMD
            if ${WP_CMD} plugin update "$plugin_slug" --quiet 2> "$UPDATE_STDERR_FILE"; then
                echo "Successfully updated $plugin_slug."
                # Log successful update
                echo "$plugin_slug" >> "$UPDATES_NEEDED_LOG"
                # Add to success array for reporting
                SUCCESSFUL_PLUGINS+=("$plugin_slug")
                rm -f "$UPDATE_STDERR_FILE" # Clean up success stderr
            else
                UPDATE_ERROR_MSG=$(<"$UPDATE_STDERR_FILE")
                rm -f "$UPDATE_STDERR_FILE" # Clean up fail stderr
                # Log failure for reporting
                FAILED_PLUGINS+=("$plugin_slug")
                # Store the error message, removing potential trailing newlines
                FAILED_MESSAGES+=("$(echo -n "$UPDATE_ERROR_MSG")")
                warning_msg "Failed to update $plugin_slug. WP-CLI stderr:\n${UPDATE_ERROR_MSG}"
                # Optionally: Add logic here to handle failed updates (e.g., notify admin)
            fi
        fi
    done < "$UPDATE_STATUS_FILE"
    echo "Plugin update process finished."

    # Update the status file: Remove successfully updated plugins
    echo "Cleaning up $UPDATE_STATUS_FILE..."
    TEMP_UPDATE_FILE=$(mktemp)
    # Ensure the last line is processed even if it doesn't end with a newline
    {
        while IFS='|' read -r plugin_slug update_flag; do
            # Keep the line if the flag is 0 OR if the flag is 1 BUT the plugin is NOT in the success log
            if [ "$update_flag" -eq 0 ] || { [ "$update_flag" -eq 1 ] && ! grep -Fxq "$plugin_slug" "$UPDATES_NEEDED_LOG"; }; then
                echo "${plugin_slug}|${update_flag}" >> "$TEMP_UPDATE_FILE"
            fi
        done
    } < "$UPDATE_STATUS_FILE"

    # Replace the old status file with the updated one
    mv "$TEMP_UPDATE_FILE" "$UPDATE_STATUS_FILE"
    echo "$UPDATE_STATUS_FILE updated. Lines for successfully updated plugins removed."
    rm -f "$UPDATES_NEEDED_LOG" # Remove temporary log

else
    echo "Skipping plugin updates (Dry Run)."
    # Populate PLUGINS_TO_UPDATE list for dry run report
     while IFS='|' read -r plugin_slug update_flag || [[ -n "$plugin_slug" ]]; do
        if [ -z "$plugin_slug" ]; then continue; fi
        if [ "$update_flag" -eq 1 ]; then
            PLUGINS_TO_UPDATE+=("$plugin_slug")
            echo "  Plugin needing update (Dry Run): $plugin_slug"
        fi
    done < "$UPDATE_STATUS_FILE"
    echo "Skipping cleanup of $UPDATE_STATUS_FILE (Dry Run)."

fi


# 6. Generate Results File (if requested)
if [[ -n "$PRINT_RESULTS_FORMAT" ]]; then
    generate_results_file "$PRINT_RESULTS_FORMAT"
fi


# --- Cleanup ---
# Keep HEALTH_CHECK_FILE for review
# rm -f "$HEALTH_CHECK_FILE" # Keep this file now as it contains individual results
# UPDATES_NEEDED_LOG is already removed in the non-dry-run path
echo "Temporary files cleaned up."

echo "WordPress maintenance process completed successfully."
exit 0

