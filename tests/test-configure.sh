#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

export DB_HOST=example.internal DB_PORT=5432 DB_NAME=flyspray DB_USER=flyspray
export DB_PASS='a$"\b' APP_BASE_URL=https://example.com/
export COOKIE_SALT=keep-me-keep-me-keep-me DB_PREFIX=flyspray_ SYNTAX_PLUGIN=dokuwiki
export FLYSPRAY_CONFIG_PATH="$temp_dir/config"
php "$root/container/configure.php"
php -r '
    $config = parse_ini_file($argv[1], true);
    if ($config["database"]["dbpass"] !== getenv("DB_PASS") ||
        $config["database"]["dbhost"] !== getenv("DB_HOST") ||
        $config["database"]["dbprefix"] !== getenv("DB_PREFIX") ||
        $config["general"]["cookiesalt"] !== getenv("COOKIE_SALT") ||
        $config["general"]["syntax_plugin"] !== getenv("SYNTAX_PLUGIN") ||
        $config["general"]["force_baseurl"] !== getenv("APP_BASE_URL")) {
        exit(1);
    }
' "$FLYSPRAY_CONFIG_PATH"


if DB_HOST= php "$root/container/configure.php" 2>/dev/null; then
  echo "Missing DB_HOST unexpectedly succeeded." >&2
  exit 1
fi
if DB_PORT=5433 php "$root/container/configure.php" 2>/dev/null; then
  echo "Unsupported database port unexpectedly succeeded." >&2
  exit 1
fi
if COOKIE_SALT=tooshort php "$root/container/configure.php" 2>/dev/null; then
  echo "Short cookie salt unexpectedly succeeded." >&2
  exit 1
fi
echo "Flyspray configuration tests passed."