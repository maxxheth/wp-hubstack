#!/bin/bash
# bulk-cancel-remaining.sh
#
# For cancellations that failed in bulk-cancel.sh (due to DNS changes),
# this script loops through WP servers (wp1.ciwgserver.com to wp41.ciwgserver.com)
# to find the server where the folder /var/opt/<domain> exists.
# When found, it runs cancel.sh with the domain and email, and then transfers the created
# ZIP file to the backup server located in the .env file.

source "$(dirname "$0")/../.env"

# Copy the list of failed cancellations from bulk-cancel.sh below:
failed_cancellations=(
    "domain1.com customer1@gmail.com"
    "domain2.com customer2@gmail.com"
)

# Loop over each failed cancellation pair.
for entry in "${failed_cancellations[@]}"; do
domain=$(echo "$entry" | awk '{print $1}')
email=$(echo "$entry" | awk '{print $2}')

echo "Processing remaining cancellation for $domain ($email)..."

found_server=""

# Loop through WP servers wp1 to wp41.
for i in $(seq 1 $SERVER_TOTAL); do

server="wp${i}.$HOST"

echo "  Checking $server for $DOMAIN_PATH/${domain}..."

        # Test if the folder exists on the remote server.
        ssh $SSH_OPTS root@"$server" "test -d /var/opt/${domain}" &>/dev/null
        if [ $? -eq 0 ]; then
            found_server="$server"
            echo "  >> Found $domain on $server"

            # Run the cancellation command.
            ssh $SSH_OPTS root@"$server" $SCRIPT_PATH/cancel.sh "$domain" "$email"
            if [ $? -eq 0 ]; then
                echo "  >> cancel.sh executed successfully on $server."

                # Transfer the generated ZIP file.
                echo "  >> Transferring ${domain}.zip to ciwebgroup.com..."
                ssh $SSH_OPTS root@"$server" "scp $DOMAIN_PATH/${domain}/www/wp-content/${domain}.zip root@$BACKUP_DOMAIN:$DOMAIN_PATH/"
                if [ $? -eq 0 ]; then
                    echo "  >> File transfer completed."
                else
                    echo "  >> File transfer FAILED on $server."
                fi
            else
                echo "  >> cancel.sh execution FAILED on $server."
            fi
            break  # Stop searching once the correct server is found.
        else
            echo "Not found, trying next server."
        fi
    done

    if [ -z "$found_server" ]; then
        echo "  >> ERROR: Could not locate server with /var/opt/${domain} for $domain. Please check manually."
    fi
    echo ""
done
