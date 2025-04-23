FROM wordpress:latest


# Switch to root to install required packages
USER root

# Install necessary packages: curl, mariadb-client, and cron
RUN apt-get update && apt-get install -y curl mariadb-client cron  \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libzip-dev \
    zip \
    unzip \
	zlib1g-dev \
    libxml2-dev \
	&& pecl install redis \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install gd zip soap \
    && docker-php-ext-enable redis soap \
	&& rm -rf /var/lib/apt/lists/*

# Install Redis extension

# Install Composer
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# Download WP-CLI, rename it, move it to /usr/local/bin, and make it executable
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && \
    mv wp-cli.phar /usr/local/bin/wp && \
    chmod +x /usr/local/bin/wp


# Copy cron scripts to the container
COPY php.ini /usr/local/etc/php/conf.d/uploads.ini:ro
COPY wp-config.php /var/www/html/wp-config.php
COPY .htaccess /var/www/html/.htaccess
COPY ./wp_rocket_settings.json /wp_rocket_settings.json

# Create log directory and ensure correct permissions
RUN mkdir /data && \
    mkdir -p /var/www/log && \
    touch /var/www/log/wordpress-website.log && \
    chown -R www-data:www-data /data && \
    chown -R www-data:www-data /var/www && \
    chmod -R 775 /var/www/log && \
    find -type f -exec chmod 644 {} \; && \
    find -type d -exec chmod 755 {} \; && \
    chmod 444 /var/www/html/wp-config.php && \
    chmod 444 /var/www/html/.htaccess;

# Copy the container-init script and make it executable
COPY container-init.sh /usr/local/bin/container-init.sh
RUN chmod +x /usr/local/bin/container-init.sh && chown www-data:www-data /usr/local/bin/container-init.sh

# Switch to www-data for the rest
USER www-data

# Set the entrypoint script
ENTRYPOINT ["/usr/local/bin/container-init.sh"]
