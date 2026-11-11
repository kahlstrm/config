# The cluster's terraform-state backup job (local-kubernetes/apps/backup, docs/backups.md)
# reads the state bucket, which holds the Talos machine secrets, and encrypts it to the
# offline recovery key before it leaves the pod. It reads nothing else: Secret Manager's
# provider tokens are minted again instead. The grants live in this layer, which only the
# operator applies, rather than in local-talos with the pool, where ops-terraform could
# widen them.
#
# The provider trusts the cluster's service-account tokens the way local-talos' provider for
# External Secrets does, but for the backup job's service account alone.
locals {
  backup_subject   = "system:serviceaccount:backup:terraform-state"
  backup_principal = "principal://iam.googleapis.com/projects/638826885263/locations/global/workloadIdentityPools/klusse/subject/${local.backup_subject}"
}

resource "google_iam_workload_identity_pool_provider" "backup" {
  workload_identity_pool_id          = "klusse"
  workload_identity_pool_provider_id = "backup"
  display_name                       = "klusse backup job"
  attribute_mapping = {
    "google.subject" = "assertion.sub"
  }
  attribute_condition = "assertion.sub == '${local.backup_subject}'"

  oidc {
    issuer_uri = "https://10.10.10.11:6443"
    jwks_json  = trimspace(file("${path.module}/../local-talos/service-account-jwks.json"))
  }
}

resource "google_storage_bucket_iam_member" "backup_state_read" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectViewer"
  member = local.backup_principal
}
