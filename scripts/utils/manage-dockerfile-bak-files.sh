#!/bin/bash

# Script to manage Dockerfile.bak.* files within WordPress installations.

# --- Script Configuration & Defaults ---
APP_NAME=$(basename "$0")
PARENT_DIR="."
ACTION=""
ALWAYS_YES=false
WP_SITE_DIRS_RAW="" # Added for --wp-site-dir
DRY_RUN_MODE=false # Added for --dry-run

# --- Helper Functions ---
display_help() {
    echo "Usage: $APP_NAME [options]"
    echo "Manages Dockerfile.bak.* files within WordPress installations."
    echo
    echo "Options:"
    echo "  --parent-dir <dir>         Specify the parent directory to search for WP sites (default: current directory '$PARENT_DIR')."
    echo "                             This is ignored if --wp-site-dir is used."
    echo "  --wp-site-dir <dir1|dir2>  Specify specific WordPress site directory/directories to manage, separated by '|'."
    echo "                             If used, --parent-dir is ignored for site discovery."
    echo
    echo "Actions (only one action can be performed per run):"
    echo "  --list-backups             List all Dockerfile.bak.* files (default action if no other action specified)."
    echo "  --delete                   Interactively select a backup file to delete."
    echo "  --delete-all               Delete all Dockerfile.bak.* files for the selected/all site(s)."
    echo "  --delete-except-latest     Delete all Dockerfile.bak.* files except the most recent one."
    echo "  --delete-except-earliest   Delete all Dockerfile.bak.* files except the oldest (earliest) one."
    echo "  --restore                  Interactively restore a Dockerfile from a backup."
    echo "  --restore-latest           Restore the Dockerfile from the most recent backup."
    echo "  --restore-earliest         Restore the Dockerfile from the oldest (earliest) backup."
    echo
    echo "  --dry-run                  Perform a dry run; show what would be done without making changes."
    echo "  -y, --yes                  Automatically answer yes to prompts (e.g., for deletion or restoration)."
    echo "  -h, --help                 Display this help message."
    echo
    echo "Examples:"
    echo "  $APP_NAME --parent-dir /var/www --restore-latest # Operates on all sites found in /var/www"
    echo "  $APP_NAME --wp-site-dir /var/www/site1 --restore-latest"
    echo "  $APP_NAME --wp-site-dir \"/var/www/site1|/var/www/site2\" --delete-all -y"
    echo "  $APP_NAME --parent-dir /websites --delete-all -y"
    echo "  $APP_NAME # Lists backups in current directory's WP sites"
    echo "  $APP_NAME --wp-site-dir /var/www/mysite --restore"
    echo "  $APP_NAME --delete-except-earliest"
}

confirm_action() {
    local prompt_message="$1"
    if [[ "$ALWAYS_YES" == "true" ]]; then
        return 0 # Yes
    fi
    local response
    while true; do
        read -r -p "$prompt_message [y/N]: " response
        case "$response" in
            [yY][eE][sS]|[yY]) return 0 ;; # Yes
            [nN][oO]|[nN]|"") return 1 ;;  # No or Enter
            *) echo "Please answer yes or no." ;;
        esac
    done
}

# --- Argument Parsing ---
ACTION_FLAG_COUNT=0
TEMP_PARENT_DIR="$PARENT_DIR"

if [[ "$#" -eq 0 ]]; then
    ACTION="list_backups"
else
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --parent-dir)
                if [[ -z "$2" || "$2" == -* ]]; then echo "Error: --parent-dir requires an argument." >&2; display_help; exit 1; fi
                TEMP_PARENT_DIR="$2"; shift 2 ;;
            --wp-site-dir)
                if [[ -z "$2" || "$2" == -* ]]; then echo "Error: --wp-site-dir requires an argument." >&2; display_help; exit 1; fi
                WP_SITE_DIRS_RAW="$2"; shift 2 ;;
            --list-backups)
                if [[ -n "$ACTION" ]]; then echo "Error: Only one action flag allowed. ('$ACTION' already set)" >&2; display_help; exit 1; fi
                ACTION="list_backups"; ACTION_FLAG_COUNT=$((ACTION_FLAG_COUNT + 1)); shift ;;
            --delete)
                if [[ -n "$ACTION" ]]; then echo "Error: Only one action flag allowed. ('$ACTION' already set)" >&2; display_help; exit 1; fi
                ACTION="delete"; ACTION_FLAG_COUNT=$((ACTION_FLAG_COUNT + 1)); shift ;;
            --delete-all)
                if [[ -n "$ACTION" ]]; then echo "Error: Only one action flag allowed. ('$ACTION' already set)" >&2; display_help; exit 1; fi
                ACTION="delete_all"; ACTION_FLAG_COUNT=$((ACTION_FLAG_COUNT + 1)); shift ;;
            --delete-except-latest)
                if [[ -n "$ACTION" ]]; then echo "Error: Only one action flag allowed. ('$ACTION' already set)" >&2; display_help; exit 1; fi
                ACTION="delete_except_latest"; ACTION_FLAG_COUNT=$((ACTION_FLAG_COUNT + 1)); shift ;;
            --delete-except-earliest)
                if [[ -n "$ACTION" ]]; then echo "Error: Only one action flag allowed. ('$ACTION' already set)" >&2; display_help; exit 1; fi
                ACTION="delete_except_earliest"; ACTION_FLAG_COUNT=$((ACTION_FLAG_COUNT + 1)); shift ;;
            --restore)
                if [[ -n "$ACTION" ]]; then echo "Error: Only one action flag allowed. ('$ACTION' already set)" >&2; display_help; exit 1; fi
                ACTION="restore"; ACTION_FLAG_COUNT=$((ACTION_FLAG_COUNT + 1)); shift ;;
            --restore-latest)
                if [[ -n "$ACTION" ]]; then echo "Error: Only one action flag allowed. ('$ACTION' already set)" >&2; display_help; exit 1; fi
                ACTION="restore_latest"; ACTION_FLAG_COUNT=$((ACTION_FLAG_COUNT + 1)); shift ;;
            --restore-earliest)
                if [[ -n "$ACTION" ]]; then echo "Error: Only one action flag allowed. ('$ACTION' already set)" >&2; display_help; exit 1; fi
                ACTION="restore_earliest"; ACTION_FLAG_COUNT=$((ACTION_FLAG_COUNT + 1)); shift ;;
            --dry-run) DRY_RUN_MODE=true; shift ;;
            -y|--yes) ALWAYS_YES=true; shift ;;
            -h|--help) display_help; exit 0 ;;
            *) echo "Error: Unknown parameter passed: $1"; display_help; exit 1 ;;
        esac
    done
fi

PARENT_DIR="$TEMP_PARENT_DIR"

if [[ "$ACTION_FLAG_COUNT" -gt 1 ]]; then
    echo "Error: Too many action flags specified. Please choose only one." >&2
    display_help
    exit 1
fi

if [[ -z "$ACTION" ]]; then
    ACTION="list_backups"
fi

# --- Core Functions ---

find_wp_sites() {
    local search_dir="$1"
    find "$search_dir" -maxdepth 3 -type f -name 'wp-config.php' -printf '%h\n' 2>/dev/null | \
    sed 's|/www$||' | \
    sort -u | \
    while IFS= read -r dir_path; do
        if [[ -d "$dir_path" ]]; then
            local rp
            rp=$(realpath -m "$dir_path" 2>/dev/null)
            if [[ -n "$rp" && -d "$rp" ]]; then
                echo "$rp"
            elif [[ -d "$dir_path" ]]; then
                echo "$dir_path"
            fi
        fi
    done | grep . # Filter out potential empty lines
}

get_backup_files_newline_separated() {
    local site_dir="$1"
    echo "DEBUG: In get_backup_files_newline_separated for site_dir: $site_dir" >&2 # DEBUG
    local files_with_timestamps=()
    local found_files_count=0       # DEBUG
    local processed_files_count=0   # DEBUG

    # Temporarily remove 2>/dev/null from find to see potential errors
    while IFS= read -r -d $'\0' filepath; do
        ((found_files_count++)) # DEBUG
        filename=$(basename "$filepath")
        echo "DEBUG: Found file by find: $filepath (filename: $filename)" >&2 # DEBUG
        timestamp=$(echo "$filename" | sed -n 's/^Dockerfile\.bak\.\([0-9]\{8\}_[0-9]\{6\}\).*/\1/p')
        if [[ -n "$timestamp" ]]; then
            echo "DEBUG: Extracted timestamp '$timestamp' for file '$filename'" >&2 # DEBUG
            files_with_timestamps+=("${timestamp}"$'\0'"${filepath}")
            ((processed_files_count++)) # DEBUG
        else
            echo "DEBUG: No valid timestamp found in filename '$filename'. Skipping." >&2 # DEBUG
        fi
    done < <(find "$site_dir" -maxdepth 1 -type f -name 'Dockerfile.bak.*' -print0) # Removed 2>/dev/null for debugging

    echo "DEBUG: For $site_dir - Total files found by find: $found_files_count. Files processed with valid timestamp: $processed_files_count." >&2 # DEBUG

    if [[ ${#files_with_timestamps[@]} -gt 0 ]]; then
        printf "%s\0" "${files_with_timestamps[@]}" | \
        sort -z -t $'\0' -k1,1 | \
        while IFS= read -r -d $'\0' sorted_line; do
            echo "${sorted_line#*$'\0'}" # Extract and print filepath
        done
    else
        echo "DEBUG: No files with valid timestamps found to sort and output for $site_dir." >&2 # DEBUG
    fi
}

# --- Action Implementations ---

perform_list_backups() {
    local current_site_path="$1"
    declare -n current_backups_ref="$2"

    if [[ ${#current_backups_ref[@]} -eq 0 ]]; then
        echo "  No backups found for $current_site_path."
    else
        echo "  Backups for $current_site_path (sorted oldest to newest):"
        for backup_file in "${current_backups_ref[@]}"; do
            echo "    - $(basename "$backup_file")"
        done
    fi
}

perform_delete_interactive() {
    local current_site_path="$1"
    declare -n current_backups_ref="$2"

    if [[ ${#current_backups_ref[@]} -eq 0 ]]; then
        echo "  No backups available to delete for $current_site_path."
        return
    fi

    echo "  Available backups for $current_site_path (sorted oldest to newest):"
    for i in "${!current_backups_ref[@]}"; do
        echo "    $((i+1))) $(basename "${current_backups_ref[$i]}")"
    done

    local choice selected_backup_path
    while true; do
        read -r -p "  Select a backup to delete (1-${#current_backups_ref[@]}), or 0 to cancel: " choice
        if [[ "$choice" == "0" ]]; then echo "  Deletion cancelled."; return; fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#current_backups_ref[@]} )); then
            selected_backup_path="${current_backups_ref[$((choice-1))]}"
            break
        else
            echo "  Invalid selection. Please enter a number between 1 and ${#current_backups_ref[@]}, or 0."
        fi
    done

    if confirm_action "  Are you sure you want to delete '$(basename "$selected_backup_path")' from $current_site_path?"; then
        if [[ "$DRY_RUN_MODE" == "true" ]]; then
            echo "  [DRY RUN] Would delete: $(basename "$selected_backup_path")"
        elif rm "$selected_backup_path"; then
            echo "  Deleted: $(basename "$selected_backup_path")"
        else
            echo "  ERROR: Failed to delete '$selected_backup_path'."
        fi
    else
        echo "  Deletion cancelled by user for $current_site_path."
    fi
}

perform_delete_all() {
    local current_site_path="$1"
    declare -n current_backups_ref="$2"

    if [[ ${#current_backups_ref[@]} -eq 0 ]]; then
        echo "  No backups found to delete for $current_site_path."
        return
    fi

    echo "  Targeting all ${#current_backups_ref[@]} backup(s) for deletion in $current_site_path:"
    for backup_file in "${current_backups_ref[@]}"; do
        echo "    - $(basename "$backup_file")"
    done

    if confirm_action "  Are you sure you want to delete ALL ${#current_backups_ref[@]} backup(s) for $current_site_path?"; then
        local delete_count=0
        for backup_file in "${current_backups_ref[@]}"; do
            if [[ "$DRY_RUN_MODE" == "true" ]]; then
                echo "    [DRY RUN] Would delete: $(basename "$backup_file")"
                delete_count=$((delete_count + 1))
            elif rm "$backup_file"; then
                echo "    Deleted: $(basename "$backup_file")"
                delete_count=$((delete_count + 1))
            else
                echo "    ERROR: Failed to delete '$backup_file'."
            fi
        done
        if [[ "$DRY_RUN_MODE" == "true" ]]; then
            echo "  [DRY RUN] Summary: Would delete $delete_count of ${#current_backups_ref[@]} backup(s) for $current_site_path."
        else
            echo "  Summary: Deleted $delete_count of ${#current_backups_ref[@]} backup(s) for $current_site_path."
        fi
    else
        echo "  Deletion cancelled by user for $current_site_path."
    fi
}

perform_delete_except_latest() {
    local current_site_path="$1"
    declare -n current_backups_ref="$2"
    local num_backups=${#current_backups_ref[@]}

    if [[ "$num_backups" -le 1 ]]; then
        echo "  Not enough backups to perform 'delete except latest' for $current_site_path (found $num_backups, need >1)."
        return
    fi

    local latest_backup_path="${current_backups_ref[$((num_backups-1))]}"
    echo "  Latest backup for $current_site_path (will be KEPT): $(basename "$latest_backup_path")"

    local backups_to_delete=()
    for i in $(seq 0 $((num_backups-2)) ); do
        backups_to_delete+=("${current_backups_ref[$i]}")
    done

    if [[ ${#backups_to_delete[@]} -eq 0 ]]; then
        echo "  No older backups to delete." # Should not happen if num_backups > 1
        return
    fi

    echo "  The following ${#backups_to_delete[@]} older backup(s) will be targeted for deletion:"
    for backup_file in "${backups_to_delete[@]}"; do
        echo "    - $(basename "$backup_file")"
    done

    if confirm_action "  Delete these ${#backups_to_delete[@]} older backup(s) for $current_site_path?"; then
        local delete_count=0
        for backup_file in "${backups_to_delete[@]}"; do
            if [[ "$DRY_RUN_MODE" == "true" ]]; then
                echo "    [DRY RUN] Would delete: $(basename "$backup_file")"
                delete_count=$((delete_count + 1))
            elif rm "$backup_file"; then
                echo "    Deleted: $(basename "$backup_file")"
                delete_count=$((delete_count + 1))
            else
                echo "    ERROR: Failed to delete '$backup_file'."
            fi
        done
        if [[ "$DRY_RUN_MODE" == "true" ]]; then
            echo "  [DRY RUN] Summary: Would delete $delete_count of ${#backups_to_delete[@]} older backup(s) for $current_site_path."
        else
            echo "  Summary: Deleted $delete_count of ${#backups_to_delete[@]} older backup(s) for $current_site_path."
        fi
    else
        echo "  Deletion cancelled by user for $current_site_path."
    fi
}

perform_delete_except_earliest() {
    local current_site_path="$1"
    declare -n current_backups_ref="$2"
    local num_backups=${#current_backups_ref[@]}

    if [[ "$num_backups" -le 1 ]]; then
        echo "  Not enough backups to perform 'delete except earliest' for $current_site_path (found $num_backups, need >1)."
        return
    fi

    local earliest_backup_path="${current_backups_ref[0]}"
    echo "  Earliest backup for $current_site_path (will be KEPT): $(basename "$earliest_backup_path")"

    local backups_to_delete=()
    for i in $(seq 1 $((num_backups-1)) ); do
        backups_to_delete+=("${current_backups_ref[$i]}")
    done

    if [[ ${#backups_to_delete[@]} -eq 0 ]]; then
        echo "  No newer backups to delete." # Should not happen if num_backups > 1
        return
    fi

    echo "  The following ${#backups_to_delete[@]} newer backup(s) will be targeted for deletion:"
    for backup_file in "${backups_to_delete[@]}"; do
        echo "    - $(basename "$backup_file")"
    done

    if confirm_action "  Delete these ${#backups_to_delete[@]} newer backup(s) for $current_site_path?"; then
        local delete_count=0
        for backup_file in "${backups_to_delete[@]}"; do
            if [[ "$DRY_RUN_MODE" == "true" ]]; then
                echo "    [DRY RUN] Would delete: $(basename "$backup_file")"
                delete_count=$((delete_count + 1))
            elif rm "$backup_file"; then
                echo "    Deleted: $(basename "$backup_file")"
                delete_count=$((delete_count + 1))
            else
                echo "    ERROR: Failed to delete '$backup_file'."
            fi
        done
        if [[ "$DRY_RUN_MODE" == "true" ]]; then
            echo "  [DRY RUN] Summary: Would delete $delete_count of ${#backups_to_delete[@]} newer backup(s) for $current_site_path."
        else
            echo "  Summary: Deleted $delete_count of ${#backups_to_delete[@]} newer backup(s) for $current_site_path."
        fi
    else
        echo "  Deletion cancelled by user for $current_site_path."
    fi
}

perform_restore() {
    local current_site_path="$1"
    declare -n current_backups_ref="$2"
    local dockerfile_path="$current_site_path/Dockerfile"

    if [[ ${#current_backups_ref[@]} -eq 0 ]]; then
        echo "  No backups available to restore for $current_site_path."
        return
    fi

    echo "  Available backups for $current_site_path (sorted oldest to newest):"
    for i in "${!current_backups_ref[@]}"; do
        echo "    $((i+1))) $(basename "${current_backups_ref[$i]}")"
    done

    local choice selected_backup_path
    while true; do
        read -r -p "  Select a backup to restore to '$dockerfile_path' (1-${#current_backups_ref[@]}), or 0 to cancel: " choice
        if [[ "$choice" == "0" ]]; then echo "  Restore cancelled."; return; fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#current_backups_ref[@]} )); then
            selected_backup_path="${current_backups_ref[$((choice-1))]}"
            break
        else
            echo "  Invalid selection. Please enter a number between 1 and ${#current_backups_ref[@]}, or 0."
        fi
    done

    if confirm_action "  Restore '$dockerfile_path' from '$(basename "$selected_backup_path")'?"; then
        if [[ "$DRY_RUN_MODE" == "true" ]]; then
            echo "  [DRY RUN] Would restore '$dockerfile_path' from '$(basename "$selected_backup_path")'."
        elif cp "$selected_backup_path" "$dockerfile_path"; then
            echo "  SUCCESS: '$dockerfile_path' restored from '$(basename "$selected_backup_path")'."
        else
            echo "  ERROR: Failed to restore '$dockerfile_path' from '$(basename "$selected_backup_path")'."
        fi
    else
        echo "  Restore cancelled by user."
    fi
}

perform_restore_latest() {
    local current_site_path="$1"
    declare -n current_backups_ref="$2"
    local dockerfile_path="$current_site_path/Dockerfile"

    if [[ ${#current_backups_ref[@]} -eq 0 ]]; then
        echo "  No backups available to restore for $current_site_path."
        return
    fi

    local latest_backup_path="${current_backups_ref[${#current_backups_ref[@]}-1]}"

    if confirm_action "  Restore '$dockerfile_path' from the latest backup '$(basename "$latest_backup_path")'?"; then
        if [[ "$DRY_RUN_MODE" == "true" ]]; then
            echo "  [DRY RUN] Would restore '$dockerfile_path' from '$(basename "$latest_backup_path")'."
        elif cp "$latest_backup_path" "$dockerfile_path"; then
            echo "  SUCCESS: '$dockerfile_path' restored from '$(basename "$latest_backup_path")'."
        else
            echo "  ERROR: Failed to restore '$dockerfile_path' from '$(basename "$latest_backup_path")'."
        fi
    else
        echo "  Restore cancelled by user."
    fi
}

perform_restore_earliest() {
    local current_site_path="$1"
    declare -n current_backups_ref="$2"
    local dockerfile_path="$current_site_path/Dockerfile"

    if [[ ${#current_backups_ref[@]} -eq 0 ]]; then
        echo "  No backups available to restore for $current_site_path."
        return
    fi

    local earliest_backup_path="${current_backups_ref[0]}" # Backups are sorted oldest to newest

    if confirm_action "  Restore '$dockerfile_path' from the earliest backup '$(basename "$earliest_backup_path")'?"; then
        if [[ "$DRY_RUN_MODE" == "true" ]]; then
            echo "  [DRY RUN] Would restore '$dockerfile_path' from '$(basename "$earliest_backup_path")'."
        elif cp "$earliest_backup_path" "$dockerfile_path"; then
            echo "  SUCCESS: '$dockerfile_path' restored from '$(basename "$earliest_backup_path")'."
        else
            echo "  ERROR: Failed to restore '$dockerfile_path' from '$(basename "$earliest_backup_path")'."
        fi
    else
        echo "  Restore cancelled by user."
    fi
}


# --- Main Execution ---
echo "WordPress Dockerfile Backup Manager"
echo "-----------------------------------"
if [[ "$DRY_RUN_MODE" == "true" ]]; then
    echo "*** DRY RUN MODE ENABLED - NO CHANGES WILL BE MADE ***"
    echo "-----------------------------------"
fi

declare -a TARGET_SITES_ARRAY

if [[ -n "$WP_SITE_DIRS_RAW" ]]; then
    echo "Processing specified WordPress site directories from --wp-site-dir: $WP_SITE_DIRS_RAW"
    IFS='|' read -r -a TARGET_SITES_ARRAY <<< "$WP_SITE_DIRS_RAW"
    
    # Validate specified directories
    declare -a VALIDATED_TARGET_SITES_ARRAY
    for site_path_candidate in "${TARGET_SITES_ARRAY[@]}"; do
        # Attempt to resolve to a real path, handling potential relative paths
        resolved_path_candidate=$(realpath -m "$site_path_candidate" 2>/dev/null)
        if [[ -n "$resolved_path_candidate" && -d "$resolved_path_candidate" ]]; then
            # Further check if it looks like a WP site by checking for wp-config.php
            if [[ -f "$resolved_path_candidate/wp-config.php" ]]; then
                VALIDATED_TARGET_SITES_ARRAY+=("$resolved_path_candidate")
                echo "  Validated WP site: $resolved_path_candidate"
            elif [[ -f "$resolved_path_candidate/www/wp-config.php" ]]; then # Handle common /www subdirectory
                 VALIDATED_TARGET_SITES_ARRAY+=("$resolved_path_candidate/www")
                 echo "  Validated WP site (in www subdir): $resolved_path_candidate/www"
            else
                 # If wp-config.php is not found, still add it but warn the user.
                 # The backup functions will simply report no backups if it's not a valid structure.
                 VALIDATED_TARGET_SITES_ARRAY+=("$resolved_path_candidate")
                 echo "  Warning: Directory '$resolved_path_candidate' specified via --wp-site-dir does not contain a 'wp-config.php' or 'www/wp-config.php'. Processing anyway."
            fi
        elif [[ -d "$site_path_candidate" ]]; then # Fallback for paths realpath might not like but are valid dirs
             if [[ -f "$site_path_candidate/wp-config.php" ]]; then
                VALIDATED_TARGET_SITES_ARRAY+=("$site_path_candidate")
                echo "  Validated WP site: $site_path_candidate"
            elif [[ -f "$site_path_candidate/www/wp-config.php" ]]; then
                 VALIDATED_TARGET_SITES_ARRAY+=("$site_path_candidate/www")
                 echo "  Validated WP site (in www subdir): $site_path_candidate/www"
            else
                 VALIDATED_TARGET_SITES_ARRAY+=("$site_path_candidate")
                 echo "  Warning: Directory '$site_path_candidate' specified via --wp-site-dir does not contain a 'wp-config.php' or 'www/wp-config.php'. Processing anyway."
            fi
        else
            echo "  Error: Specified directory '$site_path_candidate' from --wp-site-dir does not exist or is not a directory. Skipping." >&2
        fi
    done
    TARGET_SITES_ARRAY=("${VALIDATED_TARGET_SITES_ARRAY[@]}")
else
    echo "Searching for WordPress installations in: $PARENT_DIR"
    declare -a ALL_WP_SITES
    readarray -t ALL_WP_SITES < <(find_wp_sites "$PARENT_DIR")

    if [[ ${#ALL_WP_SITES[@]} -eq 0 ]]; then
        echo "No WordPress installations found in '$PARENT_DIR'."
        exit 0
    fi
    TARGET_SITES_ARRAY=("${ALL_WP_SITES[@]}")
    echo "Operating on all ${#TARGET_SITES_ARRAY[@]} found WordPress site(s)."
fi

if [[ ${#TARGET_SITES_ARRAY[@]} -eq 0 ]]; then
    echo "No target WordPress sites to process. Exiting."
    exit 0
fi

echo "-----------------------------------"

for site_path in "${TARGET_SITES_ARRAY[@]}"; do
    echo
    echo "Processing site: $site_path"

    declare -a current_site_backups
    readarray -t current_site_backups < <(get_backup_files_newline_separated "$site_path")

    case "$ACTION" in
        list_backups) perform_list_backups "$site_path" current_site_backups ;;
        delete) perform_delete_interactive "$site_path" current_site_backups ;;
        delete_all) perform_delete_all "$site_path" current_site_backups ;;
        delete_except_latest) perform_delete_except_latest "$site_path" current_site_backups ;;
        delete_except_earliest) perform_delete_except_earliest "$site_path" current_site_backups ;;
        restore) perform_restore "$site_path" current_site_backups ;;
        restore_latest) perform_restore_latest "$site_path" current_site_backups ;;
        restore_earliest) perform_restore_earliest "$site_path" current_site_backups ;;
        *) echo "Error: Unknown action '$ACTION'" >&2 ;;
    esac
done

echo
echo "-----------------------------------"
echo "All processing complete."
exit 0