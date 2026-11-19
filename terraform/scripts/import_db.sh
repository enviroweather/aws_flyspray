#!/usr/bin/env bash
set -euo pipefail

force=false

while getopts "f" opt; do
  case "$opt" in
    f) force=true ;;
    *) echo "Usage: bash myscript.sh [-f] /path/to/file" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

if [[ $# -ne 1 ]]; then
  echo "Usage: bash scripts/import_db.sh /path/to/dump.sql [-f]" >&2
  exit 2
fi

dump_file=$1
[[ -f "$dump_file" ]] || { echo "SQL dump does not exist or is not a regular file: $dump_file" >&2; exit 1; }
[[ -r "$dump_file" ]] || { echo "SQL dump is not readable: $dump_file" >&2; exit 1; }

for executable in terraform psql; do
  command -v "$executable" >/dev/null || { echo "Missing required command: $executable" >&2; exit 1; }
done
: "${TF_VAR_db_master_password:?Set TF_VAR_db_master_password}"
: "${TF_VAR_app_password:?Set TF_VAR_app_password}"

db_host="${PGHOST:-$(terraform output -raw db_endpoint)}"
db_port="${PGPORT:-$(terraform output -raw db_port)}"
app_db="$(terraform output -raw app_db)"
app_user="$(terraform output -raw app_user)"

export PGPASSWORD="$TF_VAR_db_master_password" PGHOST="$db_host" PGPORT="$db_port" PGUSER=dbmaster
psql -X -v ON_ERROR_STOP=1 -v app_user="$app_user" -v app_db="$app_db" -d postgres <<'SQL'
\getenv app_password TF_VAR_app_password
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'app_db', :'app_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'app_db') \gexec
SQL




table_count=$(psql -X -At -v ON_ERROR_STOP=1 -d "$app_db" -c "SELECT count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p');")

  
if [[ "$table_count" != "0" ]]; then
  if [ "$force" = false ]; then
    echo "Refusing to import into a database with existing public tables. use the -f flag to force overwrite" >&2
    exit 1
  else
    echo "$table_count tables exist but force flag is set, overwriting...  " >&2
  fi
fi

psql -X -v ON_ERROR_STOP=1 --single-transaction -d "$app_db" -f "$dump_file"
psql -X -v ON_ERROR_STOP=1 -v app_user="$app_user" -d "$app_db" <<'SQL'
SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'app_user') \gexec
SELECT format('GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO %I', :'app_user') \gexec
SELECT format('GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO %I', :'app_user') \gexec
SELECT format('GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO %I', :'app_user') \gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO %I', :'app_user') \gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO %I', :'app_user') \gexec
SQL
echo "Database import complete. Verify the app user's password if the role already existed."