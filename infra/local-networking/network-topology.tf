locals {
  stationary_lan = {
    network          = "10.1.1.0/24"
    gateway_ip       = "10.1.1.1"
    dhcp_pool_ranges = ["10.1.1.100-10.1.1.254"]
    dhcp_server_name = "stationary-dhcp"
  }
  external_dns_records = {
    "poenttoe.kalski.xyz" = {
      ip = "10.255.255.3"
    }
  }
  transit_network = {
    kuberack_address     = "10.254.254.1/30"
    stationary_address   = "10.254.254.2/30"
    kuberack_ipv6        = "fd00:de:ad:ff::1"
    stationary_ipv6      = "fd00:de:ad:ff::2"
    stationary_interface = "ether1"
  }
  stationary = {
    ip                = local.stationary_lan.gateway_ip
    ipv6              = "fd00:de:ad:1::1"
    zerotier_ip       = "10.255.255.2"
    domain_name       = "stationary.networking.kalski.xyz"
    wan_interface     = "ether8"
    transit_address   = local.transit_network.stationary_address
    transit_ipv6      = local.transit_network.stationary_ipv6
    transit_interface = local.transit_network.stationary_interface
    enable_cake       = true
    cake_down_mbps    = 500
    cake_up_mbps      = 50
    # The ISP's CMTS advertises itself as our v6 router and delegates a /56, but never
    # answers Neighbor Solicitations for that gateway, so IPv6 cannot leave the CPE.
    # Disable all IPv6 until the ISP fixes it.
    enable_ipv6      = false
    ipv6_prefix_hint = "::/56"
    # The default gateway probe is added automatically from the routing table.
    netwatch_targets = {
      cloudflare-dns = "1.1.1.1"
      google-dns     = "8.8.8.8"
      poenttoe       = local.external_dns_records["poenttoe.kalski.xyz"].ip
    }
  }
  kuberack = {
    transit_address   = local.transit_network.kuberack_address
    transit_ipv6      = local.transit_network.kuberack_ipv6
    transit_interface = "ether1"
    ip                = "10.10.10.1"
    ipv6              = "fd00:de:ad:10::1"
    zerotier_ip       = "10.255.255.1"
    domain_name       = "kuberack.networking.kalski.xyz"
    wan_interface     = "ether8"
    poe_out_ports     = 8 # RB5009UPr+S+: ether1-ether8 can each power a device
    enable_cake       = true
    enable_ipv6       = false
    ipv6_prefix_hint  = "::/56"
    netwatch_targets = {
      cloudflare-dns = "1.1.1.1"
      google-dns     = "8.8.8.8"
      poenttoe       = local.external_dns_records["poenttoe.kalski.xyz"].ip
    }
  }
  kuberack_network = {
    network = "10.10.10.0/24"
  }
  kuberack_dhcp_config = {
    server_name     = "kuberack-dhcp"
    network_address = "10.10.10.0/24"
    pool_ranges     = ["10.10.10.100-10.10.10.254"]
  }
  all_router_dns_records = {
    "stationary.networking.kalski.xyz" = {
      ip          = local.stationary.ip
      ipv6        = local.stationary.ipv6
      enable_ipv6 = local.stationary.enable_ipv6
    },
    "kuberack.networking.kalski.xyz" = {
      ip          = local.kuberack.ip
      ipv6        = local.kuberack.ipv6
      enable_ipv6 = local.kuberack.enable_ipv6
    }
  }
}
