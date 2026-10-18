resource "kubernetes_namespace_v1" "pocket_id" {
  depends_on = [talos_cluster_kubeconfig.this]

  metadata {
    name = "pocket-id"
  }
}

ephemeral "random_password" "pocket_id_encryption_key" {
  length  = 48
  special = false
}

ephemeral "random_password" "pocket_id_static_api_key" {
  length  = 48
  special = false
}

# Losing the encryption key makes Pocket ID's data unreadable, so both keys live
# in Secret Manager and survive recreating the Kubernetes Secret. Terraform also
# reads the static API key to manage Pocket ID.
resource "google_secret_manager_secret" "pocket_id" {
  secret_id = "pocket-id-keys"

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret_version" "pocket_id" {
  secret = google_secret_manager_secret.pocket_id.id
  secret_data_wo = jsonencode({
    encryption_key = ephemeral.random_password.pocket_id_encryption_key.result
    static_api_key = ephemeral.random_password.pocket_id_static_api_key.result
  })
  secret_data_wo_version = 1
  deletion_policy        = "DISABLE"
}

ephemeral "google_secret_manager_secret_version" "pocket_id" {
  secret  = google_secret_manager_secret.pocket_id.id
  version = google_secret_manager_secret_version.pocket_id.version
}

locals {
  pocket_id_keys = jsondecode(ephemeral.google_secret_manager_secret_version.pocket_id.secret_data)
}

resource "kubernetes_secret_v1" "pocket_id" {
  metadata {
    name      = "pocket-id"
    namespace = kubernetes_namespace_v1.pocket_id.metadata[0].name
  }

  data_wo_revision = tonumber(google_secret_manager_secret_version.pocket_id.version)
  data_wo = {
    ENCRYPTION_KEY = local.pocket_id_keys.encryption_key
    STATIC_API_KEY = local.pocket_id_keys.static_api_key
  }
}
