# Terraform on the ops VM runs local-talos: its state and lock under local-talos/,
# local-networking's state for remote_state, and the GCP resources local-talos
# manages.
resource "google_service_account" "ops_terraform" {
  account_id   = "ops-terraform"
  display_name = "ops VM Terraform (local-talos)"
}

resource "google_project_iam_custom_role" "terraform_state_lister" {
  role_id     = "terraformStateLister"
  title       = "Terraform state lister"
  permissions = ["storage.objects.list"]
}

resource "google_project_iam_custom_role" "secret_metadata_admin" {
  role_id = "secretMetadataAdmin"
  title   = "Secret metadata admin"
  permissions = [
    "secretmanager.secrets.get",
    "secretmanager.secrets.getIamPolicy",
    "secretmanager.secrets.setIamPolicy",
    "secretmanager.secrets.update",
  ]
}

resource "google_storage_bucket_iam_member" "ops_state_list" {
  bucket = google_storage_bucket.state.name
  role   = google_project_iam_custom_role.terraform_state_lister.name
  member = local.ops_member
}

resource "google_storage_bucket_iam_member" "ops_local_talos_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectUser"
  member = local.ops_member

  condition {
    title      = "local-talos-state"
    expression = "resource.name.startsWith(\"projects/_/buckets/${local.state_bucket}/objects/local-talos/\")"
  }
}

resource "google_storage_bucket_iam_member" "ops_local_networking_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectViewer"
  member = local.ops_member

  condition {
    title      = "local-networking-state-read"
    expression = "resource.name.startsWith(\"projects/_/buckets/${local.state_bucket}/objects/local-networking/\")"
  }
}

# local-talos manages the cluster's Workload Identity pool and its provider.
resource "google_project_iam_member" "ops_workload_identity_pool_admin" {
  project = local.project
  role    = "roles/iam.workloadIdentityPoolAdmin"
  member  = local.ops_member
}

# local-talos manages the secret and its IAM policy, but never reads its versions.
resource "google_secret_manager_secret_iam_member" "ops_local_kubernetes_metadata" {
  secret_id = "projects/${local.project}/secrets/local-kubernetes"
  role      = google_project_iam_custom_role.secret_metadata_admin.name
  member    = local.ops_member
}

import {
  to = google_service_account.ops_terraform
  id = "projects/${local.project}/serviceAccounts/ops-terraform@${local.project}.iam.gserviceaccount.com"
}

import {
  to = google_project_iam_custom_role.terraform_state_lister
  id = "projects/${local.project}/roles/terraformStateLister"
}

import {
  to = google_project_iam_custom_role.secret_metadata_admin
  id = "projects/${local.project}/roles/secretMetadataAdmin"
}

import {
  to = google_storage_bucket_iam_member.ops_state_list
  id = "b/${local.state_bucket} projects/${local.project}/roles/terraformStateLister serviceAccount:ops-terraform@${local.project}.iam.gserviceaccount.com"
}

import {
  to = google_storage_bucket_iam_member.ops_local_talos_state
  id = "b/${local.state_bucket} roles/storage.objectUser serviceAccount:ops-terraform@${local.project}.iam.gserviceaccount.com local-talos-state"
}

import {
  to = google_storage_bucket_iam_member.ops_local_networking_state
  id = "b/${local.state_bucket} roles/storage.objectViewer serviceAccount:ops-terraform@${local.project}.iam.gserviceaccount.com local-networking-state-read"
}

import {
  to = google_project_iam_member.ops_workload_identity_pool_admin
  id = "${local.project} roles/iam.workloadIdentityPoolAdmin serviceAccount:ops-terraform@${local.project}.iam.gserviceaccount.com"
}

import {
  to = google_secret_manager_secret_iam_member.ops_local_kubernetes_metadata
  id = "projects/${local.project}/secrets/local-kubernetes projects/${local.project}/roles/secretMetadataAdmin serviceAccount:ops-terraform@${local.project}.iam.gserviceaccount.com"
}
