terraform {
  required_providers {
    routeros = {
      source                = "terraform-routeros/routeros"
      configuration_aliases = [routeros.kuberack]
    }
  }
}

module "rb5009" {
  source = "../rb5009"

  providers = {
    routeros = routeros.kuberack
  }

  config            = var.config.device_config
  lan_static_leases = var.config.lan_static_leases
  lan_dhcp_config   = var.config.lan_dhcp_config
  bridge_interface  = var.config.bridge_interface
  dns_a_records     = var.config.dns_a_records
  wan_interface     = var.config.wan_interface
  enable_cake       = var.config.enable_cake
  enable_ipv6       = var.config.enable_ipv6
  ipv6_prefix_hint  = var.config.ipv6_prefix_hint
  netwatch_targets  = var.config.netwatch_targets
}

resource "routeros_ip_route" "default_via_stationary" {
  provider    = routeros.kuberack
  dst_address = "0.0.0.0/0"
  gateway     = var.config.peers.stationary.gateway
  distance    = 1
  comment     = "Default via stationary"

  # kuberack's WAN path; losing it cuts the site off. Remove this to delete it on purpose.
  lifecycle {
    prevent_destroy = true
  }
}
