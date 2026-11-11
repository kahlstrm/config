# One account per layer that infra-apply on pannu plans and applies (modules/infra-apply), named
# infra-<layer>, with only what that layer's plan and apply need. Its key is uploaded from the
# certificate generated on pannu and stays outside Terraform.

# local-networking: its state and lock, and its secret for the router credentials. No other
# state, so neither Talos nor cluster admin, and no new secret versions.
locals {
  infra_local_networking_member = "serviceAccount:${google_service_account.infra_local_networking.email}"
}

resource "google_service_account" "infra_local_networking" {
  account_id   = "infra-local-networking"
  display_name = "infra-apply on pannu: local-networking"
}

resource "google_storage_bucket_iam_member" "infra_local_networking_state_list" {
  bucket = google_storage_bucket.state.name
  role   = google_project_iam_custom_role.terraform_state_lister.name
  member = local.infra_local_networking_member
}

# The state and its lock, which the layer's runs also release when they left it behind.
resource "google_storage_bucket_iam_member" "infra_local_networking_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectUser"
  member = local.infra_local_networking_member

  condition {
    title      = "local-networking-state"
    expression = "resource.name.startsWith(\"projects/_/buckets/${local.state_bucket}/objects/local-networking/\")"
  }
}

# The layer manages its secret's metadata and reads it for the router credentials.
resource "google_secret_manager_secret_iam_member" "infra_local_networking_secret" {
  for_each  = toset(["roles/secretmanager.viewer", "roles/secretmanager.secretAccessor"])
  secret_id = "projects/${local.project}/secrets/local-networking"
  role      = each.value
  member    = local.infra_local_networking_member
}
