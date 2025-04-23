#!/bin/bash

# cron-log-rotate.sh
# This script runs the log rotation command on all WP servers.
# It uses SSH to connect to each server and execute the command.
# The script assumes that the SSH keys are set up for passwordless login.
# It also uses the .env file to get the list of servers and other configurations.
#
# This is probabally the best example of how to use the .env file.

source "$(dirname "$0")/../.env"

for ((i=1; i<=TOTAL_SERVERS; i++)); do
    REMOTE_SERVER="wp$i.$HOST_TLD"

    echo $REMOTE_SERVER
    echo "==> Removing Log on $REMOTE_SERVER..."
    echo "==> Executing: $CMD_LOG_ROTATE"

    ssh $SSH_OPTS root@"$REMOTE_SERVER" "$CMD_LOG_ROTATE"
done