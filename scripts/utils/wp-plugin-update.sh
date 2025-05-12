#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e # Keep disabled for detailed WP Doctor debugging

# --- Configuration ---
# Default values
BEDROCK_MODE=false
WP_DIR=""
SUBDIR_PATH="" # Relative path to WP install within WP_DIR
ALLOW_CHECK_ERRORS=false # Default: Exit on WP Doctor errors
PRINT_RESULTS_FORMAT="" # md, html, or empty (no report)
DRY_RUN_FLAG=false # Default: Perform actual updates and backups
DISABLE_JQ_FLAG=false # Default: Use jq if available or try to install it
DISABLE_WGET_FLAG=false # Default: Use wget if needed (e.g. for jq install)
UPDATE_ALL_FLAG=false # Default: Update plugins individually
SEO_RANK_ELEMENTOR_UPDATE_FLAG=false # Default: Standard update order
SKIP_PLUGINS_CLI_FLAG=false # Default: Do not add --skip-plugins to WP-CLI commands
SKIP_WP_DOCTOR_FLAG=false # Default: Run WP Doctor checks
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
_PLUGIN_CHECK_ERROR_MSG=""

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
    # Ensure results are printed on error if a format was specified and arrays are populated
    if [[ -n "$PRINT_RESULTS_FORMAT" && (${#PLUGINS_TO_UPDATE[@]} -gt 0 || ${#DOCTOR_CHECK_NAMES_RUN[@]} -gt 0) ]]; then
        echo "INFO: Attempting to generate results file before exiting due to error..."
        generate_results_file "$PRINT_RESULTS_FORMAT"
    fi
    exit 1
}

warning_msg() {
    echo "WARNING: $1" >&2
}

# Helper function to check if a specific plugin has an update available
# Returns 0 (shell true) if update IS available.
# Returns 1 (shell false) if NO update is available OR an error occurred.
# Populates global _PLUGIN_CHECK_ERROR_MSG if an error occurs during check.
check_single_plugin_update_status() {
    local plugin_slug_to_check="$1"
    local is_update_available_return_code=1 # Default to 1 (no update / error)
    _PLUGIN_CHECK_ERROR_MSG="" # Reset global error message
    local check_stderr_file
    check_stderr_file=$(mktemp)

    if [ "$DISABLE_JQ_FLAG" = false ]; then
        local update_info
        update_info=$(${WP_CMD} plugin update "$plugin_slug_to_check" --dry-run --format=json 2> "$check_stderr_file" || echo "[]")
        _PLUGIN_CHECK_ERROR_MSG=$(<"$check_stderr_file")
        if [[ -n "$_PLUGIN_CHECK_ERROR_MSG" && "$update_info" == "[]" ]]; then
            # Error occurred, message stored in _PLUGIN_CHECK_ERROR_MSG
            is_update_available_return_code=1
        elif echo "$update_info" | jq 'length > 0' &>/dev/null; then
            is_update_available_return_code=0 # Update available
            _PLUGIN_CHECK_ERROR_MSG="" # Clear error message on success
        else
            # No update available (empty JSON array) or jq error
            is_update_available_return_code=1
        fi
    else
        local plugin_update_status_output
        plugin_update_status_output=$(${WP_CMD} plugin list --name="$plugin_slug_to_check" --field=update --format=csv 2> "$check_stderr_file")
        _PLUGIN_CHECK_ERROR_MSG=$(<"$check_stderr_file")

        if [[ -n "$_PLUGIN_CHECK_ERROR_MSG" && -z "$plugin_update_status_output" ]]; then
            is_update_available_return_code=1
        else
            local current_plugin_update_status
            current_plugin_update_status=$(echo "$plugin_update_status_output" | awk 'NR==2 {print $1}')
            if [[ "$current_plugin_update_status" == "available" ]]; then
                is_update_available_return_code=0 # Update available
                if [[ -n "$_PLUGIN_CHECK_ERROR_MSG" && ! "$_PLUGIN_CHECK_ERROR_MSG" =~ "No update available for" ]]; then
                     : # Keep the error message for potential logging by caller
                else
                    _PLUGIN_CHECK_ERROR_MSG="" # Clear if no significant error
                fi
            else
                is_update_available_return_code=1
                # If _PLUGIN_CHECK_ERROR_MSG is empty but status is not "available", it's just no update.
                # If _PLUGIN_CHECK_ERROR_MSG has content, it's an error or "no update" message.
            fi
        fi
    fi
    rm -f "$check_stderr_file"
    return "$is_update_available_return_code"
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
        --disable-jq) DISABLE_JQ_FLAG=true; shift ;; # Disable jq usage and installation
        --disable-wget) DISABLE_WGET_FLAG=true; shift ;; # Disable wget usage and installation
        --update-all) UPDATE_ALL_FLAG=true; shift ;; # Enable updating all plugins at once
        --seo-rank-elementor-update) SEO_RANK_ELEMENTOR_UPDATE_FLAG=true; shift ;; # Enable SEO Rank Math & Elementor priority update
        --skip-plugins) SKIP_PLUGINS_CLI_FLAG=true; shift ;; # Add --skip-plugins to all wp-cli commands
        --skip-wp-doctor) SKIP_WP_DOCTOR_FLAG=true; shift ;; # Skip WP Doctor checks entirely
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
    error_exit "Usage: $0 [--bedrock] [--dry-run] [--disable-jq] [--disable-wget] [--update-all] [--seo-rank-elementor-update] [--skip-plugins] [--skip-wp-doctor] [--subdir <relative_path>] [--allow-check-errors] [--exclude-checks <check1,check2|none>] [--print-results[=md|html]] <path_to_wordpress_directory>"
fi

# Check if WP_DIR is a directory
if [ ! -d "$WP_DIR" ]; then
    error_exit "WordPress directory not found: $WP_DIR"
fi

# Check if wp-cli is installed
if ! command -v wp &> /dev/null; then
    error_exit "WP-CLI command 'wp' not found. Please install it."
fi

# Check if jq is installed (needed for wp doctor list and plugin checks if not disabled)
if [ "$DISABLE_JQ_FLAG" = false ]; then
    if ! command -v jq &> /dev/null; then
        echo "INFO: 'jq' command not found. Attempting to install from source..."
        # Assuming script is run as root, sudo is not needed for apt-get or make install.

        # Check for wget
        if ! command -v wget &> /dev/null; then
            if [ "$DISABLE_WGET_FLAG" = true ]; then
                error_exit "jq needs to be installed, but wget is disabled (--disable-wget) and wget command is not found. Please install jq or wget manually, or enable wget usage."
            fi
            echo "INFO: 'wget' not found. Attempting to install via apt-get..."
            if ! command -v apt-get &> /dev/null; then
                error_exit "wget is not installed (needed for jq source install), and apt-get is not available. Please install wget manually or ensure jq is already installed."
            fi
            resolve_apt_locks
            if ! apt-get install -y wget; then
                error_exit "Failed to install wget using apt-get (needed for jq source install). Please install it manually or ensure jq is already installed."
            fi
            echo "INFO: wget installed successfully."
        fi
        
        # Check for tar (already checked below, but good to ensure it's available before wget for jq)
        if ! command -v tar &> /dev/null; then
            echo "INFO: 'tar' not found (needed for jq source install). Attempting to install via apt-get..."
            if ! command -v apt-get &> /dev/null; then error_exit "tar is not installed, and apt-get is not available. Please install tar manually."; fi
            resolve_apt_locks
            if ! apt-get install -y tar; then error_exit "Failed to install tar using apt-get."; fi
            echo "INFO: tar installed successfully."
        fi
        
        # Check for make and build essentials (common for ./configure && make)
        if ! command -v make &> /dev/null; then
            echo "INFO: 'make' not found (needed for jq source install). Attempting to install 'make' and 'build-essential' via apt-get..."
            if ! command -v apt-get &> /dev/null; then error_exit "make is not installed, and apt-get is not available. Please install them manually."; fi
            resolve_apt_locks
            if ! apt-get install -y make build-essential; then error_exit "Failed to install make/build-essential using apt-get."; fi
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
            error_exit "Failed to download jq tarball. wget might be blocked or URL is invalid."
        fi

        echo "INFO: Extracting jq tarball..."
        if ! tar -xzf "$TEMP_BUILD_DIR/$JQ_TARBALL" -C "$TEMP_BUILD_DIR"; then
            rm -rf "$TEMP_BUILD_DIR"
            error_exit "Failed to extract jq tarball."
        fi

        cd "$TEMP_BUILD_DIR/$JQ_SOURCE_DIR" || { rm -rf "$TEMP_BUILD_DIR"; error_exit "Failed to change directory to jq source."; }

        echo "INFO: Configuring jq..."
        if ! ./configure --with-oniguruma=builtin; then
            cd "$WP_DIR" 
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
            error_exit "Failed to install jq using make install. Check permissions or previous conflicting jq installations."
        fi

        cd "$WP_DIR" 
        rm -rf "$TEMP_BUILD_DIR" 

        if ! command -v jq &> /dev/null; then
            error_exit "jq installation from source completed, but 'jq' command still not found. Check PATH or installation."
        fi
        echo "INFO: jq installed successfully from source."
    else
        echo "INFO: 'jq' command found."
    fi
else
    echo "INFO: jq usage is disabled via --disable-jq. Using awk for parsing where possible."
    # awk becomes critical if jq is disabled
    if ! command -v awk &> /dev/null; then
        echo "INFO: 'awk' command not found (and jq is disabled). Attempting to install 'gawk'..."
        # (awk installation logic is present below, it will be hit)
    fi
fi

# Check for tar (if not already handled by jq install block)
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


# Check if awk is installed (needed for preparing exclusion list and as jq fallback)
if ! command -v awk &> /dev/null; then
    echo "INFO: 'awk' command not found. Attempting to install 'gawk'..."
    if ! command -v apt-get &> /dev/null; then
        # If jq is disabled, awk is critical.
        if [ "$DISABLE_JQ_FLAG" = true ]; then
            error_exit "awk is not installed (and jq is disabled), and apt-get is not available. Please install gawk manually."
        else
            warning_msg "awk is not installed, and apt-get is not available. Some operations might fail if jq is also unavailable. Please install gawk manually."
        fi
    else
        echo "INFO: Running: apt-get install -y gawk (after lock resolution)"
        resolve_apt_locks
        if apt-get install -y gawk; then
            echo "INFO: gawk installed successfully."
            if ! command -v awk &> /dev/null; then 
                 if [ "$DISABLE_JQ_FLAG" = true ]; then
                     error_exit "Verification failed after attempting to install gawk (awk command still not found, and jq is disabled)."
                 else
                     warning_msg "Verification failed after attempting to install gawk (awk command still not found)."
                 fi
            fi
        else
            if [ "$DISABLE_JQ_FLAG" = true ]; then
                error_exit "Failed to install gawk using apt-get (and jq is disabled). Please install it manually."
            else
                warning_msg "Failed to install gawk using apt-get. Some operations might fail if jq is also unavailable."
            fi
        fi
    fi
elif [ "$DISABLE_JQ_FLAG" = true ]; then
     echo "INFO: 'awk' command found (critical as jq is disabled)."
else
    echo "INFO: 'awk' command found."
fi

# Final check for jq if it was supposed to be enabled
if [ "$DISABLE_JQ_FLAG" = false ] && ! command -v jq &> /dev/null; then
    error_exit "jq is enabled but not found, and installation attempts failed. Please install jq manually or use --disable-jq."
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
if [ "$SKIP_PLUGINS_CLI_FLAG" = true ]; then
    WP_CMD="$WP_CMD --skip-plugins"
    echo "INFO: All WP-CLI commands will use --skip-plugins."
fi

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
    if [ "$SKIP_PLUGINS_CLI_FLAG" = true ]; then
        WP_CMD="$WP_CMD --skip-plugins"
    fi
    echo "WP-CLI commands will use path: $WP_INSTALL_PATH_ABS"
fi
echo "WP-CLI Base Command: $WP_CMD"

# Helper function to update a specific group of plugins
update_plugin_group() {
    local group_name="$1"
    shift
    local specific_plugins_to_update=("$@") # This is an array of plugin slugs for the current group

    echo "Updating $group_name plugins..."
    for plugin_slug in "${specific_plugins_to_update[@]}"; do
        # Check if this plugin was identified in the initial scan as needing an update
        local needs_update_from_initial_scan=false
        for p_to_update_master in "${PLUGINS_TO_UPDATE[@]}"; do
            if [[ "$p_to_update_master" == "$plugin_slug" ]]; then
                needs_update_from_initial_scan=true;
                break
            fi
        done

        if ! $needs_update_from_initial_scan; then
            # If it wasn't in the initial list, check if it was somehow already updated (edge case)
            local already_succeeded_edge_case=false
            for suc_p_edge in "${SUCCESSFUL_PLUGINS[@]}"; do if [[ "$suc_p_edge" == "$plugin_slug" ]]; then already_succeeded_edge_case=true; break; fi; done

            if $already_succeeded_edge_case; then
                 echo "  Plugin $plugin_slug was already updated in a previous step (though not in initial scan list). Skipping."
            else
                 # Check if the plugin is even installed if not found in initial scan list
                 if ! ${WP_CMD} plugin is-installed "$plugin_slug" >/dev/null 2>&1; then
                    echo "  Plugin $plugin_slug is not installed. Skipping."
                 else
                    echo "  Plugin $plugin_slug does not require an update (as per initial scan) or is not installed. Skipping."
                 fi
            fi
            continue
        fi

        # Check if already successfully updated in this run (e.g. if called multiple times with overlap)
        local already_attempted_successfully=false
        for suc_p in "${SUCCESSFUL_PLUGINS[@]}"; do if [[ "$suc_p" == "$plugin_slug" ]]; then already_attempted_successfully=true; break; fi; done
        if $already_attempted_successfully; then
            echo "  Plugin $plugin_slug already successfully updated in this run. Skipping."
            continue
        fi

        # Check if already attempted and failed in this run
        local already_attempted_failed=false
        for fail_p in "${FAILED_PLUGINS[@]}"; do if [[ "$fail_p" == "$plugin_slug" ]]; then already_attempted_failed=true; break; fi; done
        if $already_attempted_failed; then
            echo "  Plugin $plugin_slug already attempted and failed in this run. Skipping."
            continue
        fi

        echo "  Updating plugin: $plugin_slug"
        local update_stderr_file
        update_stderr_file=$(mktemp)
        # Pass the single plugin slug directly to the update command
        if WP_CLI_PHP_ARGS="-d max_execution_time=300" ${WP_CMD} plugin update "$plugin_slug" 2> "$update_stderr_file"; then
            echo "  Successfully updated: $plugin_slug"
            SUCCESSFUL_PLUGINS+=("$plugin_slug")
        else
            local update_error_msg
            update_error_msg=$(<"$update_stderr_file")
            local update_error_msg_oneline # Renamed for clarity within this scope
            update_error_msg_oneline=$(echo "$update_error_msg" | tr -d '\n\r' | sed 's/^Error: //')
            echo "  Failed to update: $plugin_slug. Error: $update_error_msg"
            FAILED_PLUGINS+=("$plugin_slug")
            FAILED_MESSAGES+=("$update_error_msg_oneline")
        fi
        rm -f "$update_stderr_file"
    done
}

# Check and install WP Doctor if necessary
if [ "$SKIP_WP_DOCTOR_FLAG" = true ]; then
    echo "Skipping WP Doctor checks as per --skip-wp-doctor flag."
    # Optionally, populate DOCTOR_CHECK arrays with a skipped message for reporting
    DOCTOR_CHECK_NAMES_RUN+=("WP Doctor")
    DOCTOR_CHECK_STATUSES+=("skipped")
    DOCTOR_CHECK_MESSAGES+=("All WP Doctor checks skipped via --skip-wp-doctor flag.")
else
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
          update_status_for_file=0 # 0 = no update, 1 = update available

          if check_single_plugin_update_status "$plugin_slug"; then
              # Function returned 0 (shell true) => update is available
              update_status_for_file=1
              echo "  Update available for $plugin_slug."
          else
              # Function returned 1 (shell false) => no update or error
              update_status_for_file=0
              if [[ -n "$_PLUGIN_CHECK_ERROR_MSG" ]]; then
                  warning_msg "Could not reliably check update status for '$plugin_slug'. Assuming no update. Details: $_PLUGIN_CHECK_ERROR_MSG"
              else
                  echo "  No update needed for $plugin_slug."
              fi
          fi
          # The UPDATE_STATUS_FILE stores 1 if update is available, 0 if not.
          echo "${plugin_slug}|${update_status_for_file}" >> "$UPDATE_STATUS_FILE"
      done
    fi
    echo "Plugin update check complete. Status saved to $UPDATE_STATUS_FILE"

    # Populate PLUGINS_TO_UPDATE with all plugins identified as needing an update
    echo "Identifying plugins that require updates from $UPDATE_STATUS_FILE..."
    # Ensure PLUGINS_TO_UPDATE is empty before populating
    PLUGINS_TO_UPDATE=()
    while IFS='|' read -r plugin_slug update_flag || [[ -n "$plugin_slug" ]]; do
        if [ -z "$plugin_slug" ]; then continue; fi
        if [ "$update_flag" -eq 1 ]; then
            PLUGINS_TO_UPDATE+=("$plugin_slug")
        fi
    done < "$UPDATE_STATUS_FILE"

    if [ ${#PLUGINS_TO_UPDATE[@]} -eq 0 ]; then
        echo "No plugins currently require updates based on initial check."
    else
        echo "Plugins initially identified for update attempt: ${PLUGINS_TO_UPDATE[*]}"
    fi

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
            # Command itself failed (e.g., check doesn't exist, WP-CLI error)
            check_stderr_content=$(<"$CHECK_STDERR_FILE")
            echo "Failed (command error)"
            DOCTOR_CHECK_STATUSES+=("failed_to_run")
            DOCTOR_CHECK_MESSAGES+=("Command execution failed for $check_name. Stderr: $check_stderr_content")
            # Log to health check file
            echo "Check: $check_name, Status: failed_to_run, Message: Command execution failed. Stderr: $check_stderr_content" >> "$HEALTH_CHECK_FILE"
            if [[ "$ALLOW_CHECK_ERRORS" = false ]]; then
                DOCTOR_ERRORS_FOUND+=("Doctor check '$check_name' command failed: $check_stderr_content")
            fi
        else
            # Command executed, CHECK_RESULT_JSON should have output. Now parse it.
            check_status=""
            check_message=""

            # Attempt to parse status and message using jq
            # Handle cases where CHECK_RESULT_JSON might not be valid JSON or fields are missing
            if echo "$CHECK_RESULT_JSON" | jq -e .status > /dev/null 2>&1; then
                check_status=$(echo "$CHECK_RESULT_JSON" | jq -r '.status')
                check_message=$(echo "$CHECK_RESULT_JSON" | jq -r '.message')
            else
                # JSON is invalid or status field is missing
                check_stderr_content=$(<"$CHECK_STDERR_FILE") # Check stderr from the command execution
                check_status="unknown" # Mark as unknown if parsing fails
                check_message="Could not parse JSON result or 'status' field missing. Raw output: '$CHECK_RESULT_JSON'. Stderr: '$check_stderr_content'"
            fi

            echo "$check_status" # Print status to console
            DOCTOR_CHECK_STATUSES+=("$check_status")
            DOCTOR_CHECK_MESSAGES+=("$check_message")

            # Log to health check file
            echo "Check: $check_name, Status: $check_status, Message: $check_message" >> "$HEALTH_CHECK_FILE"

            # Handle errors based on status if not excluded
            # Only consider "error" status as a failure for DOCTOR_ERRORS_FOUND
            if [[ "$check_status" == "error" ]]; then
                error_entry="Doctor check '$check_name' reported status '$check_status': $check_message"
                warning_msg "$error_entry" # Also echo to console as a warning
                if [[ "$ALLOW_CHECK_ERRORS" = false ]]; then
                    DOCTOR_ERRORS_FOUND+=("$error_entry")
                fi
            elif [[ "$check_status" == "warning" ]]; then
                # Log warnings but don't add to DOCTOR_ERRORS_FOUND unless you want to treat warnings as critical
                warning_msg "Doctor check '$check_name' reported status '$check_status': $check_message"
            fi
        fi
        rm -f "$CHECK_STDERR_FILE"
    done

    # After the loop, check DOCTOR_ERRORS_FOUND
    if [ "$ALLOW_CHECK_ERRORS" = false ] && [ ${#DOCTOR_ERRORS_FOUND[@]} -gt 0 ]; then
        echo "ERROR: Critical WP Doctor errors found:" >&2
        for err_msg in "${DOCTOR_ERRORS_FOUND[@]}"; do
            echo "- $err_msg" >&2
        done
        error_exit "Aborting due to WP Doctor errors. Use --allow-check-errors to override."
    else
        if [ ${#DOCTOR_ERRORS_FOUND[@]} -gt 0 ]; then
            # This means errors were found, but --allow-check-errors was true
            warning_msg "WP Doctor errors were found but ignored due to --allow-check-errors:"
            for err_msg in "${DOCTOR_ERRORS_FOUND[@]}"; do
                warning_msg "- $err_msg"
            done
        else
            echo "WP Doctor checks passed (no critical errors found after exclusions)."
        fi
    fi
fi

# 5. Perform Updates (Conditional)
if [ "$DRY_RUN_FLAG" = false ]; then
    echo "Performing plugin updates..."
    # Ensure these are reset before starting updates for this run
    SUCCESSFUL_PLUGINS=()
    FAILED_PLUGINS=()
    FAILED_MESSAGES=()

    if [ "$SEO_RANK_ELEMENTOR_UPDATE_FLAG" = true ]; then
        echo "SEO Rank Math & Elementor priority update mode enabled."

        # These are regular shell arrays, not local, as this is not a function
        RANK_MATH_PLUGINS_ORDER=("seo-by-rank-math")
        ELEMENTOR_PLUGINS_ORDER=("elementor-pro" "elementor")

        update_plugin_group "Rank Math" "${RANK_MATH_PLUGINS_ORDER[@]}"
        update_plugin_group "Elementor" "${ELEMENTOR_PLUGINS_ORDER[@]}"

        echo "Updating remaining plugins..."
        # This is a regular shell array
        REMAINING_PLUGINS_TO_UPDATE=()
        for plugin_slug_iter_rem in "${PLUGINS_TO_UPDATE[@]}"; do
            # This variable is scoped to the loop iteration, not declared 'local'
            is_priority_plugin_rem=false
            for p_rank_rem in "${RANK_MATH_PLUGINS_ORDER[@]}"; do
                if [[ "$plugin_slug_iter_rem" == "$p_rank_rem" ]]; then is_priority_plugin_rem=true; break; fi
            done
            if ! $is_priority_plugin_rem; then # Only check Elementor if not already found in Rank Math
                for p_elem_rem in "${ELEMENTOR_PLUGINS_ORDER[@]}"; do
                    if [[ "$plugin_slug_iter_rem" == "$p_elem_rem" ]]; then is_priority_plugin_rem=true; break; fi
                done
            fi

            if ! $is_priority_plugin_rem; then
                REMAINING_PLUGINS_TO_UPDATE+=("$plugin_slug_iter_rem")
            fi
        done

        if [ ${#REMAINING_PLUGINS_TO_UPDATE[@]} -gt 0 ]; then
            if [ "$UPDATE_ALL_FLAG" = true ]; then
                echo "Updating all remaining plugins at once: ${REMAINING_PLUGINS_TO_UPDATE[*]}"
                # Temporary file, not local
                update_stderr_file_all_rem=$(mktemp)
                # Pass the array of remaining plugins to the update command
                if WP_CLI_PHP_ARGS="-d max_execution_time=600" ${WP_CMD} plugin update "${REMAINING_PLUGINS_TO_UPDATE[@]}" 2> "$update_stderr_file_all_rem"; then
                    echo "Successfully updated remaining plugins group."
                    for p_slug in "${REMAINING_PLUGINS_TO_UPDATE[@]}"; do
                        # Variables for checks, not local
                        already_handled_final_check_s=false
                        for sp in "${SUCCESSFUL_PLUGINS[@]}"; do if [[ "$sp" == "$p_slug" ]]; then already_handled_final_check_s=true; break; fi; done
                        for fp in "${FAILED_PLUGINS[@]}"; do if [[ "$fp" == "$p_slug" ]]; then already_handled_final_check_s=true; break; fi; done # Check failed too
                        if ! $already_handled_final_check_s; then SUCCESSFUL_PLUGINS+=("$p_slug"); fi
                    done
                else
                    # Error message variables, not local
                    update_error_msg_all_rem=$(<"$update_stderr_file_all_rem")
                    update_error_msg_all_rem_oneline=$(echo "$update_error_msg_all_rem" | tr -d '\n\r' | sed 's/^Error: //')
                    echo "Failed to update one or more remaining plugins when using --update-all. Error: $update_error_msg_all_rem"
                    for p_slug in "${REMAINING_PLUGINS_TO_UPDATE[@]}"; do
                        # Variables for checks, not local
                        already_handled_final_check_f=false
                        for sp in "${SUCCESSFUL_PLUGINS[@]}"; do if [[ "$sp" == "$p_slug" ]]; then already_handled_final_check_f=true; break; fi; done
                        for fp in "${FAILED_PLUGINS[@]}"; do if [[ "$fp" == "$p_slug" ]]; then already_handled_final_check_f=true; break; fi; done
                        if ! $already_handled_final_check_f; then
                            FAILED_PLUGINS+=("$p_slug")
                            FAILED_MESSAGES+=("Part of failed --update-all group (remaining): $update_error_msg_all_rem_oneline")
                        fi
                    done
                fi
                rm -f "$update_stderr_file_all_rem"
            else
                # Call update_plugin_group for remaining plugins if not --update-all
                update_plugin_group "Other" "${REMAINING_PLUGINS_TO_UPDATE[@]}"
            fi
        else
            echo "No other plugins left to update."
        fi

    elif [ "$UPDATE_ALL_FLAG" = true ]; then # SEO_RANK_ELEMENTOR_UPDATE_FLAG is false, but UPDATE_ALL_FLAG is true
        if [ ${#PLUGINS_TO_UPDATE[@]} -gt 0 ]; then
            echo "Updating all plugins at once: ${PLUGINS_TO_UPDATE[*]}"
            # Temporary file, not local
            update_stderr_file_all_gen=$(mktemp)
            # Pass the array of all plugins to update to the command
            if WP_CLI_PHP_ARGS="-d max_execution_time=600" ${WP_CMD} plugin update "${PLUGINS_TO_UPDATE[@]}" 2> "$update_stderr_file_all_gen"; then
                echo "Successfully updated all plugins."
                # Mark all plugins from PLUGINS_TO_UPDATE as successful if the batch command succeeded
                # and they haven't been marked as failed from a prior (e.g. priority) step.
                for p_slug in "${PLUGINS_TO_UPDATE[@]}"; do
                    # Variables for checks, not local
                    already_handled_gen_s=false
                    for sp in "${SUCCESSFUL_PLUGINS[@]}"; do if [[ "$sp" == "$p_slug" ]]; then already_handled_gen_s=true; break; fi; done
                    for fp in "${FAILED_PLUGINS[@]}"; do if [[ "$fp" == "$p_slug" ]]; then already_handled_gen_s=true; break; fi; done
                    if ! $already_handled_gen_s; then SUCCESSFUL_PLUGINS+=("$p_slug"); fi
                done
            else
                # Error message variables, not local
                update_error_msg_all_gen=$(<"$update_stderr_file_all_gen")
                update_error_msg_all_gen_oneline=$(echo "$update_error_msg_all_gen" | tr -d '\n\r' | sed 's/^Error: //')
                echo "Failed to update one or more plugins when using --update-all. Error: $update_error_msg_all_gen"
                # Mark all plugins from this attempt as failed if the batch failed,
                # unless they were already successfully updated (e.g. in a priority step).
                for p_slug in "${PLUGINS_TO_UPDATE[@]}"; do
                    # Variables for checks, not local
                    already_handled_gen_f=false
                    for sp in "${SUCCESSFUL_PLUGINS[@]}"; do if [[ "$sp" == "$p_slug" ]]; then already_handled_gen_f=true; break; fi; done # Check if already successful
                    for fp in "${FAILED_PLUGINS[@]}"; do if [[ "$fp" == "$p_slug" ]]; then already_handled_gen_f=true; break; fi; done # Check if already failed
                    if ! $already_handled_gen_f; then
                       FAILED_PLUGINS+=("$p_slug")
                       FAILED_MESSAGES+=("Part of failed --update-all group: $update_error_msg_all_gen_oneline")
                    fi
                done
            fi
            rm -f "$update_stderr_file_all_gen"
        else
            echo "No plugins to update with --update-all."
        fi
    else # Original individual update logic (neither SEO_RANK_ELEMENTOR_UPDATE_FLAG nor UPDATE_ALL_FLAG)
        # This loop iterates over PLUGINS_TO_UPDATE.
        # The update_plugin_group function is now the primary way individual plugins are updated
        # when SEO_RANK_ELEMENTOR_UPDATE_FLAG is true and UPDATE_ALL_FLAG is false for the "Other" group.
        # This specific 'else' block will handle the case where neither of those flags are set.
        for plugin_slug_ind in "${PLUGINS_TO_UPDATE[@]}"; do
            # Check if already processed by a (hypothetically) preceding step, though unlikely in this specific path.
            # Variables for checks, not local
            already_s_ind=false; for s_p in "${SUCCESSFUL_PLUGINS[@]}"; do if [[ "$s_p" == "$plugin_slug_ind" ]]; then already_s_ind=true; break; fi; done
            already_f_ind=false; for f_p in "${FAILED_PLUGINS[@]}"; do if [[ "$f_p" == "$plugin_slug_ind" ]]; then already_f_ind=true; break; fi; done
            if $already_s_ind || $already_f_ind; then continue; fi

            echo "Updating plugin (individual mode): $plugin_slug_ind"
            # Temporary file, not local
            update_stderr_file_ind=$(mktemp)
            if WP_CLI_PHP_ARGS="-d max_execution_time=300" ${WP_CMD} plugin update "$plugin_slug_ind" 2> "$update_stderr_file_ind"; then
                echo "Successfully updated: $plugin_slug_ind"
                SUCCESSFUL_PLUGINS+=("$plugin_slug_ind")
            else
                # Error message variables, not local
                update_error_msg_ind=$(<"$update_stderr_file_ind")
                update_error_msg_ind_oneline=$(echo "$update_error_msg_ind" | tr -d '\n\r' | sed 's/^Error: //')
                echo "Failed to update: $plugin_slug_ind. Error: $update_error_msg_ind"
                FAILED_PLUGINS+=("$plugin_slug_ind")
                FAILED_MESSAGES+=("$update_error_msg_ind_oneline")
            fi
            rm -f "$update_stderr_file_ind"
        done
    fi
else
    echo "Skipping plugin updates (Dry Run)."
    # PLUGINS_TO_UPDATE is already populated with plugins that would be updated.
    # The reporting logic uses this array directly in dry run mode.
fi

# Generate results file if requested
if [[ -n "$PRINT_RESULTS_FORMAT" ]]; then
    generate_results_file "$PRINT_RESULTS_FORMAT"
fi

echo "WordPress maintenance process completed."

