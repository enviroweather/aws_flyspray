#!/usr/bin/env bash
# update-lightsail-container-policy.sh
#
# Updates (or adds) the container access inline policy on an EXISTING user.
# Safe to re-run - uses put-user-policy which creates or replaces.
#
# Usage:
#   ./update-lightsail-container-policy.sh <username> <app-name>
#
# Arguments:
#   username  - existing IAM username (e.g. billspat-ewx)
#   app-name  - short app name matching your ECR repo and CodeBuild project
#               (e.g. flyspray, myapp)
#
# Examples:
#   ./update-lightsail-container-policy.sh billspat-ewx flyspray
#   ./update-lightsail-container-policy.sh alee myapp
#
# Run in AWS CloudShell - account ID is resolved automatically.
# -----------------------------------------------------------------------

set -euo pipefail

USERNAME="${1:-}"
APP_NAME="${2:-}"

if [[ -z "$USERNAME" || -z "$APP_NAME" ]]; then
  echo "Usage: $0 <username> <app-name>"
  echo ""
  echo "  username  - existing IAM username (e.g. billspat-ewx)"
  echo "  app-name  - short app name for ECR/CodeBuild scoping (e.g. flyspray)"
  echo ""
  echo "Examples:"
  echo "  $0 billspat-ewx flyspray"
  echo "  $0 alee myapp"
  exit 1
fi

POLICY_NAME="${APP_NAME}-container-access"
CODEBUILD_ROLE="${APP_NAME}-containers-codebuild"

# --- Resolve account ID from current CloudShell session ---
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "==> AWS Account:  $ACCOUNT_ID"
echo "==> Username:     $USERNAME"
echo "==> App name:     $APP_NAME"
echo "==> Policy name:  $POLICY_NAME"
echo ""

# --- Verify user exists ---
if ! aws iam get-user --user-name "$USERNAME" > /dev/null 2>&1; then
  echo "ERROR: User '$USERNAME' does not exist."
  echo "To create a new user, use setup-lightsail-container-user.sh instead."
  exit 1
fi

echo "==> Updating inline policy: $POLICY_NAME"

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
      "Resource": "arn:aws:ecr:*:${ACCOUNT_ID}:repository/${APP_NAME}*"
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
      "Resource": "arn:aws:codebuild:*:${ACCOUNT_ID}:project/${APP_NAME}*"
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
      "Sid": "IAMManageAppRoles",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:TagRole",
        "iam:PassRole"
      ],
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/${APP_NAME}-*"
    }
  ]
}
EOF
)

aws iam put-user-policy \
  --user-name "$USERNAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document "$POLICY_DOC"

echo ""
echo "==> Done. Policy '$POLICY_NAME' applied to: $USERNAME"
echo ""
echo "==> Permissions granted:"
echo "    lightsail:*                                          (all Lightsail resources)"
echo "    ecr:* on repository/${APP_NAME}*                    (manage ECR repos and images)"
echo "    codebuild:* on project/${APP_NAME}*                 (manage CodeBuild projects)"
echo "    logs:* on /aws/codebuild/*                          (read build logs)"
echo "    iam:CreateRole/DeleteRole/etc on role/${APP_NAME}-* (manage app IAM roles)"
echo "    iam:PassRole on role/${CODEBUILD_ROLE}"
echo ""
echo "==> Verify with:"
echo "    aws iam get-user-policy --user-name $USERNAME --policy-name $POLICY_NAME"
echo ""
echo "==> View all policies on this user:"
echo "    aws iam list-user-policies --user-name $USERNAME"
echo "    aws iam list-attached-user-policies --user-name $USERNAME"
echo "    aws iam list-groups-for-user --user-name $USERNAME"
