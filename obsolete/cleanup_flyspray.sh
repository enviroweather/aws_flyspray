#!/usr/bin/env bash
# =============================================================================
# cleanup_flyspray.sh
#
# Deletes all Lightsail resources created by deploy_flyspray.sh.
# Uses the same FLYSPRAY_* environment variables and positional arguments
# as the deploy script so you can run both with the same shell session.
#
# Variable resolution order (same as deploy script):
#   1. CLI positional arguments  ($1 = INSTANCE_NAME)
#   2. Environment variables     (FLYSPRAY_*)
#   3. Defaults
#   4. Derived values            (STATIC_IP_NAME from INSTANCE_NAME)
#
# Usage examples:
#
#   # Uses defaults (removes flyspray-app, flyspray-db, flyspray-app-static-ip)
#   ./cleanup_flyspray.sh
#
#   # Remove a named dev/test deployment
#   ./cleanup_flyspray.sh flyspray-dev
#
#   # Using env var
#   export FLYSPRAY_INSTANCE_NAME="flyspray-dev"
#   ./cleanup_flyspray.sh
#
# What this script removes:
#   - Lightsail instance
#   - Lightsail static IP (detached first, then released)
#   - Lightsail managed PostgreSQL database
#   - Local files written by the deploy script (/tmp/flyspray.conf.php,
#     /tmp/setup_ssl.sh, /tmp/flyspray_dump.sql)
#
# What this script does NOT remove:
#   - S3 objects (the source dump is left untouched)
#   - Any manual snapshots you created outside the deploy script
#   - Automatic snapshots (deleted automatically when the resource is deleted)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
err()  { echo "[ERROR] $*" >&2; exit 1; }

# safe_delete SERVICE DESCRIPTION CMD...
# Runs a deletion command and treats 'NotFoundException' as success
# (resource was already gone — idempotent cleanup).
safe_delete() {
  local service="$1"
  local description="$2"
  shift 2
  log "Deleting $description..."
  if OUTPUT=$("$@" 2>&1); then
    log "  OK: $description deleted."
  else
    if echo "$OUTPUT" | grep -qiE 'NotFoundException|does not exist|not found|InvalidInputException'; then
      log "  SKIP: $description not found (already deleted or never created)."
    else
      echo "  WARNING: unexpected error deleting $description:"
      echo "  $OUTPUT"
      # Continue — don't abort cleanup because one resource failed
    fi
  fi
}

# ---------------------------------------------------------------------------
# REGION — from AWS CLI config, fallback to us-east-1
# ---------------------------------------------------------------------------
REGION=$(aws configure get region 2>/dev/null || echo "")
REGION=${REGION:-us-east-1}
log "Using region: $REGION"

# ---------------------------------------------------------------------------
# POSITIONAL ARGUMENTS
#   $1 = INSTANCE_NAME
# ---------------------------------------------------------------------------
CLI_INSTANCE_NAME="${1:-}"

# ---------------------------------------------------------------------------
# VARIABLE RESOLUTION (mirrors deploy script)
# ---------------------------------------------------------------------------
INSTANCE_NAME="${CLI_INSTANCE_NAME:-${FLYSPRAY_INSTANCE_NAME:-flyspray-app}}"
STATIC_IP_NAME="${INSTANCE_NAME}-static-ip"
DB_INSTANCE_NAME="${FLYSPRAY_DB_NAME:-flyspray-db}"

# Local files written by the deploy script
LOCAL_DUMP="/tmp/flyspray_dump.sql"
OUTPUT_CONF="/tmp/flyspray.conf.php"
OUTPUT_SSL_SCRIPT="/tmp/setup_ssl.sh"

# ---------------------------------------------------------------------------
# PRE-FLIGHT — show what will be deleted and confirm
# ---------------------------------------------------------------------------
echo ""
echo "  ================================================================"
echo "  WARNING: This will permanently delete the following resources:"
echo "  ================================================================"
echo "  Region       : $REGION"
echo "  Instance     : $INSTANCE_NAME"
echo "  Static IP    : $STATIC_IP_NAME"
echo "  Database     : $DB_INSTANCE_NAME"
echo ""
echo "  Local files  : $LOCAL_DUMP"
echo "                 $OUTPUT_CONF"
echo "                 $OUTPUT_SSL_SCRIPT"
echo ""
echo "  Automatic snapshots are deleted along with their parent resource."
echo "  The S3 dump and any manual snapshots are NOT affected."
echo "  ================================================================"
echo ""
read -r -p "Type 'yes' to confirm deletion: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted — nothing was deleted."; exit 0; }
echo ""

# ---------------------------------------------------------------------------
# STEP 1 — Detach and release the static IP
#           Must be detached before the instance is deleted, otherwise
#           the IP lingers as an unattached (billable) resource.
# ---------------------------------------------------------------------------
safe_delete "lightsail" "static IP attachment ($STATIC_IP_NAME)" \
  aws lightsail detach-static-ip \
    --static-ip-name "$STATIC_IP_NAME" \
    --region "$REGION" \
    --output text

safe_delete "lightsail" "static IP ($STATIC_IP_NAME)" \
  aws lightsail release-static-ip \
    --static-ip-name "$STATIC_IP_NAME" \
    --region "$REGION" \
    --output text

# ---------------------------------------------------------------------------
# STEP 2 — Delete the Lightsail instance
# ---------------------------------------------------------------------------
safe_delete "lightsail" "instance ($INSTANCE_NAME)" \
  aws lightsail delete-instance \
    --instance-name "$INSTANCE_NAME" \
    --force-delete-add-ons \
    --region "$REGION" \
    --output text

# ---------------------------------------------------------------------------
# STEP 3 — Delete the managed PostgreSQL database
#           --skip-final-snapshot avoids creating a billable snapshot on
#           deletion. Remove this flag if you want a final backup kept.
# ---------------------------------------------------------------------------
safe_delete "lightsail" "database ($DB_INSTANCE_NAME)" \
  aws lightsail delete-relational-database \
    --relational-database-name "$DB_INSTANCE_NAME" \
    --skip-final-snapshot \
    --region "$REGION" \
    --output text

# ---------------------------------------------------------------------------
# STEP 4 — Remove local files written by the deploy script
# ---------------------------------------------------------------------------
log "Removing local deploy artefacts..."
for f in "$LOCAL_DUMP" "$OUTPUT_CONF" "$OUTPUT_SSL_SCRIPT"; do
  if [[ -f "$f" ]]; then
    rm -f "$f"
    log "  Removed: $f"
  else
    log "  SKIP: $f not found."
  fi
done

# ---------------------------------------------------------------------------
# STEP 5 — Wait for instance and DB deletion to complete
#           (Lightsail deletions are async — useful to confirm before
#            re-deploying to the same names.)
# ---------------------------------------------------------------------------
log "Waiting for instance '$INSTANCE_NAME' to be fully deleted..."
while true; do
  STATE=$(aws lightsail get-instance \
    --instance-name "$INSTANCE_NAME" \
    --region "$REGION" \
    --query 'instance.state.name' \
    --output text 2>&1 || echo "NotFoundException")
  if echo "$STATE" | grep -qiE 'NotFoundException|not found'; then
    log "  Instance deleted."
    break
  fi
  log "  Instance state: $STATE — waiting..."
  sleep 10
done

log "Waiting for database '$DB_INSTANCE_NAME' to be fully deleted..."
while true; do
  STATE=$(aws lightsail get-relational-database \
    --relational-database-name "$DB_INSTANCE_NAME" \
    --region "$REGION" \
    --query 'relationalDatabase.state' \
    --output text 2>&1 || echo "NotFoundException")
  if echo "$STATE" | grep -qiE 'NotFoundException|not found'; then
    log "  Database deleted."
    break
  fi
  log "  DB state: $STATE — waiting..."
  sleep 15
done

# ---------------------------------------------------------------------------
# DONE
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Cleanup complete"
echo "============================================================"
echo "  Deleted instance : $INSTANCE_NAME"
echo "  Deleted static IP: $STATIC_IP_NAME"
echo "  Deleted database : $DB_INSTANCE_NAME"
echo "  Region           : $REGION"
echo ""
echo "  You can now re-run deploy_flyspray.sh with the same names."
echo "============================================================"
