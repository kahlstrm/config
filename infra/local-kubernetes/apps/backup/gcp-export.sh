# Copies every object in the Terraform state bucket, such as local-talos' state with the
# Talos machine secrets, through the workload identity provider in
# infra/gcp-project/backup.tf, which reads that bucket only.
set -eu
export CLOUDSDK_CONFIG=/tmp/gcloud
gcloud auth login --cred-file=/config/gcp-credentials.json --quiet
mkdir /work/state
gcloud storage cp --recursive 'gs://terraform-state-1751317459/*' /work/state/
