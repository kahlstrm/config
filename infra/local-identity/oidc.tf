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

# Public clients use PKCE instead of a client secret, so nothing has to reach
# the cluster from here.
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
  is_public           = true
  allowed_user_groups = [pocketid_group.admins.id]
}
