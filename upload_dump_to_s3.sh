#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: bash upload_dump_to_s3.sh LOCAL_SQL_FILE S3_BUCKET S3_KEY" >&2
  exit 2
fi
[[ -f "$1" && -r "$1" ]] || { echo "SQL dump is not a readable file." >&2; exit 1; }
command -v aws >/dev/null || { echo "AWS CLI is required." >&2; exit 1; }
aws s3 cp "$1" "s3://$2/$3" --sse AES256
echo "Upload complete. Set s3_bucket and s3_dump_key in Terraform configuration."