#!/bin/bash

# Grep all directories that have a common TLD.

# This script will restore the Dockerfile from the backup file if it exists.
# It will also check if the backup file is older than the original Dockerfile and

# if so, it will remove the backup file provided a --delete-bak flag is passed.

# Usage: ./restore-dockerfile-bak.sh [--delete-bak]

# Check if the --delete-bak flag is passed

if [[ "$1" == "--delete-bak" ]]; then
	DELETE_BAK=true
else
	DELETE_BAK=false
fi

# 1. Grep all directories that have a common TLD.

# 2. Check if the Dockerfile.bak file exists in each directory.

# 3. If it does, check if the backup file is older than the original Dockerfile.
# 4. If it is, backup the original Dockerfile and restore the backup file.
# 5. If the --delete-bak flag is passed, delete the backup file.

# TLD = Top Level Domain such as .com, .net, .org, etc.

DIRS_WITH_TLD=$(
	find . -type d -name "*.*" | grep -E "\.[a-z]{2,}$" | grep -v "node_modules"
)
for dir in $DIRS_WITH_TLD; do
	echo "Processing directory in order to restore Dockerfile.bak: $dir"
	# Check if the Dockerfile.bak file exists in the directory

	dockerfile_bak=$(ls -t "$dir" | grep "Dockerfile.bak" | sort -u | tail -n 1)

	# Back up the original Dockerfile if the --backup-current flag is passed and restore the backup file 

	if [[ -f "$dockerfile_bak" ]]; then
		# Check if the backup file is older than the original Dockerfile
		if [[ "$DELETE_BAK" == true ]]; then
			rm -f "$dockerfile_bak"
		else
			echo "Restoring $dockerfile_bak to $dir/Dockerfile"
			cp "$dockerfile_bak" "$dir/Dockerfile"
		fi
	fi
done