#!/bin/bash

# Script to find WordPress installations, manage object-cache.php, and check site status.

# --- Default Argument Values ---
WP_DIRS_ARG=""
DRY_RUN_FLAG=false
DISABLE_CURL_CHECK_FLAG=false # Added: default to false (curl check ON)

# --- Argument Parsing ---
# Keep track of original arguments for potential error messages
ORIGINAL_ARGS=("$@")
POSITIONAL_ARGS=()
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --wp-dir)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "ERROR: Missing value for --wp-dir flag." >&2
                echo "Usage: $0 [--wp-dir <dir1,dir2,...>] [--disable-curl-check] [--dry-run]" >&2
                exit 1
            fi
            WP_DIRS_ARG="$2"
            shift 2 # Consume flag and value
            ;;
        --disable-curl-check) # Added
            DISABLE_CURL_CHECK_FLAG=true
            shift # Consume flag
            ;;
        --dry-run)
            DRY_RUN_FLAG=true
            shift # Consume flag
            ;;
        -*) # Unknown option
            echo "ERROR: Unknown option: $1" >&2
            echo "Usage: $0 [--wp-dir <dir1,dir2,...>] [--disable-curl-check] [--dry-run]" >&2
            exit 1
            ;;
        *) # Positional argument
            POSITIONAL_ARGS+=("$1")
            shift # Consume positional argument
            ;;
    esac
done

# Restore positional arguments if any were captured (though this script doesn't use them)
# set -- "${POSITIONAL_ARGS[@]}"

if [ ${#POSITIONAL_ARGS[@]} -gt 0 ]; then
    echo "ERROR: Unexpected positional arguments: ${POSITIONAL_ARGS[*]}" >&2
    echo "Usage: $0 [--wp-dir <dir1,dir2,...>] [--disable-curl-check] [--dry-run]" >&2
    exit 1
fi


# --- Initial Script Messages ---
echo "Starting script in $(pwd)"
if [ "$DRY_RUN_FLAG" = true ]; then
    echo "*** DRY RUN MODE ENABLED: No actual file changes will be made. ***"
fi
if [ "$DISABLE_CURL_CHECK_FLAG" = false ]; then # Modified
    echo "*** Enhanced CURL Check ENABLED (default). Use --disable-curl-check to bypass. ***"
fi
echo ""


# --- Determine Directories to Process ---
DIRS_TO_PROCESS=()
if [ -n "$WP_DIRS_ARG" ]; then
    echo "Processing specified WP directories from --wp-dir: $WP_DIRS_ARG"
    IFS=',' read -r -a RAW_DIRS <<< "$WP_DIRS_ARG"
    for dir_item in "${RAW_DIRS[@]}"; do
        processed_dir_item=$(echo "$dir_item" | xargs) # Trim leading/trailing whitespace
        processed_dir_item="${processed_dir_item%/}"    # Remove trailing slash if any

        if [ -d "$processed_dir_item" ]; then
            DIRS_TO_PROCESS+=("$processed_dir_item")
        else
            echo "WARNING: Specified directory '$processed_dir_item' (from input '$dir_item') not found or not a directory. Skipping." >&2
        fi
    done
else
    echo "No --wp-dir specified. Looking for WordPress installations in all direct subdirectories of $(pwd)..."
    for dir_path_glob in */; do
        if [ -d "$dir_path_glob" ]; then
            DIRS_TO_PROCESS+=("${dir_path_glob%/}") # Add cleaned path
        fi
    done
fi

if [ ${#DIRS_TO_PROCESS[@]} -eq 0 ]; then
    if [ -n "$WP_DIRS_ARG" ]; then
        echo "No valid directories found from the --wp-dir list. Exiting."
    else
        echo "No subdirectories found to process in $(pwd). Exiting."
    fi
    exit 0
fi

echo ""
echo "Will attempt to process the following directories:"
for d in "${DIRS_TO_PROCESS[@]}"; do echo "  - $d"; done
echo ""

# --- Main Processing Loop ---
for dir_cleaned in "${DIRS_TO_PROCESS[@]}"; do
    echo "Processing directory: $dir_cleaned"

    wp_config_at_root="$dir_cleaned/wp-config.php"
    wp_config_in_www="$dir_cleaned/www/wp-config.php"
    is_wp_install=false
    wp_content_dir_path="" # Path to the wp-content directory relative to $dir_cleaned

    # 1. Check for wp-config.php and determine wp-content path
    if [ -f "$wp_config_in_www" ]; then
        echo "  Found WordPress config at: $wp_config_in_www"
        is_wp_install=true
        # If config is in 'www', wp-content is likely in 'www/wp-content'
        wp_content_dir_path="$dir_cleaned/www/wp-content"
    elif [ -f "$wp_config_at_root" ]; then
        echo "  Found WordPress config at: $wp_config_at_root"
        is_wp_install=true
    else
        echo "  No wp-config.php found in '$dir_cleaned/wp-config.php' or '$dir_cleaned/www/wp-config.php'. Skipping."
        echo "----------------------------------------"
        continue
    fi

    if [ "$is_wp_install" = true ]; then
        sub_dir_basename=$(basename "$dir_cleaned") # Moved here as it's used by curl check

        # --- Curl Check Logic (default, can be disabled) ---
        if [ "$DISABLE_CURL_CHECK_FLAG" = false ]; then
            if [ -n "$sub_dir_basename" ] && [ "$sub_dir_basename" != "." ] && [ "$sub_dir_basename" != ".." ]; then
                target_url="http://$sub_dir_basename" # Assuming HTTP. Modify to HTTPS if needed.
                echo "  Performing enhanced curl check for: $target_url"
                # Get HTTP status code
                http_status=$(curl -s -L -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$target_url")
                curl_status_exit_code=$?

                if [ "$curl_status_exit_code" -ne 0 ]; then
                    echo "  ERROR: curl command failed to get HTTP status for $target_url (curl exit code: $curl_status_exit_code). Status code received: $http_status."
                elif [ "$http_status" -eq 200 ]; then
                    echo "  SUCCESS: $target_url returned HTTP status 200. Skipping object-cache rename for this site."
                    echo "----------------------------------------"
                    continue # Skip to the next WP directory
                elif [ "$http_status" -ge 400 ]; then
                    echo "  ERROR: $target_url returned HTTP status $http_status."
                else # Covers 3xx, 000 (if curl_exit_code was 0 but status is 000), etc.
                    echo "  INFO: $target_url returned HTTP status $http_status (Not 200 and not >=400)."
                fi

                # If status was not 200 and curl command for status didn't fail catastrophically, try to get content for grep
                if [ "$http_status" -ne 200 ]; then
                    echo "  Fetching page content from $target_url to check for Redis error..."
                    page_content=$(curl -s -L --connect-timeout 5 --max-time 10 "$target_url")
                    content_curl_exit_code=$?

                    if [ "$content_curl_exit_code" -ne 0 ]; then
                        echo "  ERROR: curl command failed to fetch content from $target_url (curl exit code: $content_curl_exit_code)."
                    elif [ -z "$page_content" ] && [[ "$http_status" != "000" && "$curl_status_exit_code" -eq 0 ]]; then
                        echo "  WARNING: Fetched empty content from $target_url (Status: $http_status), but curl command was successful."
                        echo "  NOT FOUND: The phrase 'Error establishing a Redis connection' was not found (empty page content)."
                    elif [ -n "$page_content" ]; then
                        if echo "$page_content" | grep -q "Error establishing a Redis connection"; then
                            echo "  FOUND: The phrase 'Error establishing a Redis connection' was found on $target_url."
                        else
                            echo "  NOT FOUND: The phrase 'Error establishing a Redis connection' was not found on $target_url."
                        fi
                    else
                        echo "  INFO: No content fetched from $target_url (Status: $http_status, Content Curl Exit: $content_curl_exit_code). Cannot check for Redis error phrase."
                    fi
                fi
            else
                echo "  WARNING: Could not derive a valid hostname from directory '$dir_cleaned' for HTTP check. Skipping curl check for this directory."
            fi
        else
            echo "  INFO: Curl check disabled via --disable-curl-check."
        fi # End of DISABLE_CURL_CHECK_FLAG block

        # --- Object Cache Renaming Logic ---
        object_cache_base_dir="$dir_cleaned/www/wp-content"
        object_cache_path="$object_cache_base_dir/object-cache.php"
        renamed_object_cache_path="$object_cache_base_dir/_object-cache.php"

        if [ -d "$dir_cleaned/www" ]; then
            if [ -d "$object_cache_base_dir" ];then
                if [ -f "$object_cache_path" ]; then
                    echo "  Found object-cache.php at: $object_cache_path"
                    if [ "$DRY_RUN_FLAG" = true ]; then
                        echo "  [DRY RUN] Would rename $object_cache_path to $renamed_object_cache_path"
                    else
                        if mv "$object_cache_path" "$renamed_object_cache_path"; then
                            echo "  SUCCESS: Renamed to $renamed_object_cache_path"
                        else
                            echo "  ERROR: Failed to rename $object_cache_path"
                        fi
                    fi
                else
                    echo "  INFO: object-cache.php not found in $object_cache_base_dir/"
                fi
            else
                echo "  INFO: Directory $object_cache_base_dir/ not found. Cannot check for object-cache.php."
            fi
        else
            echo "  INFO: Subdirectory '$dir_cleaned/www' does not exist. Cannot check for object-cache.php in its wp-content."
        fi
    fi
    echo "----------------------------------------"
done

echo ""
echo "Script finished."