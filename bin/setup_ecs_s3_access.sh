#!/usr/bin/env bash
# -*- mode: bash; -*-

set -euo pipefail

########################################################################
usage() {
########################################################################
  cat <<EOF
Usage: $0 --bucket BUCKET --task-def-arn ECS_TASK_ARN --role-name ROLE_NAME --profile AWS_PROFILE

Arguments:
  --bucket         S3 bucket name to grant access to
  --task-def-arn   ARN of the ECS task definition to update
  --role-name      Name for the new IAM role to create
  --profile        AWS CLI profile to use
EOF
  exit 1
}

# --- Parse arguments ---
TEMP=$(getopt -o '' --long bucket:,task-def-arn:,role-name:,profile: -n "$0" -- "$@")
eval set -- "$TEMP"

bucket=""
task_def_arn=""
role_name=""
profile=""

while true; do
  case "$1" in
    --bucket)         bucket="$2"; shift 2 ;;
    --task-def-arn)   task_def_arn="$2"; shift 2 ;;
    --role-name)      role_name="$2"; shift 2 ;;
    --profile)        profile="$2"; shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done

if [[ -n "$profile" ]]; then
  profile="--profile $profile"
fi

if [[ -z "$bucket" || -z "$task_def_arn" || -z "$role_name" ]]; then
  usage
fi

# --- Step 1: Create trust policy for ECS tasks ---
trust_policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ecs-tasks.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)

aws iam create-role \
  --role-name "$role_name" \
  --assume-role-policy-document "$trust_policy" $profile

echo "Created IAM role: $role_name"

# --- Step 2: Attach S3 access policy to the role ---
s3_policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowS3AccessToBucket",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::$bucket",
        "arn:aws:s3:::$bucket/*"
      ]
    }
  ]
}
EOF
)

aws iam put-role-policy \
  --role-name "$role_name" \
  --policy-name "${role_name}_S3Policy" \
  --policy-document "$s3_policy" \
  $profile

echo "Attached inline S3 policy to role: $role_name"

# --- Step 3: Get latest task definition revision and update it with new role ---
task_family=$(aws ecs describe-task-definition \
  --task-definition "$task_def_arn" $profile \
  --query "taskDefinition.family" \
  --output text)

task_def_json=$(aws ecs describe-task-definition \
  --task-definition "$task_def_arn" $profile \
  --query "taskDefinition" \
  --output json)

new_def=$(echo "$task_def_json" | jq \
  --arg role_arn "arn:aws:iam::$(aws sts get-caller-identity $profile --query Account --output text):role/$role_name" \
  '.taskRoleArn = $role_arn | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)')

aws ecs register-task-definition \
  --cli-input-json "$new_def" $profile

echo "Registered new task definition revision with IAM role: $role_name"
