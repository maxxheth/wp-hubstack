#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
WP_DIR=""
SUBDIR_PATH="" # Relative path to WP install within WP_DIR
PRINT_RESULTS_FORMAT="" # md, html, or empty (no report)
SKIP_WP_DOCTOR_FLAG=false # Default: Run WP Doctor checks
EXCLUDE_CHECKS_ARG="core-update" # Default checks to exclude
SKIP_PLUGINS_CLI_FLAG=false # Default: Do not skip plugins for WP-CLI
DRY_RUN_FLAG=false # Default: Perform actual updates

# Health check results file (will store raw results from individual checks)
HEALTH_CHECK_FILE="health-check-results.log"
# Results file names
MARKDOWN_RESULTS_FILE="update-results.md"
HTML_RESULTS_FILE="update-results.html"

# Arrays to store doctor check results for reporting
DOCTOR_CHECK_NAMES_RUN=()
DOCTOR_CHECK_STATUSES=()
DOCTOR_CHECK_MESSAGES=()

# --- Helper Functions ---
error_exit() {
    echo "ERROR: $1" >&2
    if [[ -n "$PRINT_RESULTS_FORMAT" && ${#DOCTOR_CHECK_NAMES_RUN[@]} -gt 0 ]]; then
        echo "INFO: Attempting to generate results file before exiting due to error..."
        generate_results_file "$PRINT_RESULTS_FORMAT"
    fi
    exit 1
}

warning_msg() {
    echo "WARNING: $1" >&2
}

# --- Argument Parsing ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --skip-wp-doctor) SKIP_WP_DOCTOR_FLAG=true; shift ;;
        --skip-plugins) SKIP_PLUGINS_CLI_FLAG=true; shift ;;
        --dry-run) DRY_RUN_FLAG=true; shift ;;
        --subdir)
             if [[ -z "$2" || "$2" == --* ]]; then error_exit "Missing value for --subdir flag."; fi
            SUBDIR_PATH="$2"; shift 2 ;;
        --exclude-checks)
            if [[ -z "$2" || "$2" == --* ]]; then error_exit "Missing value for --exclude-checks flag."; fi
            EXCLUDE_CHECKS_ARG="$2"; shift 2 ;;
        --print-results)
            if [[ -n "$2" && "$2" != --* ]]; then
                if [[ "$2" == "md" || "$2" == "html" ]]; then
                    PRINT_RESULTS_FORMAT="$2"; shift 2;
                else
                    warning_msg "Invalid format '$2' for --print-results. Defaulting to Markdown."
                    PRINT_RESULTS_FORMAT="md"; shift;
                fi
            else
                PRINT_RESULTS_FORMAT="md"; shift;
            fi ;;
        *)
           if [ -z "$WP_DIR" ]; then WP_DIR="$1"; else warning_msg "Ignoring unexpected argument: $1"; fi
           shift ;;
    esac
done

# --- Pre-flight Checks ---
if [ -z "$WP_DIR" ]; then
    error_exit "Usage: $0 [--skip-wp-doctor] [--skip-plugins] [--dry-run] [--subdir <relative_path>] [--exclude-checks <check1,check2|none>] [--print-results[=md|html]] <path_to_wordpress_directory>"
fi
if [ ! -d "$WP_DIR" ]; then error_exit "WordPress directory not found: $WP_DIR"; fi
if ! command -v wp &> /dev/null; then error_exit "WP-CLI command 'wp' not found. Please install it."; fi

if [ "$SKIP_WP_DOCTOR_FLAG" = false ]; then
    if ! command -v jq &> /dev/null; then
        error_exit "jq is required for WP Doctor checks but is not installed. Please install jq or use the --skip-wp-doctor flag."
    fi
fi

# --- Result Generation Function ---
generate_results_file() {
    local format="$1"
    local filename=""
    local doctor_checks_run_count=${#DOCTOR_CHECK_NAMES_RUN[@]}
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S %Z")
    # WP_CMD is defined in Main Script Logic, ensure it's available or pass as arg if needed
    local site_url=$($WP_CMD_BASE option get home 2>/dev/null || echo 'N/A') # Use WP_CMD_BASE for site URL as WP_CMD might have --dry-run
    local current_dir=$(pwd)
    local dry_run_notice=""
    if [ "$DRY_RUN_FLAG" = true ]; then
        dry_run_notice="**DRY RUN MODE ACTIVE** - No actual changes were made to plugins."
    fi

    if [[ "$format" == "md" ]]; then
        filename="$MARKDOWN_RESULTS_FILE"
        echo "Generating Markdown results file: $filename"
        {
            echo "# WordPress Maintenance Results"
            echo ""
            echo "**Timestamp:** $timestamp"
            echo "**Site:** $site_url"
            echo "**Directory:** \`$current_dir\`"
            if [[ -n "$SUBDIR_PATH" ]]; then echo "**Subdirectory:** \`$SUBDIR_PATH\`"; fi
            if [ "$SKIP_PLUGINS_CLI_FLAG" = true ]; then echo "**WP-CLI Mode:** --skip-plugins active"; fi
            if [[ -n "$dry_run_notice" ]]; then echo "**Status:** $dry_run_notice"; fi
            echo ""
            echo "## Plugin Update Summary"
            echo "The following plugin update commands were executed:"
            echo "- \`wp ... plugin update seo-by-rank-math\` (full command includes --allow-root and potentially --path, --skip-plugins, --dry-run)"
            echo "- \`wp ... plugin update seo-by-rank-math-pro\`"
            echo "- \`wp ... plugin update elementor\`"
            echo "- \`wp ... plugin update elementor-pro\`"
            echo "- \`wp ... plugin update --all\`"
            echo ""
            echo "*Please check WP-CLI output above for details on individual plugin update statuses.*"
            echo ""
            echo "## WP Doctor Health Checks"
            echo "- Total Checks Run/Attempted: $doctor_checks_run_count"
            echo ""
            if [[ $doctor_checks_run_count -gt 0 ]]; then
                 echo "| Check Name | Status | Message |"
                 echo "|------------|--------|---------|"
                 for (( i=0; i<${#DOCTOR_CHECK_NAMES_RUN[@]}; i++ )); do
                     local msg_escaped=${DOCTOR_CHECK_MESSAGES[$i]//\|/\\|}
                     echo "| \`${DOCTOR_CHECK_NAMES_RUN[$i]}\` | **${DOCTOR_CHECK_STATUSES[$i]}** | ${msg_escaped:-N/A} |"
                 done
            else
                 echo "No WP Doctor checks were run or recorded (possibly skipped)."
            fi
            echo ""
        } > "$filename"
    elif [[ "$format" == "html" ]]; then
        filename="$HTML_RESULTS_FILE"
        echo "Generating HTML results file: $filename"
        {
            echo "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"UTF-8\"><title>WordPress Maintenance Results</title>"
            echo "<style>body{font-family:sans-serif;line-height:1.6;padding:20px}h1,h2{border-bottom:1px solid #eee;padding-bottom:8px}code{background-color:#f0f0f0;padding:2px 4px;border-radius:3px}table{width:100%;border-collapse:collapse;margin-top:15px}th,td{border:1px solid #ddd;padding:8px;text-align:left}</style></head><body>"
            echo "<h1>WordPress Maintenance Results</h1>"
            echo "<p><strong>Timestamp:</strong> $timestamp</p>"
            echo "<p><strong>Site:</strong> <a href=\"$site_url\">$site_url</a></p>"
            echo "<p><strong>Directory:</strong> <code>$current_dir</code></p>"
            if [[ -n "$SUBDIR_PATH" ]]; then echo "<p><strong>Subdirectory:</strong> <code>$SUBDIR_PATH</code></p>"; fi
            if [ "$SKIP_PLUGINS_CLI_FLAG" = true ]; then echo "<p><strong>WP-CLI Mode:</strong> --skip-plugins active</p>"; fi
            if [[ -n "$dry_run_notice" ]]; then echo "<p><strong>Status:</strong> $dry_run_notice</p>"; fi
            echo "<h2>Plugin Update Summary</h2>"
            echo "<p>The following plugin update commands were executed:</p><ul>"
            echo "<li><code>wp ... plugin update seo-by-rank-math</code> (full command includes --allow-root and potentially --path, --skip-plugins, --dry-run)</li>"
            echo "<li><code>wp ... plugin update seo-by-rank-math-pro</code></li>"
            echo "<li><code>wp ... plugin update elementor</code></li>"
            echo "<li><code>wp ... plugin update elementor-pro</code></li>"
            echo "<li><code>wp ... plugin update --all</code></li></ul>"
            echo "<p><em>Please check WP-CLI output above for details on individual plugin update statuses.</em></p>"
            echo "<h2>WP Doctor Health Checks</h2>"
            echo "<p>Total Checks Run/Attempted: $doctor_checks_run_count</p>"
            if [[ $doctor_checks_run_count -gt 0 ]]; then
                echo "<table><thead><tr><th>Check Name</th><th>Status</th><th>Message</th></tr></thead><tbody>"
                for (( i=0; i<${#DOCTOR_CHECK_NAMES_RUN[@]}; i++ )); do
                    local status_class="status-${DOCTOR_CHECK_STATUSES[$i]}"
                    local msg_html=$(echo "${DOCTOR_CHECK_MESSAGES[$i]:-N/A}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g;')
                    echo "<tr><td><code>${DOCTOR_CHECK_NAMES_RUN[$i]}</code></td><td><span class=\"$status_class\">${DOCTOR_CHECK_STATUSES[$i]}</span></td><td>${msg_html}</td></tr>"
                done
                echo "</tbody></table>"
            else
                echo "<p>No WP Doctor checks were run or recorded (possibly skipped).</p>"
            fi
            echo "</body></html>"
        } > "$filename"
    fi
    if [[ -n "$filename" ]]; then echo "Results file generated: $filename"; fi
}

# --- Main Script Logic ---
echo "Simplified WordPress Plugin Update Process for Project Root: $WP_DIR"
if [[ -n "$SUBDIR_PATH" ]]; then echo "Using WordPress Subdirectory: $SUBDIR_PATH"; fi
if [ "$DRY_RUN_FLAG" = true ]; then echo "INFO: --dry-run flag is active. No actual changes will be made to plugins."; fi

WP_CMD_PARTS_BASE=("wp") # For commands that should not be affected by --dry-run, like `option get` or `doctor`
WP_CMD_PARTS_UPDATE=("wp") # For plugin update commands, will include --dry-run if set

if [[ -n "$SUBDIR_PATH" ]]; then
    WP_INSTALL_PATH_ABS=$(realpath "$WP_DIR/$SUBDIR_PATH")
    if [ ! -d "$WP_INSTALL_PATH_ABS" ]; then error_exit "Specified subdirectory '$SUBDIR_PATH' not found at '$WP_INSTALL_PATH_ABS'."; fi
    WP_CMD_PARTS_BASE+=("--path=$WP_INSTALL_PATH_ABS")
    WP_CMD_PARTS_UPDATE+=("--path=$WP_INSTALL_PATH_ABS")
fi

WP_CMD_PARTS_BASE+=("--allow-root")
WP_CMD_PARTS_UPDATE+=("--allow-root")


if [ "$SKIP_PLUGINS_CLI_FLAG" = true ]; then
    WP_CMD_PARTS_BASE+=("--skip-plugins")
    WP_CMD_PARTS_UPDATE+=("--skip-plugins")
    echo "INFO: All WP-CLI commands will use --skip-plugins."
fi

if [ "$DRY_RUN_FLAG" = true ]; then
    WP_CMD_PARTS_UPDATE+=("--dry-run")
fi

WP_CMD_BASE="${WP_CMD_PARTS_BASE[*]}" 
WP_CMD_UPDATE="${WP_CMD_PARTS_UPDATE[*]}"

echo "WP-CLI Base Command (general ops): $WP_CMD_BASE"
echo "WP-CLI Update Command (plugin ops): $WP_CMD_UPDATE"


# Change to WordPress directory (for context, though WP_CMD with --path should handle most cases)
cd "$WP_DIR" || error_exit "Failed to change directory to $WP_DIR"
echo "Changed directory to $(pwd)"

echo "Attempting to update Rank Math SEO..."
$WP_CMD_UPDATE plugin update seo-by-rank-math || warning_msg "Update command for 'seo-by-rank-math' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."
$WP_CMD_UPDATE plugin update seo-by-rank-math-pro || warning_msg "Update command for 'seo-by-rank-math-pro' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Elementor..."
$WP_CMD_UPDATE plugin update elementor || warning_msg "Update command for 'elementor' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."
$WP_CMD_UPDATE plugin update elementor-pro || warning_msg "Update command for 'elementor-pro' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update all other plugins..."
$WP_CMD_UPDATE plugin update --all || warning_msg "Update command for '--all' plugins finished. It might have failed, or no other updates were available. Check output."

echo "Plugin update sequence completed."

if [ "$SKIP_WP_DOCTOR_FLAG" = true ]; then
    echo "Skipping WP Doctor checks as per --skip-wp-doctor flag."
    DOCTOR_CHECK_NAMES_RUN+=("WP Doctor")
    DOCTOR_CHECK_STATUSES+=("skipped")
    DOCTOR_CHECK_MESSAGES+=("All WP Doctor checks skipped via --skip-wp-doctor flag.")
else
    echo "Checking if WP Doctor (wp-cli/doctor-command) is installed..."
    # Use WP_CMD_BASE for package operations as --dry-run is not applicable here
    if ! $WP_CMD_BASE package list --fields=name --format=csv | grep -q "wp-cli/doctor-command"; then
        echo "WP Doctor not found. Attempting to install..."
        if $WP_CMD_BASE package install wp-cli/doctor-command:@stable; then
            echo "WP Doctor (wp-cli/doctor-command) installed successfully."
        else
            error_exit "Failed to install WP Doctor (wp-cli/doctor-command). Please install it manually."
        fi
    else
        echo "WP Doctor is already installed."
    fi

    echo "Running WP Doctor checks individually..."
    > "$HEALTH_CHECK_FILE" # Clear previous health check log
    DOCTOR_ERRORS_FOUND=()

    EXCLUDED_CHECKS_ARRAY=()
    if [[ "$EXCLUDE_CHECKS_ARG" != "none" ]]; then
        IFS=',' read -r -a EXCLUDED_CHECKS_ARRAY <<< "$(echo "$EXCLUDE_CHECKS_ARG" | sed 's/ *, */,/g')"
        echo "WP Doctor: Excluding checks from error report: ${EXCLUDED_CHECKS_ARRAY[*]}"
    else
         echo "WP Doctor: Checking status for all checks (no exclusions)."
    fi

    containsElement () {
      local e match="$1"; shift
      for e; do [[ "$e" == "$match" ]] && return 0; done
      return 1
    }
    # Use WP_CMD_BASE for doctor list and check as --dry-run is not applicable
    DOCTOR_CHECKS_JSON=$($WP_CMD_BASE doctor list --format=json 2>/dev/null)
    if [ -z "$DOCTOR_CHECKS_JSON" ]; then error_exit "Failed to get list of WP Doctor checks (empty output)."; fi
    
    mapfile -t DOCTOR_CHECK_NAMES < <(echo "$DOCTOR_CHECKS_JSON" | jq -r '.[].name')
    if [ ${#DOCTOR_CHECK_NAMES[@]} -eq 0 ]; then warning_msg "No WP Doctor checks found or jq failed to parse them."; fi


    for check_name in "${DOCTOR_CHECK_NAMES[@]}"; do
        DOCTOR_CHECK_NAMES_RUN+=("$check_name")
        if containsElement "$check_name" "${EXCLUDED_CHECKS_ARRAY[@]}"; then
            echo "  Running check: $check_name... Skipped (excluded)."
            DOCTOR_CHECK_STATUSES+=("skipped")
            DOCTOR_CHECK_MESSAGES+=("Excluded by --exclude-checks flag.")
            continue
        fi

        echo -n "  Running check: $check_name... "
        CHECK_STDERR_FILE=$(mktemp)
        CHECK_RESULT_JSON=""
        # Increased memory limit for doctor checks
        # Use WP_CMD_BASE for doctor check
        if ! CHECK_RESULT_JSON=$(WP_CLI_PHP_ARGS="-d memory_limit=512M" $WP_CMD_BASE doctor check "$check_name" --format=json 2> "$CHECK_STDERR_FILE"); then
            check_stderr_content=$(<"$CHECK_STDERR_FILE")
            echo "Failed (command error)"
            DOCTOR_CHECK_STATUSES+=("failed_to_run")
            DOCTOR_CHECK_MESSAGES+=("Command execution failed. Stderr: $check_stderr_content")
            echo "Check: $check_name, Status: failed_to_run, Message: Command execution failed. Stderr: $check_stderr_content" >> "$HEALTH_CHECK_FILE"
            DOCTOR_ERRORS_FOUND+=("Doctor check '$check_name' command failed: $check_stderr_content")
        else
            check_status=$(echo "$CHECK_RESULT_JSON" | jq -r '.status // "unknown"')
            check_message=$(echo "$CHECK_RESULT_JSON" | jq -r '.message // "Could not parse message."')
            if ! echo "$CHECK_RESULT_JSON" | jq -e .status > /dev/null 2>&1; then # Check if status field exists
                 check_stderr_content=$(<"$CHECK_STDERR_FILE") # Capture stderr if jq parsing was problematic
                 check_message="Could not parse JSON result or 'status' field missing. Raw: '$CHECK_RESULT_JSON'. Stderr: '$check_stderr_content'"
            fi
            echo "$check_status"
            DOCTOR_CHECK_STATUSES+=("$check_status")
            DOCTOR_CHECK_MESSAGES+=("$check_message")
            echo "Check: $check_name, Status: $check_status, Message: $check_message" >> "$HEALTH_CHECK_FILE"
            if [[ "$check_status" == "error" ]]; then
                error_entry="Doctor check '$check_name' reported status '$check_status': $check_message"
                warning_msg "$error_entry"
                DOCTOR_ERRORS_FOUND+=("$error_entry")
            elif [[ "$check_status" == "warning" ]]; then
                warning_msg "Doctor check '$check_name' reported status '$check_status': $check_message"
            fi
        fi
        rm -f "$CHECK_STDERR_FILE"
    done

    if [ ${#DOCTOR_ERRORS_FOUND[@]} -gt 0 ]; then
        echo "ERROR: Critical WP Doctor errors found:" >&2
        for err_msg in "${DOCTOR_ERRORS_FOUND[@]}"; do echo "- $err_msg" >&2; done
        # Do not exit here, allow report generation
        warning_msg "Critical WP Doctor errors were found. Check the report."
    else
        echo "WP Doctor checks completed (or no critical errors found after exclusions)."
    fi
fi

if [[ -n "$PRINT_RESULTS_FORMAT" ]]; then
    generate_results_file "$PRINT_RESULTS_FORMAT"
fi

echo "WordPress maintenance process completed."
# If DOCTOR_ERRORS_FOUND is not empty, exit with an error code to signal issues to the calling script.
if [ ${#DOCTOR_ERRORS_FOUND[@]} -gt 0 ] && [ "$SKIP_WP_DOCTOR_FLAG" = false ]; then
    exit 1 # Exit with error if doctor checks ran and found critical errors
fi

exit 0