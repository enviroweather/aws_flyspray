#!/usr/bin/env bash
# Triggers the CodeBuild project and waits for it to finish. Builds happen on
# an AWS-managed x86_64 host, so this requires only Terraform and the AWS CLI
# — no local Docker install, regardless of workstation architecture.
set -euo pipefail

for executable in terraform aws; do
  command -v "$executable" >/dev/null || { echo "Missing required command: $executable" >&2; exit 1; }
done

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
terraform_dir=$(cd "$script_dir/.." && pwd)
project=$(terraform -chdir="$terraform_dir" output -raw codebuild_project_name)
region=$(terraform -chdir="$terraform_dir" output -raw region)

build_id=$(aws codebuild start-build --project-name "$project" --region "$region" \
  --query 'build.id' --output text)
echo "Started build: $build_id"

status="IN_PROGRESS"
while [[ "$status" == "IN_PROGRESS" ]]; do
  sleep 15
  status=$(aws codebuild batch-get-builds --ids "$build_id" --region "$region" \
    --query 'builds[0].buildStatus' --output text)
  echo "Status: $status"
done

if [[ "$status" != "SUCCEEDED" ]]; then
  echo "Build did not succeed. Log group/stream:" >&2
  aws codebuild batch-get-builds --ids "$build_id" --region "$region" \
    --query 'builds[0].logs.{group:groupName,stream:streamName}' >&2
  exit 1
fi

echo "Build succeeded. Deploy it with:"
echo "  terraform apply -var deploy_flyspray=true"
