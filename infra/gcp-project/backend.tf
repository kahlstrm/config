# The state lives in the bucket this layer manages. The bucket already exists, so
# there is no creation cycle; prevent_destroy keeps Terraform from deleting it, and
# project owners can always repair its IAM with gcloud. ops-terraform can list but
# not read this prefix.
terraform {
  backend "gcs" {
    bucket = "terraform-state-1751317459"
    prefix = "gcp-project"
  }
}
