FROM alpine:3.21

# Install necessary packages: curl, mariadb-client, bash, cron, Docker CLI tools, and mariadb plugin dependencies
RUN apk add --no-cache curl mariadb-client bash mariadb-connector-c docker-cli dcron && rm -rf /var/cache/apk/*

# Copy the db initialization service worker
COPY init-db.sh /usr/local/bin/init-db.sh
RUN chmod +x /usr/local/bin/init-db.sh

# Copy the db backup service worker
COPY backup-databases.sh /usr/local/bin/backup-databases.sh
RUN chmod +x /usr/local/bin/backup-databases.sh

# Set the entrypoint script to monitor containers
ENTRYPOINT ["/usr/local/bin/init-db.sh"]