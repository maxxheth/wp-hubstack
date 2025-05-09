#!/bin/bash

# Script to find directories named like website URLs and reset their Dockerfile

# Default values
DEFAULT_SED_PATTERN='/ENTRYPOINT \["\/usr\/local\/bin\/container-init.sh"\]/q'
SED_PATTERN="$DEFAULT_SED_PATTERN"
SKIP_BACKUP=false
TARGET_DIR=""
DRY_RUN=false

# Function to display usage
usage() {
  echo "Usage: $0 [options] <target_directory>"
  echo "Options:"
  echo "  --skip-backup          Skip creating a backup of the Dockerfile."
  echo "  --load-pattern <pattern> Load a custom sed pattern. Default: \"$DEFAULT_SED_PATTERN\""
  echo "  --dry-run              Simulate script execution without making changes."
  echo "  -h, --help             Display this help message."
  exit 1
}

# Parse command-line arguments
TEMP_ARGS=()
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --skip-backup)
      SKIP_BACKUP=true
      shift # past argument
      ;;
    --load-pattern)
      if [[ -z "$2" || "$2" == -* ]]; then
        echo "Error: --load-pattern requires an argument."
        usage
      fi
      SED_PATTERN="$2"
      shift # past argument
      shift # past value
      ;;
    -h|--help)
      usage
      ;;
    --dry-run)
      DRY_RUN=true
      shift # past argument
      ;;
    -*)
      echo "Unknown option: $1"
      usage
      ;;
    *)
      TEMP_ARGS+=("$1") # save it in an array for later
      shift # past argument
      ;;
  esac
done

# Restore positional arguments (expecting only one: target_directory)
if [ ${#TEMP_ARGS[@]} -ne 1 ]; then
  echo "Error: Please specify exactly one target directory."
  usage
fi
TARGET_DIR="${TEMP_ARGS[0]}"


# Check if the target directory exists
if [ ! -d "$TARGET_DIR" ]; then
  echo "Error: Directory '$TARGET_DIR' not found."
  exit 1
fi

echo "Searching in directory: $TARGET_DIR"
echo "Using sed pattern: $SED_PATTERN"
if [ "$SKIP_BACKUP" = true ]; then
  echo "Skipping Dockerfile backups."
else
  echo "Backing up Dockerfiles to Dockerfile.bak."
fi
if [ "$DRY_RUN" = true ]; then
  echo "Dry run mode enabled. No changes will be made."
fi

# Find directories, filter by name (ending in a TLD), and iterate
find "$TARGET_DIR" -maxdepth 1 -type d -print0 | while IFS= read -r -d $'\0' dir_path; do
  dir_name=$(basename "$dir_path")

  # Simple grep for TLDs - extend as needed
  if echo "$dir_name" | grep -qE '\.(com|org|net|io|dev|app|biz|info|us|uk|ca|au|de|fr|xyz)$'; then
    echo "Processing directory: $dir_name"
    dockerfile_path="$dir_path/Dockerfile"
    if [ -f "$dockerfile_path" ]; then
      echo "  Found Dockerfile."

      # Backup Dockerfile unless --skip-backup is used
      if [ "$SKIP_BACKUP" = false ]; then
        backup_path="$dockerfile_path.bak"
        echo "    Creating backup: $backup_path"
        if [ "$DRY_RUN" = true ]; then
          echo "    [DRY RUN] Would create backup: $backup_path"
        elif cp "$dockerfile_path" "$backup_path"; then
          echo "    Backup created successfully."
        else
          echo "    Error: Failed to create backup for $dockerfile_path. Skipping reset for this file."
          continue # Skip to the next directory
        fi
      fi

      echo "    Resetting Dockerfile..."
      # Create a temporary file for sed output, then move it
      if [ "$DRY_RUN" = true ]; then
        echo "    [DRY RUN] Would reset Dockerfile in $dir_name using pattern: $SED_PATTERN"
        echo "    [DRY RUN] Command: sed \"$SED_PATTERN\" \"$dockerfile_path\" > \"$dockerfile_path.tmp\" && mv \"$dockerfile_path.tmp\" \"$dockerfile_path\""
        echo "    Dockerfile in $dir_name would be reset successfully."
      elif sed "$SED_PATTERN" "$dockerfile_path" > "$dockerfile_path.tmp"; then
        mv "$dockerfile_path.tmp" "$dockerfile_path"
        echo "    Dockerfile in $dir_name reset successfully."
      else
        echo "    Error: sed command failed for Dockerfile in $dir_name."
        # Clean up temp file if it exists
        [ -f "$dockerfile_path.tmp" ] && rm "$dockerfile_path.tmp"
      fi
    else
      echo "  No Dockerfile found in $dir_name. Skipping."
    fi
  fi
done

echo "Script finished."