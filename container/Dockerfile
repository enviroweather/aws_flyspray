FROM php:8.3-apache

ARG FLYSPRAY_VERSION=1.0-rc11
# Local dev/test only (see container/README.md); CodeBuild never sets this.
ARG INCLUDE_SETUP=false
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl libpq-dev libpng-dev libjpeg62-turbo-dev libzip-dev libexif12 \ 
    && docker-php-ext-configure gd --with-jpeg \
    && docker-php-ext-install pgsql pdo_pgsql gd zip exif \
    && curl -fsSL "https://github.com/flyspray/flyspray/releases/download/v${FLYSPRAY_VERSION}/flyspray-${FLYSPRAY_VERSION}.tgz" \
      | tar -xz --strip-components=1 -C /var/www/html \
    && test -f /var/www/html/vendor/autoload.php \
    && if [ "$INCLUDE_SETUP" != "true" ]; then rm -rf /var/www/html/setup; fi \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/www/html/cache /var/www/html/attachments /var/www/html/avatars \
    && chown -R www-data:www-data /var/www/html/cache \
    && chmod -R a-w /var/www/html/attachments /var/www/html/avatars \
    && printf 'ok\n' > /var/www/html/health.txt \
    && printf 'file_uploads=Off\n' > /usr/local/etc/php/conf.d/uploads.ini

COPY uploads.ini /usr/local/etc/php/conf.d/uploads.ini
COPY configure.php /usr/local/bin/flyspray-configure.php
COPY docker-entrypoint.sh /usr/local/bin/flyspray-entrypoint
RUN chmod 755 /usr/local/bin/flyspray-entrypoint

EXPOSE 80
ENTRYPOINT ["/usr/local/bin/flyspray-entrypoint"]
CMD ["apache2-foreground"]