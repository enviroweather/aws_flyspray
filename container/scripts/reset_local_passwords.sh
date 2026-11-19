#!/usr/bin/env bash
# One-time local recovery helper for a disposable Docker Compose Flyspray DB.
# It intentionally refuses to run without --yes, and never prints passwords.
set -euo pipefail

usage() {
  echo "Usage: $0 --yes [BASE_URL] [OUTPUT_FILE]" >&2
  echo "  BASE_URL defaults to http://localhost:8080" >&2
  echo "  OUTPUT_FILE must be outside the repository and is created mode 0600." >&2
}

[[ "${1:-}" == "--yes" ]] || { usage; exit 2; }
base_url=${2:-http://localhost:8080}
base_url=${base_url%/}
output_file=${3:-"$HOME/.flyspray-password-resets-$(date -u '+%Y%m%dT%H%M%SZ').csv"}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
container_dir=$(cd "$script_dir/.." && pwd)
repo_root=$(cd "$container_dir/.." && pwd)

case "$output_file" in
  "$repo_root"|"$repo_root"/*) echo "Refusing to write credential output inside the repository: $output_file" >&2; exit 1 ;;
esac

for executable in docker php; do
  command -v "$executable" >/dev/null || { echo "Missing required command: $executable" >&2; exit 1; }
done

users=()
while IFS= read -r row; do
  [[ -n "$row" ]] && users+=("$row")
done < <(
  docker compose -f "$container_dir/docker-compose.dev.yml" exec -T db \
    psql -U flyspray_user -d flyspray -At -F '|' \
    -c "SELECT user_id,user_name FROM flyspray_users WHERE account_enabled=1 ORDER BY user_id"
)
[[ ${#users[@]} -gt 0 ]] || { echo "No enabled Flyspray users found." >&2; exit 1; }

umask 077
: > "$output_file"
chmod 600 "$output_file"
printf 'user_id,user_name,temporary_password,change_password_url\n' >> "$output_file"

for row in "${users[@]}"; do
  user_id=${row%%|*}
  user_name=${row#*|}
  password=$(php -r 'echo bin2hex(random_bytes(9));')
  reset_token=$(php -r 'echo md5(random_bytes(32));')
  password_hash=$(RESET_PASSWORD="$password" php -r 'echo password_hash(getenv("RESET_PASSWORD"), PASSWORD_BCRYPT, ["cost" => 12]);')
  reset_url="$base_url/index.php?do=lostpw&magic_url=$reset_token"

  RESET_HASH="$password_hash" RESET_TOKEN="$reset_token" docker compose \
    -f "$container_dir/docker-compose.dev.yml" exec -T \
    -e RESET_HASH -e RESET_TOKEN db psql -X -v ON_ERROR_STOP=1 \
    -U flyspray_user -d flyspray -q <<SQL >/dev/null
\getenv reset_hash RESET_HASH
\getenv reset_token RESET_TOKEN
UPDATE flyspray_users
SET user_pass = :'reset_hash',
    magic_url = :'reset_token',
    login_attempts = 0,
    lock_until = 0,
    account_enabled = 1
WHERE user_id = $user_id;
SQL

  printf '%s,%s,%s,%s\n' "$user_id" "$user_name" "$password" "$reset_url" >> "$output_file"
done

echo "Reset ${#users[@]} enabled local Flyspray accounts."
echo "Credentials and one-time reset URLs were written to: $output_file"
echo "Distribute privately, then delete the file. Each reset URL is invalidated after use or after that account logs in."
