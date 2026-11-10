terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
  }
}

resource "routeros_ipv6_dhcp_client" "wan_pd" {
  interface          = var.wan_interface
  request            = ["prefix"]
  pool_name          = var.pool_name
  pool_prefix_length = 64
  add_default_route  = true
  use_peer_dns       = false
  prefix_hint        = var.prefix_hint
  disabled           = !var.enable_ipv6
  comment            = "terraform: wan prefix delegation"

  # The WAN's IPv6 prefix and default route; disable it with enable_ipv6 instead of deleting it.
  lifecycle {
    prevent_destroy = true
  }
}

# The LAN's slice of the delegated prefix. Managed here rather than in the bootstrap
# script so a freshly provisioned router needs no import: bootstrap creating these
# objects is what forced Terraform to adopt them instead of owning them outright.
resource "routeros_ipv6_address" "lan_from_pool" {
  depends_on = [routeros_ipv6_dhcp_client.wan_pd]

  from_pool = var.pool_name
  interface = var.bridge_interface
  eui_64    = true
  advertise = var.enable_ipv6
  disabled  = !var.enable_ipv6
  comment   = "terraform: lan prefix from wan delegation"
}
