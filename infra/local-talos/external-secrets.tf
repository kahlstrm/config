# External Secrets Operator reads this one secret, which holds only what the
# cluster needs. GCP verifies the cluster's own service-account tokens against
# the committed public keys, so the API server stays private and no key exists.
# The file holds the keys exactly as GCP stores them, so plans stay clean. If
# Talos' service account key ever changes, write `kubectl get --raw /openid/v1/jwks`
# here, apply, then replace the file with the provider's stored `oidc.jwksJson`.
resource "google_secret_manager_secret" "kubernetes" {
  secret_id = "local-kubernetes"

  replication {
    auto {}
  }

  version_destroy_ttl = "86400s"

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  external_secrets_subject = "system:serviceaccount:external-secrets:gcp-secret-manager"
}

resource "google_iam_workload_identity_pool" "cluster" {
  workload_identity_pool_id = local.cluster_name
  display_name              = "Kubernetes ${local.cluster_name}"
}

resource "google_iam_workload_identity_pool_provider" "kubernetes" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.cluster.workload_identity_pool_id
  workload_identity_pool_provider_id = "kubernetes"
  attribute_mapping = {
    "google.subject" = "assertion.sub"
  }
  attribute_condition = "assertion.sub == '${local.external_secrets_subject}'"

  oidc {
    issuer_uri = local.service_account_issuer
    jwks_json  = trimspace(file("${path.module}/service-account-jwks.json"))
  }
}

resource "google_secret_manager_secret_iam_member" "external_secrets" {
  secret_id = google_secret_manager_secret.kubernetes.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.cluster.name}/subject/${local.external_secrets_subject}"
}
