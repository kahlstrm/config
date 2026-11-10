# The ops runner's account (modules/agent-ops/runner.nix): applies of local-networking and
# edits of its secret. It reaches no other state, so neither Talos nor cluster admin, unlike
# ops-terraform. Its key is uploaded from the runner's own certificate and stays outside
# Terraform. Only a maintainer applies this layer.
locals {
  ops_networking_member = "serviceAccount:${google_service_account.ops_networking.email}"
}

resource "google_service_account" "ops_networking" {
  account_id   = "ops-networking"
  display_name = "ops runner (local-networking applies and secret edits)"
}

resource "google_storage_bucket_iam_member" "ops_networking_state_list" {
  bucket = google_storage_bucket.state.name
  role   = google_project_iam_custom_role.terraform_state_lister.name
  member = local.ops_networking_member
}

# local-networking's state and its lock.
resource "google_storage_bucket_iam_member" "ops_networking_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectUser"
  member = local.ops_networking_member

  condition {
    title      = "local-networking-state"
    expression = "resource.name.startsWith(\"projects/_/buckets/${local.state_bucket}/objects/local-networking/\")"
  }
}

# local-networking manages its secret's metadata and reads it for the router credentials.
resource "google_secret_manager_secret_iam_member" "ops_networking_local_networking" {
  for_each  = toset(["roles/secretmanager.viewer", "roles/secretmanager.secretAccessor"])
  secret_id = "projects/${local.project}/secrets/local-networking"
  role      = each.value
  member    = local.ops_networking_member
}

# Secret edits (infra/docs/adr/2026-11-10-secret-edits-on-the-ops-runner.md): a standing grant,
# gated only by the ops runner's per-command prompt; PAM needs an organization, which this
# project lacks. An edit reads the latest version, with the grant above, and adds one. Nothing
# on local-kubernetes: IAM grants the whole secret, so reading or adding a version of it would
# also read or replace sops_age_key.
resource "google_secret_manager_secret_iam_member" "ops_networking_secret_edit" {
  secret_id = "projects/${local.project}/secrets/local-networking"
  role      = "roles/secretmanager.secretVersionAdder"
  member    = local.ops_networking_member
}
