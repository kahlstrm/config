# The cluster's two most dangerous values each have a secret of their own, so that orbs can
# edit the bundled local-kubernetes secret (amp-orbs.tf) without reaching them. sops_age_key
# decrypts every SOPS file in the repository; klusse_amp_runner_key acts as the whole Amp
# account. Only the cluster's External Secrets reads them; no orb or runner identity has a
# grant. A maintainer created both with gcloud before their readers switched, so they are
# imported here.
locals {
  cluster_only_secrets = toset(["sops_age_key", "klusse_amp_runner_key"])
}

resource "google_secret_manager_secret" "cluster_only" {
  for_each = local.cluster_only_secrets

  secret_id = each.value

  replication {
    auto {}
  }

  version_destroy_ttl = "86400s"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret_iam_member" "external_secrets_cluster_only" {
  for_each = google_secret_manager_secret.cluster_only

  secret_id = each.value.id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.external_secrets_principal
}

import {
  for_each = local.cluster_only_secrets
  to       = google_secret_manager_secret.cluster_only[each.value]
  id       = "projects/${local.project}/secrets/${each.value}"
}

import {
  for_each = local.cluster_only_secrets
  to       = google_secret_manager_secret_iam_member.external_secrets_cluster_only[each.value]
  id       = "projects/${local.project}/secrets/${each.value} roles/secretmanager.secretAccessor ${local.external_secrets_principal}"
}
