#!/bin/bash

LOG_FILE="/var/log/wordpress-manager.log"

# Function to log messages
log_message() {
  TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

  # ANSI escape codes for colors and formatting
  BOLD_WHITE="\e[1;37m"
  LIGHT_GRAY="\e[0;37m"
  RESET="\e[0m"

  # Output the formatted log message
  echo -e "${BOLD_WHITE}${TIMESTAMP}${RESET} - ${LIGHT_GRAY}$1${RESET}" | tee -a /var/log/wordpress-manager.log
}


# Function to process a container when it starts
process_container() {
  container_id=$1
  log_message "Processing container: $container_id"

  # Fetch the groups label
  CONTAINER_GROUPS=$(docker inspect --format='{{index .Config.Labels "ci.groups"}}' $container_id)
  log_message "Groups for container $container_id: $CONTAINER_GROUPS"

  # Check if the container belongs to the "wordpress" group
  if echo "$CONTAINER_GROUPS" | grep -iq "wordpress"; then
    log_message "Container $container_id belongs to 'wordpress' group."

    # Extract DB environment variables from the container
    DB_NAME=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' $container_id | grep WORDPRESS_DB_NAME | cut -d '=' -f2)
    DB_USER=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' $container_id | grep WORDPRESS_DB_USER | cut -d '=' -f2)
    DB_PASS=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' $container_id | grep WORDPRESS_DB_PASS | cut -d '=' -f2)

    CONTAINER_NAME=$(docker inspect --format='{{.Name}}' $container_id | sed 's/^\///')

    # Check if the DB exists
    DB_EXISTS=$(mysql -h mysql -e "SHOW DATABASES LIKE '$DB_NAME';" | grep $DB_NAME)
    USER_EXISTS=$(mysql -h mysql -e "SELECT User FROM mysql.user WHERE User = '$DB_USER';" | grep $DB_USER)

    if [ -n "$DB_EXISTS" ] && [ -n "$USER_EXISTS" ]; then
      log_message "Database and user exist for $CONTAINER_NAME: Skipping."
    else
      if [ -n "$DB_EXISTS" ] && [ -z "$USER_EXISTS" ]; then
        log_message "Database exists but user does not for $CONTAINER_NAME. Creating user..."
        mysql -h mysql -e "CREATE USER '$DB_USER'@'%' IDENTIFIED WITH mysql_native_password;"
        mysql -h mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'%';"
        mysql -h mysql -e "FLUSH PRIVILEGES;"
      elif [ -z "$DB_EXISTS" ] && [ -z "$USER_EXISTS" ]; then
        log_message "Neither database nor user exists for $CONTAINER_NAME. Creating both..."
        mysql -h mysql -e "CREATE DATABASE $DB_NAME;"
        mysql -h mysql -e "CREATE USER '$DB_USER'@'%' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';"
        mysql -h mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'%';"
        mysql -h mysql -e "FLUSH PRIVILEGES;"
      fi
    fi
  else
    log_message "Container $container_id does not belong to the 'wordpress' group. Skipping."
  fi
}

# Listen to Docker events and trigger the process_container function when a container starts
docker events --filter 'event=start' | while read event; do
  container_id=$(echo $event | awk '{print $4}')
  process_container $container_id
done