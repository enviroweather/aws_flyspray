#!/usr/bin/env bash
# =============================================================================
# scripts/import_db.sh
# Procedural post-Terraform step: downloads the SQL dump from S3,
# creates the app DB and user, imports the dump, and grants permissions.
#
# Run from the terraform/ directory after 'terraform apply' completes:
#   cd terraform/
#   ./scripts/import_db.sh
#
# Secrets are read from the same TF_VAR_* env vars used by Terraform.
# =============================================================================
set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Read all values from Terraform outputs — no config duplication
# ---------------------------------------------------------------------------
log "Reading Terraform outputs..."
DB_ENDPOINT=$(terraform output -raw db_endpoint)
DB_PORT=$(terraform output -raw db_port)
INSTANCE_NAME=$(terraform output -raw instance_name)

REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
REGION=${REGION:-us-east-1}

# Non-secret vars — read from env or fall back to tfvars defaults
S3_BUCKET="${TF_VAR_s3_bucket:-ewx-flyspray-941061635635-us-east-1-an}"
S3_DUMP_KEY="${TF_VAR_s3_dump_key:-flyspray_22_10_2026.sql}"
APP_DB="${TF_VAR_app_db:-flyspray}"
APP_USER="${TF_VAR_app_user:-flyspray_user}"
DB_INSTANCE_NAME="${TF_VAR_db_instance_name:-flyspray-db}"
DB_MASTER_USER="dbmaster"
LOCAL_DUMP="/tmp/flyspray_dump.sql"

# Secrets — must already be exported (same session as terraform apply)
DB_MASTER_PASSWORD="${TF_VAR_db_master_password:-}"
APP_PASSWORD="${TF_VAR_app_password:-}"
[[ -z "$DB_MASTER_PASSWORD" ]] && err "Set TF_VAR_db_master_password before running."
[[ -z "$APP_PASSWORD" ]]       && err "Set TF_VAR_app_password before running."

log "DB endpoint     : $DB_ENDPOINT:$DB_PORT"
log "App DB / user   : $APP_DB / $APP_USER"
log "S3 source       : s3://$S3_BUCKET/$S3_DUMP_KEY"

# ---------------------------------------------------------------------------
# Enable public DB access temporarily for the import
# ---------------------------------------------------------------------------
log "Enabling public endpoint on DB..."
aws lightsail update-relational-database \
  --relational-database-name "$DB_INSTANCE_NAME" \
  --publicly-accessible \
  --region "$REGION" --output text > /dev/null

log "Waiting for DB to become available..."
while true; do
  STATE=$(aws lightsail get-relational-database \
    --relational-database-name "$DB_INSTANCE_NAME" \
    --region "$REGION" \
    --query 'relationalDatabase.state' \
    --output text 2>/dev/null || echo "pending")
  [[ "$STATE" == "available" ]] && break
  log "  DB state: $STATE — waiting..."
  sleep 20
done

# ---------------------------------------------------------------------------
# Download dump from S3
# ---------------------------------------------------------------------------
log "Downloading dump from s3://$S3_BUCKET/$S3_DUMP_KEY"
aws s3 cp "s3://$S3_BUCKET/$S3_DUMP_KEY" "$LOCAL_DUMP" --region "$REGION"

# ---------------------------------------------------------------------------
# Create app DB, user, import dump, grant permissions
# ---------------------------------------------------------------------------
export PGPASSWORD="$DB_MASTER_PASSWORD"

log "Granting public schema privileges (PG15+)..."
psql -h "$DB_ENDPOINT" -p "$DB_PORT" -U "$DB_MASTER_USER" -d postgres <<SQL
GRANT ALL ON SCHEMA public TO "$DB_MASTER_USER";
SQL

log "Creating app database '$APP_DB' and user '$APP_USER'..."
psql -h "$DB_ENDPOINT" -p "$DB_PORT" -U "$DB_MASTER_USER" -d postgres <<SQL
SELECT 'CREATE DATABASE $APP_DB'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$APP_DB')\gexec
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$APP_USER') THEN
    CREATE ROLE "$APP_USER" LOGIN PASSWORD '$APP_PASSWORD';
  END IF;
END
\$\$;
SQL

log "Granting schema privileges on app database..."
psql -h "$DB_ENDPOINT" -p "$DB_PORT" -U "$DB_MASTER_USER" -d "$APP_DB" <<SQL
GRANT ALL ON SCHEMA public TO "$DB_MASTER_USER";
GRANT USAGE, CREATE ON SCHEMA public TO "$APP_USER";
SQL

log "Importing SQL dump into '$APP_DB'..."
psql -h "$DB_ENDPOINT" -p "$DB_PORT" -U "$DB_MASTER_USER" -d "$APP_DB" \
  --single-transaction -v ON_ERROR_STOP=0 -f "$LOCAL_DUMP"

log "Granting app user access to all imported tables..."
psql -h "$DB_ENDPOINT" -p "$DB_PORT" -U "$DB_MASTER_USER" -d "$APP_DB" <<SQL
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO "$APP_USER";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "$APP_USER";
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO "$APP_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO "$APP_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "$APP_USER";
SQL

unset PGPASSWORD

# ---------------------------------------------------------------------------
# Disable public DB access
# ---------------------------------------------------------------------------
log "Disabling public endpoint on DB..."
aws lightsail update-relational-database \
  --relational-database-name "$DB_INSTANCE_NAME" \
  --no-publicly-accessible \
  --region "$REGION" --output text > /dev/null

log "DB import complete. Run output/setup_ssl.sh after DNS propagates."
