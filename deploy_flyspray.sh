#!/usr/bin/env bash
# =============================================================================
# deploy_flyspray.sh  
#
# Variable resolution order:
#   1. CLI positional args  ($1=INSTANCE_NAME  $2=APP_HOSTNAME  $3=SSL_EMAIL)
#   2. Environment vars     (FLYSPRAY_*)
#   3. Defaults             (hardcoded in resolve_vars)
#   4. Derived              (AZ from REGION, STATIC_IP_NAME from INSTANCE_NAME,
#                            INSTANCE_IP fetched live from AWS)
#
# Secrets (DB_MASTER_PASSWORD, APP_PASSWORD) have NO default and error out
# if not supplied via environment.
#
# Usage:
#   # Normal full deploy:
#   export FLYSPRAY_DB_MASTER_PASSWORD="..."
#   export FLYSPRAY_APP_PASSWORD="..."
#   ./deploy_flyspray.sh flyspray-app flyspray.example.com admin@example.com
#
#   # Resume after a crash (skips already-completed steps):
#   export FLYSPRAY_DB_MASTER_PASSWORD="..."
#   export FLYSPRAY_APP_PASSWORD="..."
#   ./deploy_flyspray.sh flyspray-app flyspray.example.com admin@example.com --resume
#
#   # Dev/test with smaller bundles:
#   export FLYSPRAY_INSTANCE_BUNDLE="nano_3_0"
#   ./deploy_flyspray.sh flyspray-dev dev.example.com admin@example.com
#
# Prerequisites:
#   - AWS CLI v2, configured (region set via 'aws configure')
#   - psql client  (apt install postgresql-client / brew install libpq)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
err()  { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "  [SKIP] $*"; }

# require VAR_NAME "description"
# Exits with a clear message if the named variable is empty or unset.
require() {
  local var_name="$1"
  local description="$2"
  local value="${!var_name:-}"
  if [[ -z "$value" ]]; then
    err "Required value not set: $description

  Set it via environment variable:
    export ${var_name}=\"your-value\"

  For secrets, avoid shell history:
    read -s -p \"${description}: \" ${var_name} && export ${var_name}"
  fi
}

# ---------------------------------------------------------------------------
# RESOLVE VARS
# All variables are defined here and only here — never redefined below.
# Called once at startup. Safe to re-source in a recovery session:
#   export FLYSPRAY_DB_MASTER_PASSWORD="..."
#   export FLYSPRAY_APP_PASSWORD="..."
#   source <(sed -n '/^resolve_vars/,/^}/p' deploy_flyspray.sh)
#   resolve_vars flyspray-app flyspray.example.com admin@example.com
# ---------------------------------------------------------------------------
resolve_vars() {
  # --- Region (from AWS CLI config, fallback us-east-1) ---
  REGION=$(aws configure get region 2>/dev/null || echo "")
  REGION=${REGION:-us-east-1}
  AZ="${REGION}a"

  # --- Positional args ---
  local _instance="${1:-}"
  local _hostname="${2:-}"
  local _email="${3:-}"

  # --- Instance ---
  INSTANCE_NAME="${_instance:-${FLYSPRAY_INSTANCE_NAME:-flyspray-app}}"
  INSTANCE_BLUEPRINT="lamp_8_bitnami"
  INSTANCE_BUNDLE="${FLYSPRAY_INSTANCE_BUNDLE:-micro_3_0}"
  STATIC_IP_NAME="${INSTANCE_NAME}-static-ip"

  # --- Hostname and SSL (required) ---
  APP_HOSTNAME="${_hostname:-${FLYSPRAY_HOSTNAME:-}}"
  SSL_EMAIL="${_email:-${FLYSPRAY_SSL_EMAIL:-}}"
  require APP_HOSTNAME "App hostname (e.g. flyspray.example.com) — set FLYSPRAY_HOSTNAME or pass as \$2"
  require SSL_EMAIL    "SSL/Let's Encrypt email — set FLYSPRAY_SSL_EMAIL or pass as \$3"

  # --- Database ---
  DB_INSTANCE_NAME="${FLYSPRAY_DB_NAME:-flyspray-db}"
  DB_BUNDLE="${FLYSPRAY_DB_BUNDLE:-micro_2_0}"
  DB_BLUEPRINT="postgres_16"
  DB_MASTER_USER="dbmaster"
  DB_INITIAL_NAME="postgres"

  # --- Secrets (required, no default) ---
  DB_MASTER_PASSWORD="${FLYSPRAY_DB_MASTER_PASSWORD:-}"
  require DB_MASTER_PASSWORD "DB master password — set FLYSPRAY_DB_MASTER_PASSWORD"
  APP_PASSWORD="${FLYSPRAY_APP_PASSWORD:-}"
  require APP_PASSWORD "App DB password — set FLYSPRAY_APP_PASSWORD"

  # --- App DB / user ---
  APP_DB="${FLYSPRAY_APP_DB:-flyspray}"
  APP_USER="${FLYSPRAY_APP_USER:-flyspray_user}"

  # --- S3 dump source ---
  S3_BUCKET="${FLYSPRAY_S3_BUCKET:-ewx-flyspray-941061635635-us-east-1-an}"
  S3_DUMP_KEY="${FLYSPRAY_S3_DUMP_KEY:-flyspray_22_10_2026.sql}"
  LOCAL_DUMP="/tmp/flyspray_dump.sql"

  # --- Snapshot schedule (UTC) ---
  export INSTANCE_SNAPSHOT_TIME="06:00"
  export DB_BACKUP_WINDOW="07:00-07:30"

  # --- Output paths ---
  OUTPUT_CONF="/tmp/flyspray.conf.php"
  OUTPUT_SSL_SCRIPT="/tmp/setup_ssl.sh"

  # --- INSTANCE_IP: fetched live from AWS so it survives shell restarts ---
  INSTANCE_IP=$(aws lightsail get-static-ip \
    --static-ip-name "$STATIC_IP_NAME" \
    --region "$REGION" \
    --query 'staticIp.ipAddress' \
    --output text 2>/dev/null || echo "")

  log "Variables resolved. Region: $REGION | Instance: $INSTANCE_NAME | IP: ${INSTANCE_IP:-not yet allocated}"
}

# ---------------------------------------------------------------------------
# WAIT HELPERS
# ---------------------------------------------------------------------------
wait_for_instance() {
  local name="$1"
  log "Waiting for instance '$name' to be running..."
  while true; do
    STATE=$(aws lightsail get-instance \
      --instance-name "$name" \
      --region "$REGION" \
      --query 'instance.state.name' \
      --output text 2>/dev/null || echo "pending")
    log "  Instance state: $STATE"
    [[ "$STATE" == "running" ]] && break
    sleep 15
  done
}

wait_for_db() {
  local name="$1"
  log "Waiting for DB '$name' to become available..."
  while true; do
    STATE=$(aws lightsail get-relational-database \
      --relational-database-name "$name" \
      --region "$REGION" \
      --query 'relationalDatabase.state' \
      --output text 2>/dev/null || echo "pending")
    log "  DB state: $STATE"
    [[ "$STATE" == "available" ]] && break
    sleep 20
  done
}

# ---------------------------------------------------------------------------
# RESUME STATE CHECKS
# Each function queries AWS and returns 0 (true) if the step can be skipped.
# ---------------------------------------------------------------------------
instance_exists() {
  local state
  state=$(aws lightsail get-instance \
    --instance-name "$INSTANCE_NAME" \
    --region "$REGION" \
    --query 'instance.state.name' \
    --output text 2>/dev/null || echo "")
  [[ -n "$state" && "$state" != "terminated" ]]
}

db_exists() {
  local state
  state=$(aws lightsail get-relational-database \
    --relational-database-name "$DB_INSTANCE_NAME" \
    --region "$REGION" \
    --query 'relationalDatabase.state' \
    --output text 2>/dev/null || echo "")
  [[ -n "$state" ]]
}

static_ip_exists() {
  aws lightsail get-static-ip \
    --static-ip-name "$STATIC_IP_NAME" \
    --region "$REGION" \
    --output text > /dev/null 2>&1
}

static_ip_attached() {
  local attached
  attached=$(aws lightsail get-static-ip \
    --static-ip-name "$STATIC_IP_NAME" \
    --region "$REGION" \
    --query 'staticIp.isAttached' \
    --output text 2>/dev/null || echo "False")
  [[ "$attached" == "True" ]]
}

snapshot_addon_enabled() {
  local status
  status=$(aws lightsail get-instance \
    --instance-name "$INSTANCE_NAME" \
    --region "$REGION" \
    --query 'instance.addOns[?name==`AutoSnapshot`].status' \
    --output text 2>/dev/null || echo "")
  [[ "$status" == "Enabled" ]]
}

db_backup_enabled() {
  local enabled
  enabled=$(aws lightsail get-relational-database \
    --relational-database-name "$DB_INSTANCE_NAME" \
    --region "$REGION" \
    --query 'relationalDatabase.backupRetentionEnabled' \
    --output text 2>/dev/null || echo "False")
  [[ "$enabled" == "True" ]]
}

# ---------------------------------------------------------------------------
# PARSE ARGS — strip --resume before passing positional args to resolve_vars
# ---------------------------------------------------------------------------
RESUME=false
POS_ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--resume" ]]; then
    RESUME=true
  else
    POS_ARGS+=("$arg")
  fi
done

# ---------------------------------------------------------------------------
# RESOLVE ALL VARIABLES (once, here, never again below)
# ---------------------------------------------------------------------------
resolve_vars "${POS_ARGS[@]:-}"

# ---------------------------------------------------------------------------
# PRE-FLIGHT SUMMARY
# ---------------------------------------------------------------------------
echo ""
echo "  ---- Resolved configuration ----"
echo "  REGION            : $REGION"
echo "  AZ                : $AZ"
echo "  INSTANCE_NAME     : $INSTANCE_NAME"
echo "  INSTANCE_BUNDLE   : $INSTANCE_BUNDLE"
echo "  STATIC_IP_NAME    : $STATIC_IP_NAME"
echo "  APP_HOSTNAME      : $APP_HOSTNAME"
echo "  SSL_EMAIL         : $SSL_EMAIL"
echo "  DB_INSTANCE_NAME  : $DB_INSTANCE_NAME"
echo "  DB_BUNDLE         : $DB_BUNDLE"
echo "  APP_DB            : $APP_DB"
echo "  APP_USER          : $APP_USER"
echo "  DB_MASTER_PASSWORD: (set)"
echo "  APP_PASSWORD      : (set)"
echo "  RESUME MODE       : $RESUME"
echo ""
read -r -p "Proceed with deployment? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo ""

# ---------------------------------------------------------------------------
# STEP 1 — Create the Lightsail managed PostgreSQL database
# ---------------------------------------------------------------------------
if $RESUME && db_exists; then
  info "Step 1: DB '$DB_INSTANCE_NAME' already exists — skipping create."
else
  log "Step 1: Creating managed PostgreSQL database: $DB_INSTANCE_NAME"
  aws lightsail create-relational-database \
    --relational-database-name "$DB_INSTANCE_NAME" \
    --availability-zone "$AZ" \
    --relational-database-blueprint-id "$DB_BLUEPRINT" \
    --relational-database-bundle-id "$DB_BUNDLE" \
    --master-database-name "$DB_INITIAL_NAME" \
    --master-username "$DB_MASTER_USER" \
    --master-user-password "$DB_MASTER_PASSWORD" \
    --no-publicly-accessible \
    --region "$REGION" \
    --output text > /dev/null
fi

# ---------------------------------------------------------------------------
# STEP 2 — Create the Lightsail instance (LAMP PHP 8)
# ---------------------------------------------------------------------------
if $RESUME && instance_exists; then
  info "Step 2: Instance '$INSTANCE_NAME' already exists — skipping create."
else
  log "Step 2: Creating Lightsail instance: $INSTANCE_NAME"
  aws lightsail create-instances \
    --instance-names "$INSTANCE_NAME" \
    --availability-zone "$AZ" \
    --blueprint-id "$INSTANCE_BLUEPRINT" \
    --bundle-id "$INSTANCE_BUNDLE" \
    --region "$REGION" \
    --output text > /dev/null
fi

# ---------------------------------------------------------------------------
# STEP 3 — Wait for instance AND database to be fully ready
#           Checked here before touching either resource further.
# ---------------------------------------------------------------------------
log "Step 3: Waiting for instance and database to be ready..."
wait_for_instance "$INSTANCE_NAME"
wait_for_db      "$DB_INSTANCE_NAME"

# ---------------------------------------------------------------------------
# STEP 4 — Open HTTP and HTTPS firewall ports
#           HTTP (80) required for Let's Encrypt challenge.
#           HTTPS (443) for normal access after SSL.
#           open-instance-public-ports is idempotent — safe to re-run.
# ---------------------------------------------------------------------------
log "Step 4: Opening HTTP (80) and HTTPS (443) on instance firewall"
aws lightsail open-instance-public-ports \
  --instance-name "$INSTANCE_NAME" \
  --port-info fromPort=80,toPort=80,protocol=TCP \
  --region "$REGION" --output text > /dev/null
aws lightsail open-instance-public-ports \
  --instance-name "$INSTANCE_NAME" \
  --port-info fromPort=443,toPort=443,protocol=TCP \
  --region "$REGION" --output text > /dev/null

# ---------------------------------------------------------------------------
# STEP 5 — Allocate a static IP and attach it to the instance
# ---------------------------------------------------------------------------
if $RESUME && static_ip_exists; then
  info "Step 5: Static IP '$STATIC_IP_NAME' already exists — skipping allocate."
else
  log "Step 5: Allocating static IP: $STATIC_IP_NAME"
  aws lightsail allocate-static-ip \
    --static-ip-name "$STATIC_IP_NAME" \
    --region "$REGION" \
    --output text > /dev/null
fi

if $RESUME && static_ip_attached; then
  info "Step 5: Static IP already attached — skipping attach."
else
  log "Step 5: Attaching static IP '$STATIC_IP_NAME' to '$INSTANCE_NAME'"
  aws lightsail attach-static-ip \
    --static-ip-name "$STATIC_IP_NAME" \
    --instance-name "$INSTANCE_NAME" \
    --region "$REGION" \
    --output text > /dev/null
fi

# Refresh INSTANCE_IP now that the static IP is confirmed attached
INSTANCE_IP=$(aws lightsail get-static-ip \
  --static-ip-name "$STATIC_IP_NAME" \
  --region "$REGION" \
  --query 'staticIp.ipAddress' \
  --output text)
log "Static IP: $INSTANCE_IP"

# ---------------------------------------------------------------------------
# STEP 6 — Enable automatic snapshots
# ---------------------------------------------------------------------------
if $RESUME && snapshot_addon_enabled; then
  info "Step 6: Auto-snapshot already enabled on instance — skipping."
else
  log "Step 6: Enabling automatic daily snapshot on instance (${INSTANCE_SNAPSHOT_TIME} UTC)..."
  aws lightsail enable-add-on \
    --resource-name "$INSTANCE_NAME" \
    --add-on-request "addOnType=AutoSnapshot,autoSnapshotAddOnRequest={snapshotTimeOfDay=${INSTANCE_SNAPSHOT_TIME}}" \
    --region "$REGION" \
    --output text > /dev/null
fi

if $RESUME && db_backup_enabled; then
  info "Step 6: DB backup retention already enabled — skipping."
else
  log "Step 6: Enabling automatic backups on database (window: ${DB_BACKUP_WINDOW} UTC)..."
  aws lightsail update-relational-database \
    --relational-database-name "$DB_INSTANCE_NAME" \
    --preferred-backup-window "$DB_BACKUP_WINDOW" \
    --preferred-maintenance-window  sun:00:00-sun:01:00  \
    --enable-backup-retention \
    --region "$REGION" \
    --output text > /dev/null
fi

# ---------------------------------------------------------------------------
# STEP 7 — Retrieve the DB endpoint
# ---------------------------------------------------------------------------
log "Step 7: Retrieving DB endpoint..."
DB_ENDPOINT=$(aws lightsail get-relational-database \
  --relational-database-name "$DB_INSTANCE_NAME" \
  --region "$REGION" \
  --query 'relationalDatabase.masterEndpoint.address' \
  --output text)
DB_PORT=$(aws lightsail get-relational-database \
  --relational-database-name "$DB_INSTANCE_NAME" \
  --region "$REGION" \
  --query 'relationalDatabase.masterEndpoint.port' \
  --output text)
log "DB endpoint: $DB_ENDPOINT:$DB_PORT"

# ---------------------------------------------------------------------------
# STEP 8 — Enable public DB access temporarily for the import
# ---------------------------------------------------------------------------
log "Step 8: Enabling public endpoint on DB for import..."
aws lightsail update-relational-database \
  --relational-database-name "$DB_INSTANCE_NAME" \
  --publicly-accessible \
  --region "$REGION" --output text > /dev/null
wait_for_db "$DB_INSTANCE_NAME"

# ---------------------------------------------------------------------------
# STEP 9 — Download the SQL dump from S3
# ---------------------------------------------------------------------------
if $RESUME && [[ -f "$LOCAL_DUMP" ]]; then
  info "Step 9: Dump already at $LOCAL_DUMP — skipping download."
else
  log "Step 9: Downloading dump from s3://$S3_BUCKET/$S3_DUMP_KEY"
  aws s3 cp "s3://$S3_BUCKET/$S3_DUMP_KEY" "$LOCAL_DUMP" --region "$REGION"
fi

# ---------------------------------------------------------------------------
# STEP 10 — Prepare PostgreSQL, create app DB/user, import dump
# ---------------------------------------------------------------------------
export PGPASSWORD="$DB_MASTER_PASSWORD"

log "Step 10: Granting public schema privileges (PG15+)..."
psql -h "$DB_ENDPOINT" -p "$DB_PORT" -U "$DB_MASTER_USER" -d "$DB_INITIAL_NAME" <<SQL
GRANT ALL ON SCHEMA public TO "$DB_MASTER_USER";
SQL

log "Step 10: Creating app database '$APP_DB' and user '$APP_USER'..."
psql -h "$DB_ENDPOINT" -p "$DB_PORT" -U "$DB_MASTER_USER" -d "$DB_INITIAL_NAME" <<SQL
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

log "Step 10: Granting schema privileges on app database..."
psql -h "$DB_ENDPOINT" -p "$DB_PORT" -U "$DB_MASTER_USER" -d "$APP_DB" <<SQL
GRANT ALL ON SCHEMA public TO "$DB_MASTER_USER";
GRANT USAGE, CREATE ON SCHEMA public TO "$APP_USER";
SQL

log "Step 10: Importing SQL dump into '$APP_DB'..."
psql -h "$DB_ENDPOINT" -p "$DB_PORT" -U "$DB_MASTER_USER" -d "$APP_DB" \
  --single-transaction \
  -v ON_ERROR_STOP=0 \
  -f "$LOCAL_DUMP"

log "Step 10: Granting app user access to all imported tables..."
psql -h "$DB_ENDPOINT" -p "$DB_PORT" -U "$DB_MASTER_USER" -d "$APP_DB" <<SQL
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO "$APP_USER";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "$APP_USER";
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO "$APP_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO "$APP_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "$APP_USER";
SQL

unset PGPASSWORD

# ---------------------------------------------------------------------------
# STEP 11 — Disable public DB access
# ---------------------------------------------------------------------------
log "Step 11: Disabling public endpoint on DB..."
aws lightsail update-relational-database \
  --relational-database-name "$DB_INSTANCE_NAME" \
  --no-publicly-accessible \
  --region "$REGION" --output text > /dev/null

# ---------------------------------------------------------------------------
# STEP 12 — Write flyspray.conf.php
# ---------------------------------------------------------------------------
if $RESUME && [[ -f "$OUTPUT_CONF" ]]; then
  info "Step 12: $OUTPUT_CONF already exists — skipping."
else
  log "Step 12: Writing $OUTPUT_CONF"
  cat > "$OUTPUT_CONF" <<PHP
<?php
####################################################################
# Flyspray configuration file — generated by deploy_flyspray.sh
# Copy to: /opt/bitnami/apache/htdocs/flyspray.conf.php
####################################################################

[database]
dbtype   = pgsql
host     = ${DB_ENDPOINT}
port     = ${DB_PORT}
dbname   = ${APP_DB}
dbprefix = flyspray_
dbuser   = ${APP_USER}
dbpass   = ${APP_PASSWORD}

[general]
base_url      = https://${APP_HOSTNAME}
attachmentdir = ./attachments
logfile       = ./flyspray.log

PHP
fi

# ---------------------------------------------------------------------------
# STEP 13 — Write setup_ssl.sh
# ---------------------------------------------------------------------------
if $RESUME && [[ -f "$OUTPUT_SSL_SCRIPT" ]]; then
  info "Step 13: $OUTPUT_SSL_SCRIPT already exists — skipping."
else
  log "Step 13: Writing $OUTPUT_SSL_SCRIPT"
  cat > "$OUTPUT_SSL_SCRIPT" <<SSLSCRIPT
#!/usr/bin/env bash
# Generated by deploy_flyspray.sh — run AFTER DNS A record is live.
# Verify: dig +short ${APP_HOSTNAME}  # should return: ${INSTANCE_IP}
set -euo pipefail

REGION="${REGION}"
INSTANCE_NAME="${INSTANCE_NAME}"
APP_HOSTNAME="${APP_HOSTNAME}"
SSL_EMAIL="${SSL_EMAIL}"
INSTANCE_IP="${INSTANCE_IP}"

echo "Verifying DNS for \$APP_HOSTNAME..."
RESOLVED=\$(dig +short "\$APP_HOSTNAME" | tail -1)
if [[ "\$RESOLVED" != "\$INSTANCE_IP" ]]; then
  echo "ERROR: \$APP_HOSTNAME -> '\$RESOLVED', expected '\$INSTANCE_IP'. Wait for DNS propagation."
  exit 1
fi
echo "DNS OK: \$APP_HOSTNAME -> \$INSTANCE_IP"

echo "Provisioning Let's Encrypt certificate..."
aws lightsail ssh \
  --instance-name "\$INSTANCE_NAME" \
  --region "\$REGION" \
  -- sudo /opt/bitnami/bncert-tool \
       --domain "\$APP_HOSTNAME" \
       --email  "\$SSL_EMAIL" \
       --enable-https \
       --enable-redirect \
       --agree-tos

echo "SSL provisioning complete. Visit https://\$APP_HOSTNAME"
SSLSCRIPT
  chmod +x "$OUTPUT_SSL_SCRIPT"
fi

# ---------------------------------------------------------------------------
# STEP 14 — Print summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Flyspray Lightsail deployment complete"
echo "============================================================"
echo "  Instance name      : $INSTANCE_NAME"
echo "  Static IP          : $INSTANCE_IP  (permanent — survives reboots)"
echo "  DB instance        : $DB_INSTANCE_NAME"
echo "  DB endpoint        : $DB_ENDPOINT:$DB_PORT"
echo "  App database       : $APP_DB"
echo "  App user           : $APP_USER"
echo "  App hostname       : $APP_HOSTNAME"
echo "  Instance snapshots : daily at ${INSTANCE_SNAPSHOT_TIME} UTC, 7-day retention"
echo "  DB backups         : daily at ${DB_BACKUP_WINDOW} UTC, 7-day retention"
echo ""
echo "  ---- NEXT STEPS (in order) ----"
echo ""
echo "  1. Create GoDaddy DNS A record:"
echo "       Name:  $(echo "$APP_HOSTNAME" | cut -d. -f1)"
echo "       Value: $INSTANCE_IP"
echo "       TTL:   600"
echo ""
echo "  2. SSH in and install Flyspray into the web root:"
echo "       aws lightsail ssh --instance-name $INSTANCE_NAME --region $REGION"
echo ""
echo "     On the instance:"
echo "       cd /opt/bitnami/apache/htdocs"
echo "       sudo wget https://github.com/flyspray/flyspray/releases/download/v1.0/flyspray-1.0.tar.gz"
echo "       sudo tar xzf flyspray-1.0.tar.gz"
echo "       sudo mv flyspray/* ."
echo "       sudo mv flyspray/.htaccess . 2>/dev/null || true"
echo "       sudo rm -rf flyspray flyspray-1.0.tar.gz"
echo ""
echo "  3. Copy flyspray.conf.php to the instance:"
echo "       scp $OUTPUT_CONF bitnami@$INSTANCE_IP:/tmp/"
echo "     On the instance:"
echo "       sudo mv /tmp/flyspray.conf.php /opt/bitnami/apache/htdocs/"
echo "       sudo chown -R bitnami:daemon /opt/bitnami/apache/htdocs"
echo "       sudo chmod -R 775 /opt/bitnami/apache/htdocs/attachments"
echo ""
echo "  4. Wait for DNS propagation:"
echo "       dig +short $APP_HOSTNAME   # should return: $INSTANCE_IP"
echo ""
echo "  5. Provision SSL:"
echo "       $OUTPUT_SSL_SCRIPT"
echo ""
echo "  6. Open https://$APP_HOSTNAME"
echo "============================================================"
