#!/bin/sh
# Creates the bucket, its policy and the user scoped to it, through rustfs's S3 and admin APIs
# signed with the root credential. Each call creates or replaces, so a rerun undoes drift.
set -eu

endpoint=http://rustfs:9000
bucket=$BUCKET
admin="$(cat /admin/access-key):$(cat /admin/secret-key)"
access_key=$(cat /scoped/access-key)
secret_key=$(cat /scoped/secret-key)

call() {
  curl --silent --show-error --fail-with-body --aws-sigv4 aws:amz:us-east-1:s3 --user "$admin" "$@"
  echo
}

# rustfs may still be starting.
tries=0
until curl --silent --fail --output /dev/null "$endpoint/health/ready"; do
  tries=$((tries + 1))
  [ "$tries" -lt 60 ] || { echo "rustfs is not ready" >&2; exit 1; }
  sleep 5
done

call --request PUT "$endpoint/$bucket"
call --request PUT "$endpoint/rustfs/admin/v3/add-canned-policy?name=$bucket" --data-binary @- <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:*"],
      "Resource": ["arn:aws:s3:::$bucket", "arn:aws:s3:::$bucket/*"]
    }
  ]
}
EOF
call --request PUT "$endpoint/rustfs/admin/v3/add-user?accessKey=$access_key" \
  --header 'Content-Type: application/json' --data-binary @- <<EOF
{"secretKey": "$secret_key", "status": "enabled"}
EOF
call --request PUT \
  "$endpoint/rustfs/admin/v3/set-user-or-group-policy?policyName=$bucket&userOrGroup=$access_key&isGroup=false"
echo "bucket $bucket and its user $access_key are set up"
