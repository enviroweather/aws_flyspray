<?php
declare(strict_types=1);

// Generates flyspray.conf.php from plain environment variables at container
// startup. No secret is baked into the image; all values come from the
// Lightsail deployment's environment (set by Terraform from .env/TF_VAR_*).

function required_env(string $name): string
{
    $value = getenv($name);
    if ($value === false || $value === '') {
        fwrite(STDERR, "Missing required environment variable: $name\n");
        exit(1);
    }
    return $value;
}

$dbHost      = required_env('DB_HOST');
$dbPort      = required_env('DB_PORT');
$dbName      = required_env('DB_NAME');
$dbUser      = required_env('DB_USER');
$dbPass      = required_env('DB_PASS');
$baseUrl     = required_env('APP_BASE_URL');
$cookieSalt  = required_env('COOKIE_SALT');
$dbPrefix    = getenv('DB_PREFIX') ?: 'flyspray_';
$syntaxPlugin = getenv('SYNTAX_PLUGIN') ?: '';

if ($dbPort !== '5432') {
    fwrite(STDERR, "Only the default PostgreSQL port 5432 is supported.\n");
    exit(1);
}
if (strlen($cookieSalt) < 16) {
    fwrite(STDERR, "COOKIE_SALT must be at least 16 characters.\n");
    exit(1);
}
if (!preg_match('/^[a-zA-Z0-9_]*$/', $dbPrefix)) {
    fwrite(STDERR, "DB_PREFIX contains unsupported characters.\n");
    exit(1);
}
if (!preg_match('/^[a-zA-Z0-9_]*$/', $syntaxPlugin)) {
    fwrite(STDERR, "SYNTAX_PLUGIN contains unsupported characters.\n");
    exit(1);
}

$config = [
    'database' => [
        'dbtype'   => 'pgsql',
        'dbhost'   => $dbHost,
        'dbname'   => $dbName,
        'dbuser'   => $dbUser,
        'dbpass'   => $dbPass,
        'dbprefix' => $dbPrefix,
    ],
    'general' => [
        'cookiesalt'       => $cookieSalt,
        'output_buffering' => 'on',
        'passwdcrypt'      => '',
        'dot_path'         => '',
        'dot_format'       => 'png',
        'reminder_daemon'  => '1',
        'doku_url'         => 'http://en.wikipedia.org/wiki/',
        'syntax_plugin'    => 'html',
        'update_check'     => '1',
        'address_rewriting' => '0',
        'force_baseurl'    => $baseUrl,
        'securecookies'    => ''
    ],
    'attachments' => [
        'zip' => 'application/zip',
    ],
    'oauth' => [
        'github_secret' => '',
        'github_id' => '',
        'google_secret' => '',
        'google_id' => '',
        'facebook_secret' => '',
        'facebook_id' => '',
        'microsoft_secret' => '',
        'microsoft_id' => '',
    ],
];

$output = "; <?php die('Do not access this page directly.'); ?>\n";
foreach ($config as $section => $values) {
    $output .= "\n[$section]\n";
    foreach ($values as $key => $value) {
        if (strpbrk($value, "\r\n") !== false) {
            fwrite(STDERR, "Unsupported configuration value for $key.\n");
            exit(1);
        }
        $escaped = str_replace(['\\', '"', '$'], ['\\\\', '\\"', '\\$'], $value);
        $output .= "$key = \"$escaped\"\n";
    }
}
if (parse_ini_string($output, true) !== $config) {
    fwrite(STDERR, "Configuration could not be represented safely.\n");
    exit(1);
}
$path = getenv('FLYSPRAY_CONFIG_PATH') ?: '/var/www/html/flyspray.conf.php';
umask(0027);
if (file_put_contents($path, $output) === false || !chmod($path, 0640)) {
    fwrite(STDERR, "Failed to write Flyspray configuration.\n");
    exit(1);
}
