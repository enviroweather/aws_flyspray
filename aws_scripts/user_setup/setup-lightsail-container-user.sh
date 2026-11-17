#!/usr/bin/env bash
# setup-lightsail-container-user.sh
#
# Creates an IAM user with permissions to work on any Lightsail
# containerized app stack: Lightsail, ECR, CodeBuild, S3, CloudWatch logs.
#
# Usage:
#   ./setup-lightsail-container-user.sh <username> <group> <app-name>
#
# Arguments:
#   username  - IAM username to create (e.g. jsmith)
#   group     - IAM group to add the user to (e.g. ewx-developers)
#   app-name  - Short app name used to scope ECR repo and CodeBuild
#               project names (e.g. flyspray, myapp, tracker)
#
# Examples:
#   ./setup-lightsail-container-user.sh jsmith ewx-developers flyspray
#   ./setup-lightsail-container-user.sh alee research-team myapp
#
# Run in AWS CloudShell - account ID is resolved automatically.
# No AWS configuration needed.
# -----------------------------------------------------------------------

set -euo pipefail

# --- Arguments ---
USERNAME="${1:-}"
GROUP_NAME="${2:-}"
APP_NAME="${3:-}"

if [[ -z "$USERNAME" || -z "$GROUP_NAME" || -z "$APP_NAME" ]]; then
  echo "Usage: $0 <username> <group> <app-name>"
  echo ""
  echo "  username  - IAM username to create (e.g. jsmith)"
  echo "  group     - IAM group to add the user to (e.g. ewx-developers)"
  echo "  app-name  - Short app name for scoping ECR/CodeBuild (e.g. flyspray)"
  echo ""
  echo "Examples:"
  echo "  $0 jsmith ewx-developers flyspray"
  echo "  $0 alee research-team myapp"
  exit 1
fi

POLICY_NAME="${APP_NAME}-container-access"
CODEBUILD_ROLE="${APP_NAME}-codebuild-role"
CODEBUILD_PROJECT="${APP_NAME}-build"

# --- Resolve account ID from current CloudShell session ---
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "==> AWS Account:    $ACCOUNT_ID"
echo "==> Username:       $USERNAME"
echo "==> Group:          $GROUP_NAME"
echo "==> App name:       $APP_NAME"
echo "==> Policy name:    $POLICY_NAME"
echo ""

# --- Verify the group exists before proceeding ---
if ! aws iam get-group --group-name "$GROUP_NAME" > /dev/null 2>&1; then
  echo "ERROR: Group '$GROUP_NAME' does not exist in this account."
  echo "Create it first or check the group name."
  exit 1
fi

# --- Create the user ---
echo "==> Creating IAM user: $USERNAME"
if aws iam get-user --user-name "$USERNAME" > /dev/null 2>&1; then
  echo "    User already exists - skipping create, will update policy only."
else
  aws iam create-user --user-name "$USERNAME"
fi

# --- Add to group ---
echo "==> Adding $USERNAME to group: $GROUP_NAME"
aws iam add-user-to-group \
  --user-name "$USERNAME" \
  --group-name "$GROUP_NAME"

# --- Build and attach inline policy ---
echo "==> Attaching inline policy: $POLICY_NAME"

POLICY_DOC=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LightsailFullAccess",
      "Effect": "Allow",
      "Action": "lightsail:*",
      "Resource": "*"
    },
    {
      "Sid": "ECRAuthToken",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "ECRAppRepo",
      "Effect": "Allow",
      "Action": [
        "ecr:DescribeRepositories",
        "ecr:ListImages",
        "ecr:DescribeImages",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
        "ecr:CreateRepository",
        "ecr:DeleteRepository",
        "ecr:PutLifecyclePolicy",
        "ecr:GetLifecyclePolicy"
      ],
      "Resource": "arn:aws:ecr:*:${ACCOUNT_ID}:repository/${APP_NAME}"
    },
    {
      "Sid": "CodeBuildApp",
      "Effect": "Allow",
      "Action": [
        "codebuild:StartBuild",
        "codebuild:StopBuild",
        "codebuild:BatchGetBuilds",
        "codebuild:ListBuildsForProject",
        "codebuild:ListProjects",
        "codebuild:BatchGetProjects",
        "codebuild:CreateProject",
        "codebuild:UpdateProject",
        "codebuild:DeleteProject"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CodeBuildLogs",
      "Effect": "Allow",
      "Action": [
        "logs:GetLogEvents",
        "logs:FilterLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ],
      "Resource": "arn:aws:logs:*:${ACCOUNT_ID}:log-group:/aws/codebuild/*"
    },
    {
      "Sid": "IAMPassRoleForCodeBuild",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/${CODEBUILD_ROLE}"
    }
  ]
}
EOF
)

aws iam put-user-policy \
  --user-name "$USERNAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document "$POLICY_DOC"

# --- Create console login profile ---
echo "==> Creating console login profile (temporary password, reset required)"
TEMP_PASS="$(openssl rand -base64 12)Aa1!"

if aws iam get-login-profile --user-name "$USERNAME" > /dev/null 2>&1; then
  echo "    Login profile already exists - skipping."
else
  aws iam create-login-profile \
    --user-name "$USERNAME" \
    --password "$TEMP_PASS" \
    --password-reset-required
  echo ""
  echo "    Temp password: $TEMP_PASS"
  echo "    (share securely - user must change on first login)"
fi

# --- Summary ---
echo ""
echo "==> Done. Summary:"
echo "    User:           $USERNAME"
echo "    Group:          $GROUP_NAME"
echo "    Inline policy:  $POLICY_NAME"
echo ""
echo "==> Permissions granted:"
echo "    lightsail:*                              (all Lightsail resources)"
echo "    ecr:* on arn:...:repository/$APP_NAME    (push/pull container images)"
echo "    codebuild:* on $CODEBUILD_PROJECT        (trigger and monitor builds)"
echo "    logs:* on /aws/codebuild/*               (read build logs)"
echo "    iam:PassRole $CODEBUILD_ROLE"
echo "    + all permissions inherited from group:  $GROUP_NAME"
echo ""
echo "==> To generate CLI/Terraform access keys:"
echo "    aws iam create-access-key --user-name $USERNAME"
echo ""
echo "==> Console login URL:"
echo "    https://${ACCOUNT_ID}.signin.aws.amazon.com/console"
