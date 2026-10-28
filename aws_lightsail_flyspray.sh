#!/usr/bin/env bash
# =============================================================================
# deploy_flyspray.sh  (v4 — final)
# Provisions a Lightsail instance + managed PostgreSQL DB for Flyspray,
# allocates and attaches a static IP, enables automatic snapshots,
# imports the SQL dump from S3, creates an app DB/user, and writes
# flyspray.conf.php and setup_ssl.sh.
#
# Prerequisites (on the machine running this script):
#   - AWS CLI v2, configured with credentials that can manage Lightsail + S3
#   - psql client  (apt install postgresql-client  /  brew install libpq)
#
# set the following or edit to use command line params
# APP_HOSTNAME          flyspray.yourdomain.com
# SSL_EMAIL             you@yourdomain.com
# DB_MASTER_PASSWORD    Ch@ngeMe_Master1
# APP_PASSWORD          Ch@ngeMe_App1
#
# Usage:
#   chmod +x deploy_flyspray.sh
#   ./deploy_flyspray.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION  — edit these before running
# ---------------------------------------------------------------------------
REGION="us-east-1"
LIGHTSAIL_AZ="us-east-1a"                        # Lightsail LIGHTSAIL_AZ — must match region

# --- Instance ---
INSTANCE_NAME="flyspray-app"
INSTANCE_BLUEPRINT="lamp_8_bitnami"    # LAMP PHP 8 (Apache + PHP pre-installed)
INSTANCE_BUNDLE="micro_3_0"            # $7/mo · 1 GB RAM · 40 GB disk

# --- Static IP ---
STATIC_IP_NAME="flyspray-static-ip"

# --- Custom subdomain ---
APP_HOSTNAME="flyspray.yourdomain.com" # ← CHANGE THIS
SSL_EMAIL="you@yourdomain.com"         # ← CHANGE THIS (Let's Encrypt alerts)

# --- Snapshot schedule (UTC) ---
INSTANCE_SNAPSHOT_TIME="02:00"         # Daily instance snapshot time (UTC)
DB_BACKUP_WINDOW="03:00-03:30"         # DB backup window (UTC, 30-min slot)

# --- Managed PostgreSQL database ---
DB_INSTANCE_NAME="flyspray-db"
DB_BUNDLE="micro_2_0"                  # $15/mo · 1 GB RAM · 40 GB
DB_BLUEPRINT="postgres_16"             # PostgreSQL 16
DB_MASTER_USER="dbmaster"
DB_MASTER_PASSWORD="Ch@ngeMe_Master1"  # ← CHANGE THIS
DB_INITIAL_NAME="postgres"

# --- Application DB / user ---
APP_DB="flyspray"
APP_USER="flyspray_user"
APP_PASSWORD="Ch@ngeMe_App1"           # ← CHANGE THIS

# --- S3 dump source ---
S3_BUCKET="ewx-flyspray-941061635635-us-east-1-an"
S3_DUMP_KEY="flyspray_22_10_2026.sql"
LOCAL_DUMP="/tmp/flyspray_dump.sql"

# --- Output paths (local) ---
OUTPUT_CONF="/tmp/flyspray.conf.php"
OUTPUT_SSL_SCRIPT="/tmp/setup_ssl.sh"

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%H:%M:%S')] $*"; }

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

# ---------------------------------------------------------------------------
# STEP 1 — Create the Lightsail managed PostgreSQL database
# ---------------------------------------------------------------------------
log "Creating Lightsail managed PostgreSQL database: $DB_INSTANCE_NAME"
aws lightsail create-relational-database \
  --relational-database-name "$DB_INSTANCE_NAME" \
  --availability-zone "$LIGHTSAIL_AZ" \
  --relational-database-blueprint-id "$DB_BLUEPRINT" \
  --relational-database-bundle-id "$DB_BUNDLE" \
  --master-database-name "$DB_INITIAL_NAME" \
  --master-username "$DB_MASTER_USER" \
  --master-user-password "$DB_MASTER_PASSWORD" \
  --no-publicly-accessible \
  --region "$REGION" \
  --output text > /dev/null

# ---------------------------------------------------------------------------
# STEP 2 — Create the Lightsail instance (LAMP PHP 8)
# ---------------------------------------------------------------------------
log "Creating Lightsail instance: $INSTANCE_NAME"
aws lightsail create-instances \
  --instance-names "$INSTANCE_NAME" \
  --availability-zone "$LIGHTSAIL_AZ" \
  --blueprint-id "$INSTANCE_BLUEPRINT" \
  --bundle-id "$INSTANCE_BUNDLE" \
  --region "$REGION" \
  --output text > /dev/null

# ---------------------------------------------------------------------------
# STEP 3 — Open HTTP and HTTPS firewall ports
#           HTTP (80) is required for the Let's Encrypt domain challenge.
#           HTTPS (443) for normal access after SSL is provisioned.
# ---------------------------------------------------------------------------
log "Opening HTTP (80) and HTTPS (443) on instance firewall"
aws lightsail open-instance-public-ports \
  --instance-name "$INSTANCE_NAME" \
  --port-info fromPort=80,toPort=80,protocol=TCP \
  --region "$REGION" --output text > /dev/null
aws lightsail open-instance-public-ports \
  --instance-name "$INSTANCE_NAME" \
  --port-info fromPort=443,toPort=443,protocol=TCP \
  --region "$REGION" --output text > /dev/null

# ---------------------------------------------------------------------------
# STEP 4 — Wait for both resources to be ready
# ---------------------------------------------------------------------------
wait_for_instance "$INSTANCE_NAME"
wait_for_db      "$DB_INSTANCE_NAME"

# ---------------------------------------------------------------------------
# STEP 5 — Allocate a static IP and attach it to the instance
# ---------------------------------------------------------------------------
log "Allocating static IP: $STATIC_IP_NAME"
aws lightsail allocate-static-ip \
  --static-ip-name "$STATIC_IP_NAME" \
  --region "$REGION" \
  --output text > /dev/null

log "Attaching static IP '$STATIC_IP_NAME' to instance '$INSTANCE_NAME'"
aws lightsail attach-static-ip \
  --static-ip-name "$STATIC_IP_NAME" \
  --instance-name "$INSTANCE_NAME" \
  --region "$REGION" \
  --output text > /dev/null

INSTANCE_IP=$(aws lightsail get-static-ip \
  --static-ip-name "$STATIC_IP_NAME" \
  --region "$REGION" \
  --query 'staticIp.ipAddress' \
  --output text)
log "Static IP assigned: $INSTANCE_IP"

# ---------------------------------------------------------------------------
# STEP 6 — Enable automatic snapshots
#           Instance: daily snapshot at $INSTANCE_SNAPSHOT_TIME UTC, 7-day retention.
#           Database: daily backup in $DB_BACKUP_WINDOW UTC window, 7-day retention.
#           Staggered 1 hour apart to avoid I/O overlap.
# ---------------------------------------------------------------------------
log "Enabling automatic daily snapshot on instance (${INSTANCE_SNAPSHOT_TIME} UTC)..."
aws lightsail enable-add-on \
  --resource-name "$INSTANCE_NAME" \
  --add-on-request "addOnType=AutoSnapshot,autoSnapshotAddOnRequest={snapshotTimeOfDay=${INSTANCE_SNAPSHOT_TIME}}" \
  --region "$REGION" \
  --output text > /dev/null

log "Enabling automatic backups on database (window: ${DB_BACKUP_WINDOW} UTC)..."
aws lightsail update-relational-database \
  --relational-database-name "$DB_INSTANCE_NAME" \
  --preferred-backup-window "$DB_BACKUP_WINDOW" \
  --backup-retention-enabled \
  --region "$REGION" \
  --output text > /dev/null

# ---------------------------------------------------------------------------
# STEP 7 — Retrieve the DB endpoint
# ---------------------------------------------------------------------------
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
log "Enabling public endpoint on DB for import..."
aws lightsail update-relational-database \
  --relational-database-name "$DB_INSTANCE_NAME" \
  --publicly-accessible \
  --region "$REGION" --output text > /dev/null
wait_for_db "$DB_INSTANCE_NAME"

# ---------------------------------------------------------------------------
# STEP 9 — Download the SQL dump from S3
# ---------------------------------------------------------------------------
log "Downloading dump from s3://$S3_BUCKET/$S3_DUMP_KEY"
aws s3 cp "s3://$S3_BUCKET/$S3_DUMP_KEY" "$LOCAL_DUMP" --region "$REGION"

# ---------------------------------------------------------------------------
# STEP 10 — Prepare PostgreSQL, create app DB/user, import dump
# ---------------------------------------------------------------------------
export PGPASSWORD="$DB_MASTER_PASSWORD"

log "Granting public schema privileges (required for PG15+)..."
psql -h "$DB_ENDPOINT" -p "$DB_PORT" -U "$DB_MASTER_USER" -d "$DB_INITIAL_NAME" <<SQL
GRANT ALL ON SCHEMA public TO "$DB_MASTER_USER";
SQL

log "Creating application database '$APP_DB' and user '$APP_USER'..."
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

log "Granting public schema privileges on app database..."
psql -h "$DB_ENDPOINT" -p "$DB_PORT" -U "$DB_MASTER_USER" -d "$APP_DB" <<SQL
GRANT ALL ON SCHEMA public TO "$DB_MASTER_USER";
GRANT USAGE, CREATE ON SCHEMA public TO "$APP_USER";
SQL

log "Importing SQL dump into '$APP_DB'..."
psql -h "$DB_ENDPOINT" -p "$DB_PORT" -U "$DB_MASTER_USER" -d "$APP_DB" \
  --single-transaction \
  -v ON_ERROR_STOP=0 \
  -f "$LOCAL_DUMP"

log "Granting app user access to all imported tables..."
psql -h "$DB_ENDPOINT" -p "$DB_PORT" -U "$DB_MASTER_USER" -d "$APP_DB" <<SQL
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO "$APP_USER";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "$APP_USER";
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO "$APP_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON TABLES    TO "$APP_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON SEQUENCES TO "$APP_USER";
SQL

unset PGPASSWORD

# ---------------------------------------------------------------------------
# STEP 11 — Disable public DB access
# ---------------------------------------------------------------------------
log "Disabling public endpoint on DB..."
aws lightsail update-relational-database \
  --relational-database-name "$DB_INSTANCE_NAME" \
  --no-publicly-accessible \
  --region "$REGION" --output text > /dev/null

# ---------------------------------------------------------------------------
# STEP 12 — Write flyspray.conf.php
# ---------------------------------------------------------------------------
log "Writing $OUTPUT_CONF"
cat > "$OUTPUT_CONF" <<PHP
<?php
####################################################################
# Flyspray configuration file
# Generated by deploy_flyspray.sh
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
log "flyspray.conf.php written to $OUTPUT_CONF"

# ---------------------------------------------------------------------------
# STEP 13 — Write setup_ssl.sh
# ---------------------------------------------------------------------------
log "Writing $OUTPUT_SSL_SCRIPT"
cat > "$OUTPUT_SSL_SCRIPT" <<SSLSCRIPT
#!/usr/bin/env bash
# =============================================================================
# setup_ssl.sh
# Run this AFTER your GoDaddy A record is pointing at the static IP
# and DNS has propagated.
#
# Verify DNS first:
#   dig +short ${APP_HOSTNAME}
#   # should return: ${INSTANCE_IP}
#
# Then run:
#   chmod +x setup_ssl.sh
#   ./setup_ssl.sh
# =============================================================================
set -euo pipefail

REGION="${REGION}"
INSTANCE_NAME="${INSTANCE_NAME}"
STATIC_IP_NAME="${STATIC_IP_NAME}"
APP_HOSTNAME="${APP_HOSTNAME}"
SSL_EMAIL="${SSL_EMAIL}"
INSTANCE_IP="${INSTANCE_IP}"

echo "Verifying DNS resolution for \$APP_HOSTNAME..."
RESOLVED=\$(dig +short "\$APP_HOSTNAME" | tail -1)
if [[ "\$RESOLVED" != "\$INSTANCE_IP" ]]; then
  echo "ERROR: \$APP_HOSTNAME resolves to '\$RESOLVED', expected '\$INSTANCE_IP'"
  echo "Wait for DNS propagation and try again."
  exit 1
fi
echo "DNS OK: \$APP_HOSTNAME -> \$INSTANCE_IP"

echo "Provisioning Let's Encrypt certificate via Bitnami bncert-tool..."
aws lightsail ssh \
  --instance-name "\$INSTANCE_NAME" \
  --region "\$REGION" \
  -- sudo /opt/bitnami/bncert-tool \
       --domain "\$APP_HOSTNAME" \
       --email  "\$SSL_EMAIL" \
       --enable-https \
       --enable-redirect \
       --agree-tos

echo ""
echo "SSL provisioning complete."
echo "Visit https://\$APP_HOSTNAME to confirm."
SSLSCRIPT

chmod +x "$OUTPUT_SSL_SCRIPT"
log "setup_ssl.sh written to $OUTPUT_SSL_SCRIPT"

# ---------------------------------------------------------------------------
# STEP 14 — Print summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Flyspray Lightsail deployment complete"
echo "============================================================"
echo "  Instance name      : $INSTANCE_NAME"
echo "  Static IP          : $INSTANCE_IP  (permanent — survives reboots)"
echo "  Static IP name     : $STATIC_IP_NAME"
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
echo "       Name:  $(echo $APP_HOSTNAME | cut -d. -f1)"
echo "       Value: $INSTANCE_IP"
echo "       TTL:   600"
echo ""
echo "  2. SSH into the instance and install Flyspray into the web root:"
echo "       aws lightsail ssh --instance-name $INSTANCE_NAME --region $REGION"
echo ""
echo "     On the instance run:"
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
echo ""
echo "  4. Fix permissions on the instance:"
echo "       sudo chown -R bitnami:daemon /opt/bitnami/apache/htdocs"
echo "       sudo chmod -R 775 /opt/bitnami/apache/htdocs/attachments"
echo ""
echo "  5. Wait for DNS to propagate, then verify:"
echo "       dig +short $APP_HOSTNAME"
echo "       # should return: $INSTANCE_IP"
echo ""
echo "  6. Provision the free SSL certificate:"
echo "       $OUTPUT_SSL_SCRIPT"
echo ""
echo "  7. Open https://$APP_HOSTNAME in your browser"
echo ""
echo "  Snapshot commands for reference:"
echo "    List instance snapshots:"
echo "      aws lightsail get-auto-snapshots --resource-name $INSTANCE_NAME --region $REGION"
echo "    List DB snapshots:"
echo "      aws lightsail get-relational-database-snapshots --relational-database-name $DB_INSTANCE_NAME --region $REGION"
echo "============================================================"

