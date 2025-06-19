#!/usr/bin/env bash
# -*- mode: bash -*-
#
# Usage: ./apply_private_policy_and_lifecycle.sh my-bucket-name my-profile
#

set -euo pipefail

bucket="$1"
profile="$2"

if [[ -z "$bucket" ]]; then
    echo >&2 "ERROR: usage bucket-name [profile]"
    exit 1
fi
if [[ -n "$profile" ]]; then
  profile="--profile $profile"
fi

# Get the canonical user ID for the current profile
owner_id=$(aws s3api list-buckets --query "Owner.ID" --output text $profile)

# Create a bucket policy allowing only the bucket owner full access
policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowBucketOwnerFullAccess",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${owner_id}:root"
      },
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::$bucket",
        "arn:aws:s3:::$bucket/*"
      ]
    }
  ]
}
EOF
)

aws s3api put-bucket-policy \
  --bucket "$bucket"  $profile \
  --profile "$profile" \

echo "Private bucket policy applied to $bucket."

# Add lifecycle rule to expire objects after 1 day
lifecycle=$(cat <<EOF
{
  "Rules": [
    {
      "ID": "ExpireObjectsAfter1Day",
      "Status": "Enabled",
      "Prefix": "",
      "Expiration": {
        "Days": 1
      }
    }
  ]
}
EOF
)

aws s3api put-bucket-lifecycle-configuration \
  --bucket "$bucket" \
  --profile "$profile" \
  --lifecycle-configuration "$lifecycle"

echo "Lifecycle rule applied to $bucket: Expire all objects after 1 day."
