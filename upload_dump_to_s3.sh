#!/usr/bin/env bash
# =============================================================================
# upload_dump_to_s3.sh
#
# Pre-Terraform helper script:
# 1. Takes the path to a local PostgreSQL dump file.
# 2. Determines the AWS region (from AWS config or defaults to us-east-2).
# 3. Creates a secure, private S3 bucket if one doesn't already exist.
# 4. Uploads the SQL dump file to the bucket.
# 5. Automatically updates terraform/terraform.tfvars with the new
#    s3_bucket, s3_dump_key, and region.
#
# Usage:
#   ./upload_dump_to_s3.sh /path/to/flyspray_dump.sql
# Or run interactively:
#   ./upload_dump_to_s3.sh
# =============================================================================
set -euo pipefail

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
err()  { echo "[ERROR] $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
TFVARS_FILE="$REPO_ROOT/terraform/terraform.tfvars"

# If script is inside terraform/scripts, adjust path
if [[ ! -f "$TFVARS_FILE" && -f "$REPO_ROOT/../terraform.tfvars" ]]; then
  TFVARS_FILE="$REPO_ROOT/../terraform.tfvars"
elif [[ ! -f "$TFVARS_FILE" && -f "$REPO_ROOT/terraform.tfvars" ]]; then
  TFVARS_FILE="$REPO_ROOT/terraform.tfvars"
fi

# ---------------------------------------------------------------------------
# 1. Check prerequisites
# ---------------------------------------------------------------------------
command -v aws >/dev/null 2>&1 || err "'aws' CLI is required. Install via: brew install awscli"
command -v python3 >/dev/null 2>&1 || err "'python3' is required to update terraform.tfvars."

# ---------------------------------------------------------------------------
# 2. Resolve dump file path
# ---------------------------------------------------------------------------
SQL_PATH="${1:-}"

if [[ -z "$SQL_PATH" ]]; then
  echo "============================================================"
  echo "  Flyspray Database Dump S3 Staging Tool"
  echo "============================================================"
  read -r -p "Enter local path to Flyspray SQL dump file: " SQL_PATH
fi

# Expand tilde ~ if present
SQL_PATH="${SQL_PATH/#\~/$HOME}"

if [[ ! -f "$SQL_PATH" ]]; then
  err "SQL dump file not found at: '$SQL_PATH'"
fi

if [[ ! -s "$SQL_PATH" ]]; then
  err "SQL dump file is empty: '$SQL_PATH'"
fi

DUMP_KEY="$(basename "$SQL_PATH")"
FILE_SIZE=$(du -h "$SQL_PATH" | cut -f1)

log "Selected dump file: $SQL_PATH ($FILE_SIZE)"

# ---------------------------------------------------------------------------
# 3. Resolve AWS region & identity
# ---------------------------------------------------------------------------
log "Checking AWS credentials and region..."

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  err "AWS credentials not found or invalid. Run 'aws configure' before running this script."
fi

# Read region from AWS CLI config, fall back to us-east-2
CONFIG_REGION=$(aws configure get region 2>/dev/null || true)
REGION="${AWS_REGION:-${CONFIG_REGION:-us-east-2}}"

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null || true)
log "AWS Account ID    : $ACCOUNT_ID"
log "Target AWS Region : $REGION"

# ---------------------------------------------------------------------------
# 4. Resolve or generate S3 bucket name
# ---------------------------------------------------------------------------
# Use custom bucket name if provided via S3_BUCKET env var, else create a standard unique one
if [[ -n "${S3_BUCKET:-}" ]]; then
  BUCKET_NAME="$S3_BUCKET"
elif [[ -n "$ACCOUNT_ID" && "$ACCOUNT_ID" =~ ^[0-9]+$ ]]; then
  BUCKET_NAME="flyspray-db-dump-${ACCOUNT_ID}-${REGION}"
else
  RANDOM_HEX=$(openssl rand -hex 4 2>/dev/null || echo "$RANDOM")
  BUCKET_NAME="flyspray-db-dump-${RANDOM_HEX}-${REGION}"
fi

log "S3 Bucket name    : $BUCKET_NAME"

# ---------------------------------------------------------------------------
# 5. Create S3 Bucket (if it does not exist)
# ---------------------------------------------------------------------------
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  log "Bucket 's3://$BUCKET_NAME' already exists."
else
  log "Creating S3 bucket 's3://$BUCKET_NAME' in $REGION..."
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$REGION" >/dev/null
  else
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi

  # Block all public access (best security practice for database dumps)
  log "Enabling S3 Block Public Access..."
  aws s3api put-public-access-block \
    --bucket "$BUCKET_NAME" \
    --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >/dev/null || true

  # Enable default SSE-S3 encryption
  log "Enabling default AES-256 encryption on bucket..."
  aws s3api put-bucket-encryption \
    --bucket "$BUCKET_NAME" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null || true
fi

# ---------------------------------------------------------------------------
# 6. Upload dump file to S3
# ---------------------------------------------------------------------------
log "Uploading '$SQL_PATH' to 's3://$BUCKET_NAME/$DUMP_KEY'..."
aws s3 cp "$SQL_PATH" "s3://$BUCKET_NAME/$DUMP_KEY" --region "$REGION"
log "Upload successful!"

# ---------------------------------------------------------------------------
# 7. Update terraform.tfvars
# ---------------------------------------------------------------------------
if [[ -f "$TFVARS_FILE" ]]; then
  log "Updating $TFVARS_FILE..."

  python3 - <<EOF
import re

tfvars_path = "$TFVARS_FILE"
bucket = "$BUCKET_NAME"
dump_key = "$DUMP_KEY"
region = "$REGION"

with open(tfvars_path, "r") as f:
    content = f.read()

# Update region
content, count_region = re.subn(
    r'^(region\s*=\s*).*$',
    f'region      = "{region}"',
    content,
    flags=re.MULTILINE
)
if count_region == 0:
    content = f'region      = "{region}"\n' + content

# Update s3_bucket
content, count_bucket = re.subn(
    r'^(s3_bucket\s*=\s*).*$',
    f's3_bucket   = "{bucket}"',
    content,
    flags=re.MULTILINE
)
if count_bucket == 0:
    content += f'\ns3_bucket   = "{bucket}"\n'

# Update s3_dump_key
content, count_key = re.subn(
    r'^(s3_dump_key\s*=\s*).*$',
    f's3_dump_key = "{dump_key}"',
    content,
    flags=re.MULTILINE
)
if count_key == 0:
    content += f'\ns3_dump_key = "{dump_key}"\n'

with open(tfvars_path, "w") as f:
    f.write(content)

print(f"Successfully updated {tfvars_path}")
EOF

else
  echo "[WARNING] $TFVARS_FILE not found. Please set these manually in terraform.tfvars:"
  echo "  region      = \"$REGION\""
  echo "  s3_bucket   = \"$BUCKET_NAME\""
  echo "  s3_dump_key = \"$DUMP_KEY\""
fi

# ---------------------------------------------------------------------------
# 8. Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Flyspray Database Dump Staged Successfully!"
echo "============================================================"
echo "  Local File : $SQL_PATH ($FILE_SIZE)"
echo "  S3 URI     : s3://$BUCKET_NAME/$DUMP_KEY"
echo "  Region     : $REGION"
echo ""
echo "  Updated terraform.tfvars:"
echo "    region      = \"$REGION\""
echo "    s3_bucket   = \"$BUCKET_NAME\""
echo "    s3_dump_key = \"$DUMP_KEY\""
echo ""
echo "  Next Step:"
echo "    cd terraform"
echo "    terraform plan"
echo "============================================================"
