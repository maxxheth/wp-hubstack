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
SKIP_BACKUP_FLAG=false # Default: Create a backup

# Backup directory name
BACKUP_DIR_NAME="backups"

# Health check results file (will store raw results from individual checks)
HEALTH_CHECK_FILE="health-check-results.log"
# Results file names
MARKDOWN_RESULTS_FILE="update-results.md"
HTML_RESULTS_FILE="update-results.html"

# Arrays to store doctor check results for reporting
DOCTOR_CHECK_NAMES_RUN=()
DOCTOR_CHECK_STATUSES=()
DOCTOR_CHECK_MESSAGES=()
BACKUP_MESSAGE="" # To store backup status for reporting

# --- Helper Functions ---
error_exit() {
    echo "ERROR: $1" >&2
    if [[ -n "$PRINT_RESULTS_FORMAT" ]]; then 
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
        --skip-backup) SKIP_BACKUP_FLAG=true; shift ;;
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
    error_exit "Usage: $0 [--skip-wp-doctor] [--skip-plugins] [--dry-run] [--skip-backup] [--subdir <relative_path>] [--exclude-checks <check1,check2|none>] [--print-results[=md|html]] <path_to_wordpress_directory>"
fi
if [ ! -d "$WP_DIR" ]; then error_exit "WordPress directory not found: $WP_DIR"; fi
if ! command -v wp &> /dev/null; then error_exit "WP-CLI command 'wp' not found. Please install it."; fi
if ! command -v awk &> /dev/null; then error_exit "'awk' command not found. It is required for WP Doctor result parsing if jq is not used."; fi


if [ "$SKIP_BACKUP_FLAG" = false ]; then
    if ! command -v tar &> /dev/null; then error_exit "'tar' command not found, required for backups. Use --skip-backup or install tar."; fi
    if ! command -v gzip &> /dev/null; then error_exit "'gzip' command not found, required for backups. Use --skip-backup or install gzip."; fi
fi


# --- Result Generation Function ---
generate_results_file() {
    local format="$1"
    local filename=""
    local doctor_checks_run_count=${#DOCTOR_CHECK_NAMES_RUN[@]}
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S %Z")
    # WP_CMD_BASE should be defined globally by the time this is called
    local site_url=$($WP_CMD_BASE option get home 2>/dev/null || echo 'N/A') 
    local current_dir=$(pwd) # This will be $WP_DIR as per cd in main logic
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
            if [[ -n "$SUBDIR_PATH" ]]; then echo "**Subdirectory (within WP_DIR):** \`$SUBDIR_PATH\`"; fi
            if [ "$SKIP_PLUGINS_CLI_FLAG" = true ]; then echo "**WP-CLI Mode:** --skip-plugins active"; fi
            if [[ -n "$dry_run_notice" ]]; then echo "**Status:** $dry_run_notice"; fi
            echo ""
            if [[ -n "$BACKUP_MESSAGE" ]]; then
                echo "## Backup Summary"
                echo "$BACKUP_MESSAGE"
                echo ""
            fi
            echo "## Plugin Update Summary"
            echo "The following plugin update commands were executed (details in console output):"
            echo "- \`... plugin update seo-by-rank-math ...\`"
            echo "- \`... plugin update seo-by-rank-math-pro ...\`"
            echo "- \`... plugin update elementor ...\`"
            echo "- \`... plugin update elementor-pro ...\`"
            echo "- \`... plugin update --all ...\`"
            echo ""
            echo "*Full commands include relevant flags like --allow-root, and potentially --path, --skip-plugins, --dry-run.*"
            echo "*Please check WP-CLI output above for details on individual plugin update statuses.*"
            echo ""
            echo "## WP Doctor Health Checks"
            echo "- Total Checks Run/Attempted: $doctor_checks_run_count"
            echo ""
            if [[ $doctor_checks_run_count -gt 0 ]]; then
                 echo "| Check Name | Status | Message |"
                 echo "|------------|--------|---------|"
                 for (( i=0; i<${#DOCTOR_CHECK_NAMES_RUN[@]}; i++ )); do
                     local msg_escaped=${DOCTOR_CHECK_MESSAGES[$i]//\|/\\|} # Basic escaping for Markdown table
                     echo "| \`${DOCTOR_CHECK_NAMES_RUN[$i]}\` | **${DOCTOR_CHECK_STATUSES[$i]}** | ${msg_escaped:-N/A} |"
                 done
            else
                 echo "No WP Doctor checks were run or recorded (possibly skipped or failed to list)."
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
            if [[ -n "$SUBDIR_PATH" ]]; then echo "<p><strong>Subdirectory (within WP_DIR):</strong> <code>$SUBDIR_PATH</code></p>"; fi
            if [ "$SKIP_PLUGINS_CLI_FLAG" = true ]; then echo "<p><strong>WP-CLI Mode:</strong> --skip-plugins active</p>"; fi
            if [[ -n "$dry_run_notice" ]]; then echo "<p><strong>Status:</strong> $dry_run_notice</p>"; fi
            if [[ -n "$BACKUP_MESSAGE" ]]; then
                echo "<h2>Backup Summary</h2>"
                # Convert Markdown backticks for code to HTML <code>
                local backup_msg_html="${BACKUP_MESSAGE//\`/<code>}"
                backup_msg_html="${backup_msg_html//<\/code>/<\/code>}" # Ensure proper closing if already there
                echo "<p>${backup_msg_html}</p>"
            fi
            echo "<h2>Plugin Update Summary</h2>"
            echo "<p>The following plugin update commands were executed (details in console output):</p><ul>"
            echo "<li><code>... plugin update seo-by-rank-math ...</code></li>"
            echo "<li><code>... plugin update seo-by-rank-math-pro ...</code></li>"
            echo "<li><code>... plugin update elementor ...</code></li>"
            echo "<li><code>... plugin update elementor-pro ...</code></li>"
            echo "<li><code>... plugin update --all ...</code></li></ul>"
            echo "<p><em>Full commands include relevant flags like --allow-root, and potentially --path, --skip-plugins, --dry-run.</em></p>"
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
                echo "<p>No WP Doctor checks were run or recorded (possibly skipped or failed to list).</p>"
            fi
            echo "</body></html>"
        } > "$filename"
    fi
    if [[ -n "$filename" ]]; then echo "Results file generated: $filename"; fi
}

# --- Main Script Logic ---
echo "WordPress Maintenance Process for Project Root: $WP_DIR"
if [[ -n "$SUBDIR_PATH" ]]; then echo "Using WordPress Subdirectory: $SUBDIR_PATH"; fi
if [ "$DRY_RUN_FLAG" = true ]; then echo "INFO: --dry-run flag is active. No actual changes will be made to plugins or backups."; fi

WP_CMD_PARTS_BASE=("wp") 
WP_CMD_PARTS_UPDATE=("wp") 

ACTUAL_WP_DIR_FOR_CONTENT="$WP_DIR" # Path used to find wp-content for backups
if [[ -n "$SUBDIR_PATH" ]]; then
    WP_INSTALL_PATH_ABS=$(realpath "$WP_DIR/$SUBDIR_PATH")
    if [ ! -d "$WP_INSTALL_PATH_ABS" ]; then error_exit "Specified subdirectory '$SUBDIR_PATH' not found at '$WP_INSTALL_PATH_ABS'."; fi
    WP_CMD_PARTS_BASE+=("--path=$WP_INSTALL_PATH_ABS")
    WP_CMD_PARTS_UPDATE+=("--path=$WP_INSTALL_PATH_ABS")
    ACTUAL_WP_DIR_FOR_CONTENT="$WP_INSTALL_PATH_ABS" 
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

# Change to the main WordPress directory (WP_DIR) for consistent relative pathing for backups
cd "$WP_DIR" || error_exit "Failed to change directory to $WP_DIR"
echo "Changed directory to $(pwd) for overall script context."

# --- Backup Logic ---
PLUGINS_DIR_PATH_RELATIVE_TO_ACTUAL_WP_DIR="wp-content/plugins" # Relative path for tar
PLUGINS_DIR_FULL_PATH="${ACTUAL_WP_DIR_FOR_CONTENT}/${PLUGINS_DIR_PATH_RELATIVE_TO_ACTUAL_WP_DIR}"
BACKUP_STORAGE_DIR="${WP_DIR}/${BACKUP_DIR_NAME}" # Backups stored relative to the root WP_DIR passed to the script

if [ "$SKIP_BACKUP_FLAG" = true ]; then
    echo "Skipping plugins backup as per --skip-backup flag."
    BACKUP_MESSAGE="Plugins backup skipped via --skip-backup flag."
elif [ "$DRY_RUN_FLAG" = true ]; then
    echo "DRY RUN: Skipping actual plugins backup. Would backup: $PLUGINS_DIR_FULL_PATH"
    BACKUP_MESSAGE="Plugins backup skipped due to --dry-run mode."
else
    if [ ! -d "$PLUGINS_DIR_FULL_PATH" ]; then
        warning_msg "Plugins directory not found at '$PLUGINS_DIR_FULL_PATH'. Skipping backup."
        BACKUP_MESSAGE="Plugins backup skipped: Directory '$PLUGINS_DIR_FULL_PATH' not found."
    else
        echo "Attempting to backup plugins directory: $PLUGINS_DIR_FULL_PATH"
        mkdir -p "$BACKUP_STORAGE_DIR" || error_exit "Failed to create backup directory: $BACKUP_STORAGE_DIR"
        
        TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
        BACKUP_FILENAME="plugins-backup-${TIMESTAMP}.tar.gz"
        BACKUP_FILE_PATH_FULL="${BACKUP_STORAGE_DIR}/${BACKUP_FILENAME}"
        
        echo "Creating backup: $BACKUP_FILE_PATH_FULL ..."
        # Tar from ACTUAL_WP_DIR_FOR_CONTENT to keep 'wp-content/plugins' in the archive
        if (cd "$ACTUAL_WP_DIR_FOR_CONTENT" && tar -czf "$BACKUP_FILE_PATH_FULL" "$PLUGINS_DIR_PATH_RELATIVE_TO_ACTUAL_WP_DIR"); then
            echo "Plugins backup created successfully: $BACKUP_FILE_PATH_FULL"
            BACKUP_MESSAGE="Plugins backup successfully created: \`$BACKUP_FILE_PATH_FULL\`"
        else
            warning_msg "Plugins backup failed. Check tar/gzip output."
            BACKUP_MESSAGE="Plugins backup FAILED. Check script output for errors from tar/gzip."
        fi
    fi
fi

# --- Plugin Update Logic ---
echo "Attempting to update Rank Math SEO..."

$WP_CMD_UPDATE plugin update seo-by-rank-math || warning_msg "Update command for 'seo-by-rank-math' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."
$WP_CMD_UPDATE plugin update seo-by-rank-math-pro || warning_msg "Update command for 'seo-by-rank-math-pro' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Elementor..."
$WP_CMD_UPDATE plugin update elementor || warning_msg "Update command for 'elementor' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."
$WP_CMD_UPDATE plugin update elementor-pro || warning_msg "Update command for 'elementor-pro' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Accelerated Mobile Pages (AMP)..."

$WP_CMD_UPDATE plugin update accelerated-mobile-pages || warning_msg "Update command for 'accelerated-mobile-pages' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Advanced AJAX Product Filters for WooCommerce..."

$WP_CMD_UPDATE plugin update woocommerce-ajax-filters || warning_msg "Update command for 'advanced-ajax-product-filters-for-woocommerce' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update All-in-One WP Migration..."

$WP_CMD_UPDATE plugin update all-in-one-wp-migration || warning_msg "Update command for 'all-in-one-wp-migration' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Astra Pro..."

$WP_CMD_UPDATE plugin update astra-pro || warning_msg "Update command for 'astra-pro' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update B Slider..."

$WP_CMD_UPDATE plugin update b-slider || warning_msg "Update command for 'b-slider' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Better Find and Replace..."

$WP_CMD_UPDATE plugin update real-time-auto-find-and-replace || warning_msg "Update command for 'real-time-auto-find-and-replace' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Big File Uploads..."

$WP_CMD_UPDATE plugin update tuxedo-big-file-uploads || warning_msg "Update command for 'tuxedo-big-file-uploads' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Compact Audio Player..."

$WP_CMD_UPDATE plugin update compact-audio-player || warning_msg "Update command for 'compact-audio-player' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Contact Form 7..."

$WP_CMD_UPDATE plugin update contact-form-7 || warning_msg "Update command for 'contact-form-7' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Head, Footer and Post Injections..."

$WP_CMD_UPDATE plugin update header-footer || warning_msg "Update command for 'header-footer' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Master Addons for Elementor..."

$WP_CMD_UPDATE plugin update master-addons || warning_msg "Update command for 'master-addons' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update MWB HubSpot for WooCommerce..."

$WP_CMD_UPDATE plugin update makewebbetter-hubspot-for-woocommerce || warning_msg "Update command for 'makewebbetter-hubspot-for-woocommerce' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Pionet Addons for Elementor..."

$WP_CMD_UPDATE plugin update pionet-addons-for-elementor || warning_msg "Update command for 'pionet-addons-for-elementor' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Relevanssi..."

$WP_CMD_UPDATE plugin update relevanssi || warning_msg "Update command for 'relevanssi' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Sassy Social Share..."

$WP_CMD_UPDATE plugin update sassy-social-share || warning_msg "Update command for 'sassy-social-share' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update ShareThis Dashboard for Google Analytics..."

$WP_CMD_UPDATE plugin update googleanalytics || warning_msg "Update command for 'googleanalytics' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Shortcodes Ultimate..."

$WP_CMD_UPDATE plugin update shortcodes-ultimate || warning_msg "Update command for 'shortcodes-ultimate' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update ShiftNav Pro..."

$WP_CMD_UPDATE plugin update shiftnav-pro-responsive-mobile-menu || warning_msg "Update command for 'shiftnav-pro' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Shortcoder..."

$WP_CMD_UPDATE plugin update shortcoder || warning_msg "Update command for 'shortcoder' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Simple 301 Redirects..."

$WP_CMD_UPDATE plugin update simple-301-redirects || warning_msg "Update command for 'simple-301-redirects' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Simple Custom CSS and JS..."

$WP_CMD_UPDATE plugin update simple-custom-css-and-js || warning_msg "Update command for 'simple-custom-css-and-js' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Gravity Forms..."

$WP_CMD_UPDATE plugin update gravityforms || warning_msg "Update command for 'gravityforms' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Ultimate Elementor..."

$WP_CMD_UPDATE plugin update ultimate-elementor || warning_msg "Update command for 'ultimate-elementor' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Schema & Structured Data for WP & AMP..."

$WP_CMD_UPDATE plugin update schema-and-structured-data-for-wp || warning_msg "Update command for 'schema-and-structured-data-for-wp' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update Yoast..."

$WP_CMD_UPDATE plugin update wordpress-seo || warning_msg "Update command for 'wordpress-seo' finished. It might have failed, or the plugin was not found/already up-to-date. Check output."

echo "Attempting to update all other plugins..."

$WP_CMD_UPDATE plugin update --all || warning_msg "Update command for '--all' plugins finished. It might have failed, or no other updates were available. Check output."

echo "Plugin update sequence completed."

# --- WP Doctor Logic ---
if [ "$SKIP_WP_DOCTOR_FLAG" = true ]; then
    echo "Skipping WP Doctor checks as per --skip-wp-doctor flag."
    DOCTOR_CHECK_NAMES_RUN+=("WP Doctor")
    DOCTOR_CHECK_STATUSES+=("skipped")
    DOCTOR_CHECK_MESSAGES+=("All WP Doctor checks skipped via --skip-wp-doctor flag.")
else
    echo "Checking if WP Doctor (wp-cli/doctor-command) is installed..."
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
    > "$HEALTH_CHECK_FILE" 
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
    
    mapfile -t DOCTOR_CHECK_NAMES < <($WP_CMD_BASE doctor list --format=csv 2>/dev/null | awk -F',' 'NR > 1 {print $1}')
    if [ ${#DOCTOR_CHECK_NAMES[@]} -eq 0 ]; then 
        warning_msg "No WP Doctor checks found or failed to parse the list. WP Doctor checks will be skipped."
        # Add a placeholder to report that checks were attempted but none found/parsed
        DOCTOR_CHECK_NAMES_RUN+=("WP Doctor Check Listing")
        DOCTOR_CHECK_STATUSES+=("error")
        DOCTOR_CHECK_MESSAGES+=("Failed to list or parse WP Doctor checks. No individual checks were run.")
    fi

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
        CHECK_RESULT_RAW=""
        if ! CHECK_RESULT_RAW=$(WP_CLI_PHP_ARGS="-d memory_limit=512M" $WP_CMD_BASE doctor check "$check_name" --format=json 2> "$CHECK_STDERR_FILE"); then
            check_stderr_content=$(<"$CHECK_STDERR_FILE")
            echo "Failed (command error)"
            DOCTOR_CHECK_STATUSES+=("failed_to_run")
            DOCTOR_CHECK_MESSAGES+=("Command execution failed. Stderr: $check_stderr_content")
            echo "Check: $check_name, Status: failed_to_run, Message: Command execution failed. Stderr: $check_stderr_content" >> "$HEALTH_CHECK_FILE"
            DOCTOR_ERRORS_FOUND+=("Doctor check '$check_name' command failed: $check_stderr_content")
        else
            check_status=$(echo "$CHECK_RESULT_RAW" | awk -F'"' '/"status":/ {print $4; exit}')
            
            temp_message_from_awk=$(echo "$CHECK_RESULT_RAW" | awk -F'"' '/"message":/ {print $4; exit}')
            if [ -n "$temp_message_from_awk" ]; then
                check_message="$temp_message_from_awk"
            else
                # awk returned empty for message. Was it explicitly an empty string in JSON, or missing/malformed?
                if echo "$CHECK_RESULT_RAW" | grep -q '"message": *"*"'; then # Check for "message": "" or "message":"" etc.
                    check_message="" # Legitimately empty
                else
                    check_message="Could not retrieve message details." # Missing, malformed, or other parse error for message
                fi
            fi

            if [ -z "$check_status" ]; then 
                check_status="unknown"
                # If status is unknown, the message might be more informative if it wasn't "Could not retrieve"
                if [[ "$check_message" == "Could not retrieve message details." ]]; then
                     check_message="Status unknown. Raw output: '$CHECK_RESULT_RAW'"
                     if [ -s "$CHECK_STDERR_FILE" ]; then check_message+=" Stderr: $(<"$CHECK_STDERR_FILE")"; fi
                fi
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
        warning_msg "Critical WP Doctor errors were found. Check the report."
    else
        if [ ${#DOCTOR_CHECK_NAMES[@]} -gt 0 ]; then # Only print if checks were attempted
             echo "WP Doctor checks completed (or no critical errors found after exclusions)."
        fi
    fi
fi

if [[ -n "$PRINT_RESULTS_FORMAT" ]]; then
    generate_results_file "$PRINT_RESULTS_FORMAT"
fi

echo "WordPress maintenance process completed."
if [ ${#DOCTOR_ERRORS_FOUND[@]} -gt 0 ] && [ "$SKIP_WP_DOCTOR_FLAG" = false ]; then
    exit 1 
fi

exit 0