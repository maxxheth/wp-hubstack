#!/bin/bash

# Define the remote file path
REMOTE_FILE_PATH="/var/opt/wp-plugin-update-reports/wp_plugins_report.pdf"

# Loop through servers from wp0 to wp41
for i in {0..41}; do
    SERVER_NAME="wp${i}.ciwgserver.com"
    echo "Checking for report on ${SERVER_NAME}..."

    # Use ssh to check if the file exists on the remote server
    # The `test -f` command checks if a file exists and is a regular file.
    # `ssh -q` runs ssh in quiet mode.
    # The exit status of ssh will be the exit status of the remote command.
    if ssh -q "root@${SERVER_NAME}" "test -f ${REMOTE_FILE_PATH}"; then
        echo "Report found on ${SERVER_NAME} at ${REMOTE_FILE_PATH}"
    else
        echo "Report NOT found on ${SERVER_NAME} at ${REMOTE_FILE_PATH}"
    fi
    echo # Add a blank line for better readability
done

echo "Finished checking all servers."
