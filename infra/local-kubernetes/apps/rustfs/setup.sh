#!/bin/sh
# Creates the buckets, their policies and the users scoped to them, through rustfs's S3 and admin
# APIs signed with the root credential. Each call creates or replaces, so a rerun undoes drift.
# Each user's keys are in /users/<user>/access-key and secret-key.
set -eu

# rustfs serves TLS under this name; the Job's hostAliases pin it to rustfs's ClusterIP.
endpoint=https://s3.kube.kalski.xyz:9000
admin="$(cat /admin/access-key):$(cat /admin/secret-key)"

call() {
  curl --silent --show-error --fail-with-body --aws-sigv4 aws:amz:us-east-1:s3 --user "$admin" "$@"
  echo
}

# Reads the policy document from stdin.
policy() {
  call --request PUT "$endpoint/rustfs/admin/v3/add-canned-policy?name=$1" --data-binary @-
}

# user <user> <policy>
user() {
  access_key=$(cat "/users/$1/access-key")
  secret_key=$(cat "/users/$1/secret-key")
  call --request PUT "$endpoint/rustfs/admin/v3/add-user?accessKey=$access_key" \
    --header 'Content-Type: application/json' --data-binary @- <<EOF
{"secretKey": "$secret_key", "status": "enabled"}
EOF
  call --request PUT \
    "$endpoint/rustfs/admin/v3/set-user-or-group-policy?policyName=$2&userOrGroup=$access_key&isGroup=false"
  echo "user $access_key has policy $2"
}

# rustfs may still be starting.
tries=0
until curl --silent --fail --output /dev/null "$endpoint/health/ready"; do
  tries=$((tries + 1))
  [ "$tries" -lt 60 ] || { echo "rustfs is not ready" >&2; exit 1; }
  sleep 5
done

# The proof of concept's thread data, and the self-hosted deployment's. Its user can use only
# this bucket.
call --request PUT "$endpoint/katalyst-poc"
policy katalyst-poc <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:*"],
      "Resource": ["arn:aws:s3:::katalyst-poc", "arn:aws:s3:::katalyst-poc/*"]
    }
  ]
}
EOF
user katalyst-poc katalyst-poc

# The self-hosted deployment's celld fleet: its code, its Durable Objects' state and leases. It is
# kept apart from the thread data, so the thread-data key cannot write the fleet. The nodes may do
# anything in it; the deploy Job may list it, read and write deploy/ and read
# wake/format.json, which is what `celld deploy` needs.
call --request PUT "$endpoint/katalyst-fleet"
policy katalyst-fleet-node <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:*"],
      "Resource": ["arn:aws:s3:::katalyst-fleet", "arn:aws:s3:::katalyst-fleet/*"]
    }
  ]
}
EOF
user katalyst-fleet-node katalyst-fleet-node
policy katalyst-fleet-deploy <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": ["arn:aws:s3:::katalyst-fleet/deploy/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::katalyst-fleet/wake/format.json"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::katalyst-fleet"]
    }
  ]
}
EOF
user katalyst-fleet-deploy katalyst-fleet-deploy

# The control plane's storage issuer, which creates one user per thread and signs their
# sessions. katalyst-issuer-policy.json mirrors control-plane/src/core/storage/rustfs-policies/
# admin.json in KatalystSoftware/katalyst; keep the two in sync.
policy katalyst-issuer </setup/katalyst-issuer-policy.json
user katalyst-issuer katalyst-issuer
