#!/bin/bash

# --- Configuration ---
# Define the cron job you want to add.
# Example: Run a script every day at 2:30 AM
# CRON_MINUTE="30"
# CRON_HOUR="2"
# CRON_DAY_OF_MONTH="*"
# CRON_MONTH="*"
# CRON_DAY_OF_WEEK="*"
# COMMAND_TO_RUN="/path/to/your/script.sh"

# --- Script Variables ---
# You can modify these directly or prompt the user for input.
CRON_SCHEDULE="* * * * *" # Default: every minute
COMMAND_TO_RUN="/usr/bin/echo 'Hello from cron' >> /tmp/cron_output.log"
TEMP_CRONTAB_FILE="/tmp/my_crontab.$$" # Temporary file to store crontab contents

# --- Functions ---

# Function to display usage instructions
usage() {
  echo "Usage: $0 [-s \"<cron_schedule>\"] [-c \"<command_to_run>\"]"
  echo "  -s <cron_schedule> : The cron schedule string (e.g., \"0 5 * * 1\" for 5 AM every Monday)."
  echo "                       Default: \"$CRON_SCHEDULE\" (every minute)"
  echo "  -c <command_to_run>: The command to be executed by cron."
  echo "                       Default: \"$COMMAND_TO_RUN\""
  echo "  -h                   : Display this help message."
  exit 1
}

# Function to cleanup temporary files
cleanup() {
  if [ -f "$TEMP_CRONTAB_FILE" ]; then
    rm "$TEMP_CRONTAB_FILE"
  fi
}

# --- Argument Parsing ---
while getopts ":s:c:h" opt; do
  case ${opt} in
    s )
      CRON_SCHEDULE="$OPTARG"
      ;;
    c )
      COMMAND_TO_RUN="$OPTARG"
      ;;
    h )
      usage
      ;;
    \? )
      echo "Invalid option: -$OPTARG" 1>&2
      usage
      ;;
    : )
      echo "Invalid option: -$OPTARG requires an argument" 1>&2
      usage
      ;;
  esac
done
shift $((OPTIND -1))

# --- Main Script Logic ---

# Ensure cleanup runs on script exit or interruption
trap cleanup EXIT SIGINT SIGTERM

# Construct the cron job line
CRON_JOB_LINE="$CRON_SCHEDULE $COMMAND_TO_RUN"

echo "Attempting to add the following cron job:"
echo "$CRON_JOB_LINE"
echo ""

# Get current crontab content, or an empty string if none exists
CURRENT_CRONTAB=$(crontab -l 2>/dev/null || true)

# Check if the job already exists
if echo "$CURRENT_CRONTAB" | grep -Fxq "$CRON_JOB_LINE"; then
  echo "Cron job already exists. No changes made."
  exit 0
fi

# Append the new cron job
# The printf is used to ensure a newline is added if the current crontab is not empty
# and to handle the case where the crontab is empty.
if [ -z "$CURRENT_CRONTAB" ]; then
  echo "$CRON_JOB_LINE" > "$TEMP_CRONTAB_FILE"
else
  (echo "$CURRENT_CRONTAB"; echo "$CRON_JOB_LINE") > "$TEMP_CRONTAB_FILE"
fi

# Install the new crontab
crontab "$TEMP_CRONTAB_FILE"

# Verify if the crontab command was successful
if [ $? -eq 0 ]; then
  echo "Cron job added successfully."
  echo ""
  echo "Current crontab:"
  crontab -l
else
  echo "Error: Failed to add cron job."
  # Attempt to restore the original crontab if possible and if it wasn't empty
  if [ -n "$CURRENT_CRONTAB" ]; then
    echo "$CURRENT_CRONTAB" | crontab -
    echo "Original crontab restored (if it existed)."
  else
    # If original crontab was empty, try to remove the potentially problematic one
    crontab -r 2>/dev/null || true # Suppress error if no crontab to remove
    echo "Attempted to clear any problematic crontab entries."
  fi
  exit 1
fi

# The cleanup function will be called automatically on exit

exit 0
