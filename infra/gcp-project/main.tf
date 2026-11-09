# GCP resources that other layers depend on but cannot manage themselves: the
# Terraform state bucket and the ops VM's service account with its grants. Only
# a maintainer applies this layer; ops-terraform must never be able to widen its
# own access. The account's key is uploaded from ops' own certificate (see
# modules/agent-ops/default.nix) and stays outside Terraform.
locals {
  project      = "infra-464520"
  state_bucket = "terraform-state-1751317459"
  ops_member   = "serviceAccount:${google_service_account.ops_terraform.email}"
}

resource "google_storage_bucket" "state" {
  name                        = local.state_bucket
  location                    = "US"
  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Project members' access, restated as bucket bindings because uniform
# bucket-level access ignores object ACLs.
locals {
  state_bucket_project_bindings = {
    bucket_owner_owners  = { role = "roles/storage.legacyBucketOwner", member = "projectOwner:${local.project}" }
    bucket_owner_editors = { role = "roles/storage.legacyBucketOwner", member = "projectEditor:${local.project}" }
    bucket_reader        = { role = "roles/storage.legacyBucketReader", member = "projectViewer:${local.project}" }
    object_owner_owners  = { role = "roles/storage.legacyObjectOwner", member = "projectOwner:${local.project}" }
    object_owner_editors = { role = "roles/storage.legacyObjectOwner", member = "projectEditor:${local.project}" }
    object_reader        = { role = "roles/storage.legacyObjectReader", member = "projectViewer:${local.project}" }
  }
}

resource "google_storage_bucket_iam_member" "state_project" {
  for_each = local.state_bucket_project_bindings

  bucket = google_storage_bucket.state.name
  role   = each.value.role
  member = each.value.member
}

import {
  for_each = local.state_bucket_project_bindings
  to       = google_storage_bucket_iam_member.state_project[each.key]
  id       = "b/${local.state_bucket} ${each.value.role} ${each.value.member}"
}

import {
  to = google_storage_bucket.state
  id = local.state_bucket
}
