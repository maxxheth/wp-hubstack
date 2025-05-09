#!/bin/bash

# Regex to identify directory names that end with common TLDs.
# This is a simpler approach if the strict hostname regex is too limiting.
# Add or remove TLDs as needed.
COMMON_TLDS_REGEX="\.((com|org|net|io|co|uk|de|ca|au|info|biz|me|app|dev)|[a-z]{2})$"
# This regex looks for a dot followed by common TLDs OR any two letters (common for ccTLDs)

echo "Searching for subdirectories in the current location whose names look like URLs (ending in common TLDs)..."
echo "--------------------------------------------------------------------------"

# Find immediate subdirectories (depth 1) in the current directory (.)
# -print0 and read -d $'\0' handle names with spaces or special characters.
find . -maxdepth 1 -mindepth 1 -type d -print0 | while IFS= read -r -d $'\0' dir_path; do
    # Get the base name of the directory
    dir_name=$(basename "$dir_path")

    # Check if the directory name matches the common TLDs regex
    if [[ "$dir_name" =~ $COMMON_TLDS_REGEX ]]; then
        echo "Found potential URL-like directory: '$dir_name'"

        url_to_check_http="http://$dir_name"
        url_to_check_https="https://$dir_name"
        final_url_queried=""
        status_code=""

        # Try HTTP first
        echo "  Querying $url_to_check_http ..."
        # curl options:
        # -o /dev/null: Discard the body
        # -s: Silent mode (no progress meter)
        # -w "%{http_code}": Output only the HTTP status code
        # --connect-timeout 5: Max time in seconds for connection
        # -L: Follow redirects (optional, but often useful)
        current_status=$(curl -L -o /dev/null -s -w "%{http_code}" --connect-timeout 5 "$url_to_check_http")
        final_url_queried="$url_to_check_http"
        status_code="$current_status"

        # If HTTP fails (status 000) or returns a non-success/non-redirect, try HTTPS
        # Common non-success but valid codes: 4xx, 5xx. Redirects: 3xx.
        # 000 usually means curl couldn't connect.
        if [[ "$status_code" == "000" ]] || { [[ "$status_code" -ge 400 ]] && [[ "$status_code" -ne 401 && "$status_code" -ne 403 ]]; }; then # Basic check for connection failure or server error
            echo "  HTTP attempt returned status $status_code. Trying $url_to_check_https ..."
            current_status=$(curl -L -o /dev/null -s -w "%{http_code}" --connect-timeout 5 "$url_to_check_https")
            final_url_queried="$url_to_check_https" # Update to HTTPS URL
            status_code="$current_status"
        fi

        echo "  Status code for $final_url_queried: $status_code"
        echo "---"
    # else
        # Optional: print directories that didn't match the regex
        # echo "Directory '$dir_name' does not look like a URL. Skipping."
    fi
done

echo "--------------------------------------------------------------------------"
echo "Script finished."