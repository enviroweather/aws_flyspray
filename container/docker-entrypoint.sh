#!/bin/sh
set -eu
php /usr/local/bin/flyspray-configure.php
chown www-data:www-data /var/www/html/flyspray.conf.php
exec docker-php-entrypoint "$@"