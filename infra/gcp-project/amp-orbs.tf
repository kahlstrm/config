# Amp orbs of this repository's Amp project edit the bundled local-kubernetes secret with
# infra/secret-edit, using their own short-lived OIDC identity instead of a stored key.
# The pool trusts only tokens that `amp orb id-token` minted for this Amp project and its
# owner, and its principals have no grant but the two on that one secret. Every orb of the
# project, including a prompt-injected one, gets the same access, so the secret must hold
# nothing an orb may not read: sops_age_key and klusse_amp_runner_key are in their own
# secrets (cluster-secrets.tf). See the secret-edits ADR.
locals {
  amp_project_id = "feb4bef5-546d-4135-92f8-d09d00d9ffe1"
  amp_user_id    = "user_01M70E50VNDTWE87WV9Y30PH65"
  amp_orbs       = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.amp_orbs.name}/attribute.project_id/${local.amp_project_id}"
}

resource "google_iam_workload_identity_pool" "amp_orbs" {
  workload_identity_pool_id = "amp-orbs"
  display_name              = "Amp orbs"
}

resource "google_iam_workload_identity_pool_provider" "ampcode" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.amp_orbs.workload_identity_pool_id
  workload_identity_pool_provider_id = "ampcode"
  attribute_mapping = {
    # Unique per thread and within Google's 127-byte subject limit; Amp's own sub can be longer.
    "google.subject"       = "assertion.thread_id"
    "attribute.project_id" = "assertion.project_id"
    "attribute.user_id"    = "assertion.user_id"
  }
  # The project is personal, so its tokens carry no workspace_id.
  attribute_condition = "assertion.project_id == '${local.amp_project_id}' && assertion.user_id == '${local.amp_user_id}' && assertion.token_use == 'exchanged'"

  oidc {
    issuer_uri        = "https://ampcode.com/api/workload-identity"
    allowed_audiences = ["urn:amp:gcp:${local.project}"]
  }
}

# Read the latest version, add one, and destroy the ones before it. No versions.enable: a
# destroyed version stays disabled for a day (version_destroy_ttl) and must not be restorable
# from an orb, because the versions from before the split hold sops_age_key. No setIamPolicy.
resource "google_project_iam_custom_role" "secret_version_editor" {
  role_id     = "secretVersionEditor"
  title       = "Secret version editor"
  description = "Read, add and destroy a secret's versions, without restoring one or changing IAM"
  permissions = [
    "secretmanager.versions.access",
    "secretmanager.versions.add",
    "secretmanager.versions.destroy",
    "secretmanager.versions.get",
    "secretmanager.versions.list",
  ]
}

resource "google_secret_manager_secret_iam_member" "amp_orbs_local_kubernetes" {
  secret_id = "projects/${local.project}/secrets/local-kubernetes"
  role      = google_project_iam_custom_role.secret_version_editor.name
  member    = local.amp_orbs
}
