#!/bin/bash

source "$(dirname "$0")/../.env"
    
# Function to log messages
log_message() {
  TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
  # ANSI escape codes for colors and formatting
  BOLD_WHITE="\e[1;37m"
  LIGHT_GRAY="\e[0;37m"
  RESET="\e[0m"
  
  # Output the formatted log message
  echo -e "${BOLD_WHITE}${TIMESTAMP}${RESET} - ${LIGHT_GRAY}$1${RESET}" | tee -a $LOG_PATH/wordpress-manager.log
}
  
BACKUP_DIR=$BACKUP_PATH
DATE=$(date +%Y%m%d_%H%M%S)

# Get a list of databases
databases=$(mysql -h mysql -e "SHOW DATABASES;" | grep -Ev "(Database|information_schema|performance_schema)")

for db in $databases; do
  mysqldump -h mysql $db | gzip > $BACKUP_DIR/${db}_$DATE.sql.gz