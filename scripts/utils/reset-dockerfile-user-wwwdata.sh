#!/bin/bash

chmod +x /var/opt/reset-dockerfile.sh

echo "Processing directory in order to reset Dockerfile: $dir"
# Check if the Dockerfile.bak file exists in the directory

/var/opt/reset-dockerfile.sh . --load-pattern '/USER www\-data/q'


if [ $? -ne 0 ]; then
	echo "Error: Failed to execute reset-dockerfile.sh with the specified pattern."
	exit 1
fi

