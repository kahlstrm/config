resource "pocketid_group" "admins" {
  name          = "admins"
  friendly_name = "Administrators"
}

resource "pocketid_user" "kalle" {
  username       = "kalle"
  email          = "kalle.ahlstrom@iki.fi"
  first_name     = "Kalle"
  last_name      = "Ahlström"
  is_admin       = true
  email_verified = true
  groups         = [pocketid_group.admins.id]
}

# One-time link for registering a passkey; replace it to issue a new one.
resource "pocketid_one_time_access_token" "kalle" {
  user_id = pocketid_user.kalle.id
  ttl     = "24h"
}

locals {
  oidc_clients = {
    oauth2-proxy = ["https://auth.kube.kalski.xyz/oauth2/callback"]
    grafana      = ["https://grafana.kube.kalski.xyz/login/generic_oauth"]
  }
}

resource "pocketid_client" "this" {
  for_each = local.oidc_clients

  name                = each.key
  client_id           = each.key
  callback_urls       = each.value
  allowed_user_groups = [pocketid_group.admins.id]
}

resource "kubernetes_namespace_v1" "oauth2_proxy" {
  depends_on = [talos_cluster_kubeconfig.this]

  metadata {
    name = "oauth2-proxy"
  }
}

resource "random_password" "oauth2_proxy_cookie" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "oauth2_proxy" {
  metadata {
    name      = "oauth2-proxy"
    namespace = kubernetes_namespace_v1.oauth2_proxy.metadata[0].name
  }

  data = {
    client-id     = pocketid_client.this["oauth2-proxy"].client_id
    client-secret = pocketid_client.this["oauth2-proxy"].client_secret
    cookie-secret = random_password.oauth2_proxy_cookie.result
  }
}

resource "kubernetes_secret_v1" "grafana_oidc" {
  metadata {
    name      = "grafana-oidc"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    client-secret = pocketid_client.this["grafana"].client_secret
  }
}
