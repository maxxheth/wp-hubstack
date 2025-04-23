#!/bin/bash
# 7-Day Rotating Backup Script for WordPress Databases
# ================================================
# This script will:
#   1. Loop through all databases with names starting with "wp_"
#   2. Create a backup using mysqldump
#   3. Save the backup file as /var/opt/backup/{db_name}-{day_of_week}.sql
#

source "$(dirname "$0")/../.env"

DOCKER_CONTAINER="mysql"
BACKUP_DIR=$BACKUP_PATH

# Get the day of the week as a number (1-7; Monday=1, Sunday=7)
DAY=$(date +%u)
    
# Ensure the backup directory exists
mkdir -p "${BACKUP_DIR}"
        
echo "Starting backup process on day ${DAY}..."

# Get a list of databases that start with 'wp_'
DATABASES=$(docker exec ${DOCKER_CONTAINER} mysql -p${MYSQL_PASS} -e "SHOW DATABASES;" | grep '^wp_')
  
for db in ${DATABASES}; do
    # Skip header line if present
    if [ "$db" == "Database" ]; then
        continue
    fi
            
    BACKUP_FILE="${BACKUP_DIR}/${db}-${DAY}.sql"
    echo "Backing up database '${db}' to '${BACKUP_FILE}'..."
            
    # Execute mysqldump via Docker and redirect output to the backup file
    docker exec ${DOCKER_CONTAINER} mysqldump -p${MYSQL_PASS} ${db} > "${BACKUP_FILE}"

    if [ $? -eq 0 ]; then
        echo "Backup of '${db}' completed successfully."
    else        
        echo "Error backing up '${db}'! Check the logs for details."
    fi          
done            
            
echo "All backups complete."
