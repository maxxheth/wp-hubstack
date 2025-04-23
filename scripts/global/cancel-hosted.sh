#!/bin/bash
# bulk-cancel.sh
# This script runs the cancel.sh command on the remote server determined by the domain.
# For any cancellation where SSH fails (e.g. due to moved DNS), the pair is recorded
# in the failed_cancellations list for later processing.

# Define an array of cancellations.
# Each entry is "domain email" (space-separated).

source "$(dirname "$0")/../.env"

cancellations=(
    "domain1.com customer1@gmail.com"
    "domain2.com customer2@gmail.com"
)

failed_cancellations=()

for entry in "${cancellations[@]}"; do
    domain=$(echo "$entry" | awk '{print $1}')
    email=$(echo "$entry" | awk '{print $2}')
    
    echo "Attempting cancellation for $domain ($email) on $domain..."
    ssh $SSH_OPTS root@"$domain" $SCRIPT_PATH/cancel.sh "$domain" "$email"

    if [ $? -ne 0 ]; then
        echo ">> Cancellation FAILED for $domain"
        failed_cancellations+=("$domain $email")
    else
        echo ">> Cancellation succeeded for $domain"
    fi
done

echo ""
if [ ${#failed_cancellations[@]} -gt 0 ]; then
    echo "The following cancellations failed (likely due to moved DNS):"
    for entry in "${failed_cancellations[@]}"; do
        echo "$entry"
    done
    echo ""
    echo "Copy the above list to use in bulk-cancel-remaining.sh"
else
    echo "All cancellations completed successfully."
fi
