#!/bin/bash

# Batch runner to collect `wp plugin list` from each container.

TARGET_DIR="."
CONTAINER_LIST_FILE=""
FORMAT="json"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --target-dir)           TARGET_DIR="$2"; shift 2 ;;
    --container-list-file)  CONTAINER_LIST_FILE="$2"; shift 2 ;;
    --format)               FORMAT="$2"; shift 2 ;;
    *) echo "ERROR: Unknown option $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$CONTAINER_LIST_FILE" || ! -f "$CONTAINER_LIST_FILE" ]]; then
  echo "ERROR: --container-list-file <file> is required." >&2
  exit 1
fi

# --- Prepare report directory ---
REPORT_BASE="$TARGET_DIR/wp-plugin-update-reports"
mkdir -p "$REPORT_BASE" || exit 1

# --- Load containers (assumes same awk filter as your other runner) ---
mapfile -t CONTAINERS < <(awk 'NR>1 && $NF~/^wp_/ {print $NF}' "$CONTAINER_LIST_FILE")

if [ ${#CONTAINERS[@]} -eq 0 ]; then
  echo "No WordPress containers found." >&2
  exit 0
fi

# --- Collect plugin lists ---
for c in "${CONTAINERS[@]}"; do
  echo "Collecting from $c..."
  DIR="$REPORT_BASE/$c"
  mkdir -p "$DIR"
  docker exec "$c" wp --allow-root plugin list --format="$FORMAT" > "$DIR/plugin-list.$FORMAT" \
    && echo "  → $DIR/plugin-list.$FORMAT" \
    || echo "  WARNING: failed for $c" >&2
done

echo "Done. Reports under $REPORT_BASE"
exit 0