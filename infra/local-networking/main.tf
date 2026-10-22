locals {
  stationary_lan_static_leases_and_records = {
    "crs310.networking.kalski.xyz" = {
      ip          = "10.1.1.2"
      mac_address = local.config["macs"]["crs310"]
    }
    "p.kalski.xyz" = {
      ip                = "10.1.1.10"
      mac_address       = local.config["macs"]["pannu"]
      include_subdomain = true
    },
    "jet.kalski.xyz" = {
      ip          = "10.1.1.11"
      mac_address = local.config["macs"]["jetkvm"]
    },
    "ha.kalski.xyz" = {
      ip          = "10.1.1.20"
      mac_address = local.config["macs"]["ha_pi"]
    }
    "zima.kalski.xyz" = {
      ip                = "10.1.1.30"
      mac_address       = local.config["macs"]["zima"]
      include_subdomain = true
    }
  }
  k8s_control_plane_nodes = {
    "c1.k8s.kalski.xyz" = {
      ip          = "10.10.10.11"
      mac_address = local.config["macs"]["c1_k8s"]
    }
    "c2.k8s.kalski.xyz" = {
      ip          = "10.10.10.12"
      mac_address = local.config["macs"]["c2_k8s"]
    }
    "c3.k8s.kalski.xyz" = {
      ip          = "10.10.10.13"
      mac_address = local.config["macs"]["c3_k8s"]
    }
  }

  k8s_worker_nodes = {
    "w1.k8s.kalski.xyz" = {
      ip          = "10.10.10.21"
      mac_address = local.config["macs"]["w1_k8s"]
    }
    "w2.k8s.kalski.xyz" = {
      ip          = "10.10.10.22"
      mac_address = local.config["macs"]["w2_k8s"]
    }
  }

  # Shared Kubernetes API address, held by one healthy control plane (Talos VIP).
  k8s_api_vip = "10.10.10.10"

  kuberack_lan_static_leases_and_records = merge(
    local.k8s_control_plane_nodes,
    local.k8s_worker_nodes, {
      "crs305.networking.kalski.xyz" = {
        ip          = "10.10.10.2"
        mac_address = local.config["macs"]["crs305"]
      }
      "jet.k8s.kalski.xyz" = {
        ip          = "10.10.10.5"
        mac_address = local.config["macs"]["kuberack_jetkvm"]
      }
    }
  )

}

locals {
  dns_a_record = merge(local.stationary_lan_static_leases_and_records, local.kuberack_lan_static_leases_and_records, local.external_dns_records)
}


module "stationary" {
  source = "./modules/stationary"
  providers = {
    routeros.stationary = routeros.stationary
  }
  config = {
    device_config = local.stationary
    dhcp_config = {
      server_name     = local.stationary_lan.dhcp_server_name
      network_address = local.stationary_lan.network
      pool_ranges     = local.stationary_lan.dhcp_pool_ranges
    }
    static_leases    = local.stationary_lan_static_leases_and_records
    bridge_interface = "local-bridge"
    dns_a_records    = local.dns_a_record
    wan_interface    = local.stationary.wan_interface
    enable_cake      = local.stationary.enable_cake
    cake_down_mbps   = local.stationary.cake_down_mbps
    cake_up_mbps     = local.stationary.cake_up_mbps
    enable_ipv6      = local.stationary.enable_ipv6
    ipv6_prefix_hint = local.stationary.ipv6_prefix_hint
    netwatch_targets = local.stationary.netwatch_targets
    peers = {
      kuberack = {
        network = local.kuberack_network.network
        gateway = split("/", local.kuberack.transit_address)[0]
      }
    }
  }
}


module "zerotier" {
  source = "./modules/zerotier"
  providers = {
    routeros.stationary = routeros.stationary
    routeros.kuberack   = routeros.kuberack
    zerotier            = zerotier
  }
  stationary  = local.stationary
  kuberack    = local.kuberack
  poenttoe_ip = local.external_dns_records["poenttoe.kalski.xyz"].ip
}

module "mktxp_kuberack" {
  source = "./modules/mktxp-user"
  providers = {
    routeros = routeros.kuberack
  }
  username = local.config["mktxp"]["username"]
  password = local.config["mktxp"]["kuberack_rb5009_password"]
}

module "mktxp_stationary" {
  source = "./modules/mktxp-user"
  providers = {
    routeros = routeros.stationary
  }
  username = local.config["mktxp"]["username"]
  password = local.config["mktxp"]["stationary_rb5009_password"]
}

module "external_dns_kuberack" {
  source = "./modules/external-dns-user"
  providers = {
    routeros = routeros.kuberack
  }
  external_dns_password = local.config["external_dns_password"]
}

module "external_dns_stationary" {
  source = "./modules/external-dns-user"
  providers = {
    routeros = routeros.stationary
  }
  external_dns_password = local.config["external_dns_password"]
}

module "kuberack" {
  source = "./modules/kuberack"
  providers = {
    routeros.kuberack = routeros.kuberack
  }
  config = {
    device_config     = local.kuberack
    lan_static_leases = local.kuberack_lan_static_leases_and_records
    lan_dhcp_config   = local.kuberack_dhcp_config
    bridge_interface  = "kuberack-bridge"
    dns_a_records     = local.dns_a_record
    wan_interface     = local.bootstrap_configs.kuberack.wan_interface
    enable_cake       = local.kuberack.enable_cake
    enable_ipv6       = local.kuberack.enable_ipv6
    ipv6_prefix_hint  = local.kuberack.ipv6_prefix_hint
    netwatch_targets  = local.kuberack.netwatch_targets
    peers = {
      stationary = {
        network = local.stationary_lan.network
        gateway = split("/", local.stationary.transit_address)[0]
      }
    }
  }
}

module "stationary_cert" {
  source = "./modules/cert"
  providers = {
    routeros = routeros.stationary
    acme     = acme
  }
  account_key_pem  = acme_registration.reg.account_key_pem
  cf_dns_api_token = local.config["cf_dns_api_token"]
  domain           = local.stationary.domain_name
}

module "kuberack_cert" {
  source = "./modules/cert"
  providers = {
    routeros = routeros.kuberack
    acme     = acme
  }
  account_key_pem  = acme_registration.reg.account_key_pem
  cf_dns_api_token = local.config["cf_dns_api_token"]
  domain           = local.kuberack.domain_name
}

resource "routeros_system_user_sshkeys" "admin_keys_stationary" {
  provider = routeros.stationary
  for_each = nonsensitive(local.config["ssh_public_keys"])
  user     = local.config["stationary_rb5009"]["username"]
  key      = each.value
  comment  = each.key
}

resource "routeros_system_user_sshkeys" "admin_keys_kuberack" {
  provider = routeros.kuberack
  for_each = nonsensitive(local.config["ssh_public_keys"])
  user     = local.config["kuberack_rb5009"]["username"]
  key      = each.value
  comment  = each.key
}
