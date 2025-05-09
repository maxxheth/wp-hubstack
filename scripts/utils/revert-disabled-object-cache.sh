#!/bin/bash

# Initialize flags and arrays
dry_run=0
declare -a include_sites=()
process_all_sites=1 # 1 = process all, 0 = process only included sites
check_redis_status_flag=0
enable_redis_if_inactive_flag=0

# Associative array to store Redis status for each site
declare -A site_redis_statuses

# --- Display Help Function ---
display_help() {
  local script_name
  script_name=$(basename "$0")
  cat << EOF
Usage: $script_name [options]

Description:
  Manages WordPress sites by conditionally copying an object-cache.php file,
  checking Redis status in associated Docker containers, and optionally
  attempting to enable Redis if it's found to be inactive.

Options:
  --dry-run                 Perform a dry run. Show what actions would be taken
                            (file copies, enabling Redis) without actually
                            making any changes.

  --include <site_name>     Process only the specified site. <site_name> should
                            match a directory name (e.g., example.com).
                            This option can be used multiple times to include
                            multiple sites. If not used, all '*.com' directories
                            in the current path are processed.

  --check-redis-status      For each processed site, attempt to find a matching
                            Docker container (name containing 'wp_' and the site's
                            base name) and check its 'wp redis status'.
                            Results are summarized at the end.

  --enable-if-inactive    If --check-redis-status is active and a site's Redis
                            is found to be 'Status: Disconnected' (and the status
                            check command was successful), this flag triggers an
                            attempt to run 'wp redis enable' in the Docker container.
                            This action respects the --dry-run flag.

  -h, --help                Display this help message and exit.
EOF
}

# --- Initial Argument Check for Help ---
for arg in "$@"; do
  if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
    display_help
    exit 0
  fi
done

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=1
      shift
      ;;
    --include)
      process_all_sites=0
      if [[ -n "$2" && "$2" != --* ]]; then
        value_to_add="$2"
        value_to_add="${value_to_add#"${value_to_add%%[![:space:]]*}"}" # Trim leading
        value_to_add="${value_to_add%"${value_to_add##*[![:space:]]}"}" # Trim trailing
        if [[ -n "$value_to_add" ]]; then
          include_sites+=("$value_to_add")
        else
          echo "Warning: --include flag was followed by an empty or whitespace-only value. Ignoring." >&2
        fi
        shift 2
      else
        echo "Error: --include requires a site name argument. Use --help for more info." >&2
        exit 1
      fi
      ;;
    --check-redis-status)
      check_redis_status_flag=1
      shift
      ;;
    --enable-if-inactive)
      enable_redis_if_inactive_flag=1
      shift
      ;;
    *)
      echo "Unknown option: $1. Use --help for available options." >&2
      # Optionally exit on unknown options: exit 1
      shift # Remove the unknown option to prevent issues if it was a mistake
      ;;
  esac
done

if [[ $dry_run -eq 1 ]]; then
  echo "--- DRY RUN MODE ENABLED --- (No changes will be made for file operations or enabling Redis)"
  echo
fi

if [[ $process_all_sites -eq 0 ]]; then
  if [[ ${#include_sites[@]} -eq 0 ]]; then
    echo "Info: --include was used, but the include list is empty. No sites will be processed."
    exit 0
  else
    echo "Info: Processing only the following included sites: ${include_sites[*]}"
  fi
  echo
fi

# --- Pre-flight checks / Initializations for Redis Status ---
declare -a wp_container_list=()
if [[ $check_redis_status_flag -eq 1 ]]; then
  echo "Info: Fetching list of 'wp_' Docker containers for Redis status checks..."
  _wp_containers_str=$(docker ps --format "{{.Names}}" | grep 'wp_' || true)
  if [[ -n "$_wp_containers_str" ]]; then
    while IFS= read -r line; do wp_container_list+=("$line"); done <<< "$_wp_containers_str"
  fi

  if [[ ${#wp_container_list[@]} -eq 0 ]]; then
    echo "Warning: No running Docker containers found matching the 'wp_' pattern for Redis checks."
  else
    echo "Info: Found potential WP containers for Redis checks: ${wp_container_list[*]}"
  fi
  echo
fi

# --- Main Processing Logic ---
find . -maxdepth 1 -type d -name "*.com" -print0 | while IFS= read -r -d $'\0' site_dir; do
  site_name="${site_dir#./}"

  if [[ $process_all_sites -eq 0 ]]; then
    is_included=0
    for included_site in "${include_sites[@]}"; do
      if [[ "$site_name" == "$included_site" ]]; then
        is_included=1
        break; fi
    done
    if [[ $is_included -eq 0 ]]; then continue; fi
  fi

  echo "Processing site: $site_name"
  if [[ $check_redis_status_flag -eq 1 ]]; then
    site_redis_statuses["$site_name"]="NOT_CHECKED"
  fi

  # --- Object Cache File Copy Logic ---
  source_file="$site_name/www/wp-content/_object-cache.php"
  target_file="$site_name/www/wp-content/object-cache.php"
  target_wp_content_dir="$site_name/www/wp-content"

  if [[ ! -d "$target_wp_content_dir" ]]; then
    echo "  SKIP (object-cache): Directory $target_wp_content_dir not found."
  elif [[ ! -f "$source_file" ]]; then
    echo "  SKIP (object-cache): Source file $source_file not found."
  elif [[ ! -e "$target_file" ]]; then
    if [[ $dry_run -eq 1 ]]; then
      echo "  DRY RUN (object-cache): Would copy $source_file to $target_file."
    else
      echo "  ACTION (object-cache): Copying $source_file to $target_file..."
      cp "$source_file" "$target_file"
      if [[ $? -eq 0 ]]; then echo "    SUCCESS (object-cache): Copied."; else echo "    ERROR (object-cache): Failed to copy."; fi
    fi
  else
    echo "  SKIP (object-cache): Target file $target_file already exists."
  fi

  # --- Redis Status Check Logic ---
  if [[ $check_redis_status_flag -eq 1 ]]; then
    echo "  Attempting Redis status check for $site_name..."
    base_name="${site_name%.com}"
    matched_container=""
    site_redis_statuses["$site_name"]="NO_CONTAINER" 

    if [[ ${#wp_container_list[@]} -gt 0 ]]; then
      for container_name_from_list in "${wp_container_list[@]}"; do
        if echo "$container_name_from_list" | grep -q "$base_name"; then
          matched_container="$container_name_from_list"
          echo "    Found candidate container: $matched_container for site base: $base_name"
          break
        fi
      done
    fi

    if [[ -n "$matched_container" ]]; then
      site_redis_statuses["$site_name"]="EXEC_FAILED" 
      wp_redis_output=$(docker exec "$matched_container" wp --allow-root --path=/var/www/html redis status 2>&1)
      docker_exec_status=$?
      initial_redis_state=1 # Default to 1 (not connected / disconnected)

      if [[ $docker_exec_status -eq 0 ]]; then
        if echo "$wp_redis_output" | grep -qi "status: connected"; then
          initial_redis_state=0
          echo "    INFO: Redis reported as 'Status: Connected'."
        else
          initial_redis_state=1
          echo "    INFO: Redis reported as 'Status: Disconnected' or other."
          echo "    Full 'wp redis status' output for $matched_container:"
          echo "$wp_redis_output" | sed 's/^/      /'
        fi
        site_redis_statuses["$site_name"]="$initial_redis_state"

        if [[ $enable_redis_if_inactive_flag -eq 1 && $initial_redis_state -eq 1 ]]; then
          echo "    ACTION_TRIGGER: Redis inactive and --enable-if-inactive is set."
          if [[ $dry_run -eq 1 ]]; then
            echo "      DRY RUN: Would attempt to enable Redis (wp redis enable) for $site_name in container $matched_container."
          else
            echo "      ACTION: Enabling Redis for $site_name (Container: $matched_container)..."
            enable_output=$(docker exec "$matched_container" wp --allow-root --path=/var/www/html redis enable 2>&1)
            enable_status=$?
            if [[ $enable_status -eq 0 ]]; then
              echo "        SUCCESS: 'wp redis enable' command seems to have succeeded."
              echo "$enable_output" | sed 's/^/          /'
              echo "        Re-checking Redis status post-enable attempt..."
              new_status_output=$(docker exec "$matched_container" wp --allow-root --path=/var/www/html redis status 2>&1)
              new_docker_exec_status=$?
              if [[ $new_docker_exec_status -eq 0 ]] && echo "$new_status_output" | grep -qi "status: connected"; then
                echo "          INFO: Redis is NOW reported as 'Status: Connected'."
              else
                echo "          WARNING: Redis still NOT 'Status: Connected' after 'enable' attempt (or re-check failed)."
                if [[ $new_docker_exec_status -ne 0 ]]; then echo "            (Re-check command failed with status: $new_docker_exec_status)"; fi
                echo "$new_status_output" | sed 's/^/            /'
              fi
            else
              echo "        ERROR: 'wp redis enable' command failed with exit status $enable_status."
              echo "$enable_output" | sed 's/^/          /'
            fi
          fi
        fi
      else 
        echo "    ERROR: Command 'docker exec ... wp redis status' failed for container $matched_container."
        echo "    Output: $wp_redis_output"
      fi
    else 
      echo "    INFO: No matching 'wp_' Docker container found for site base '$base_name'."
    fi
  fi
  echo 
done

# --- Summary Reports ---
if [[ $check_redis_status_flag -eq 1 && ${#site_redis_statuses[@]} -gt 0 ]]; then
  echo 
  echo "--- Redis Status Summary (Initial States) ---"
  printf "%-35s | %s\n" "Site" "Redis Status (Code)"
  echo "---------------------------------------|-------------------------------------------------"
  for site_key in "${!site_redis_statuses[@]}"; do
    status_val="${site_redis_statuses[$site_key]}"
    case "$status_val" in
      "0") outcome="Status: Connected" ;;
      "1") outcome="Status: Disconnected" ;;
      "EXEC_FAILED") outcome="Check Failed (exec error)" ;;
      "NO_CONTAINER") outcome="No Matching Container" ;;
      "NOT_CHECKED") outcome="Not Checked (e.g. filtered out)" ;;
      *) outcome="Unknown" ;;
    esac
    printf "%-35s | %-30s (%s)\n" "$site_key" "$outcome" "$status_val"
  done
  echo "------------------------------------------------------------------------------------------"
  echo "(Recorded codes: 0 -> Status: Connected, 1 -> Status: Disconnected)"
fi

echo
echo "Script finished."