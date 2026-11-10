terraform {
  required_providers {
    routeros = {
      source                = "terraform-routeros/routeros"
      configuration_aliases = [routeros.kuberack, routeros.stationary]
    }
    zerotier = {
      source = "zerotier/zerotier"
    }
  }
}

resource "zerotier_network" "network" {
  name = "kalski.xyz"
  dns {
    domain  = "kalski.xyz"
    servers = [var.kuberack.ip, var.stationary.ip]
  }
  assignment_pool {
    start = "10.255.255.100"
    end   = "10.255.255.254"
  }
  # dynamic "route" {
  #   for_each = [var.kuberack, var.stationary]
  #   content {
  #     target = route.value.internal_ip
  #     via    = route.value.zerotier_ip
  #   }
  # }
}

resource "zerotier_identity" "kuberack" {}

resource "zerotier_member" "kuberack" {
  authorized              = true
  member_id               = zerotier_identity.kuberack.id
  name                    = "kuberack"
  network_id              = zerotier_network.network.id
  hidden                  = false
  allow_ethernet_bridging = true
  no_auto_assign_ips      = true
}

# Kuberack uses stationary as upstream, so ZeroTier connects via transit -> stationary -> WAN.
# Binding to all interfaces allows ZeroTier to use whatever path is available.
resource "routeros_zerotier" "kuberack_zt1" {
  provider   = routeros.kuberack
  comment    = "ZeroTier Central - Kuberack RB5009"
  identity   = zerotier_identity.kuberack.private_key
  interfaces = ["all"]
  name       = "zt-tunnel"
  port       = 9994
}

resource "routeros_zerotier_interface" "kuberack_zerotier1" {
  provider      = routeros.kuberack
  allow_default = false
  allow_global  = false
  allow_managed = false
  instance      = routeros_zerotier.kuberack_zt1.name
  name          = "zerotier1"
  network       = zerotier_network.network.id
}

resource "routeros_ip_address" "kuberack_zerotier_ip" {
  provider  = routeros.kuberack
  address   = "${var.kuberack.zerotier_ip}/24"
  interface = routeros_zerotier_interface.kuberack_zerotier1.name
}

resource "zerotier_identity" "stationary" {}

resource "zerotier_member" "stationary" {
  authorized              = true
  member_id               = zerotier_identity.stationary.id
  name                    = "stationary"
  network_id              = zerotier_network.network.id
  hidden                  = false
  allow_ethernet_bridging = true
  no_auto_assign_ips      = true
}

# See comment on kuberack_zt1 for WAN-only binding rationale
resource "routeros_zerotier" "stationary_zt1" {
  provider   = routeros.stationary
  comment    = "ZeroTier Central - Stationary RB5009UGS"
  identity   = zerotier_identity.stationary.private_key
  interfaces = [var.stationary.wan_interface]
  name       = "zt-tunnel"
  port       = 9994
}

resource "routeros_zerotier_interface" "stationary_zerotier1" {
  provider      = routeros.stationary
  allow_default = false
  allow_global  = false
  allow_managed = false
  instance      = routeros_zerotier.stationary_zt1.name
  name          = "zerotier1"
  network       = zerotier_network.network.id
}

resource "routeros_ip_address" "stationary_zerotier_ip" {
  provider  = routeros.stationary
  address   = "${var.stationary.zerotier_ip}/24"
  interface = routeros_zerotier_interface.stationary_zerotier1.name
}

# Add ZeroTier interfaces to MGMT_ALLOWED list for management access
resource "routeros_interface_list_member" "kuberack_zerotier_mgmt" {
  provider  = routeros.kuberack
  interface = routeros_zerotier_interface.kuberack_zerotier1.name
  list      = "MGMT_ALLOWED"
  comment   = "Allow management via ZeroTier"

  # Management over ZeroTier, the fallback when the sites are separated.
  lifecycle {
    prevent_destroy = true
  }
}

resource "routeros_interface_list_member" "stationary_zerotier_mgmt" {
  provider  = routeros.stationary
  interface = routeros_zerotier_interface.stationary_zerotier1.name
  list      = "MGMT_ALLOWED"
  comment   = "Allow management via ZeroTier"

  # Management over ZeroTier, the fallback when the sites are separated.
  lifecycle {
    prevent_destroy = true
  }
}

# Fallback routes over ZeroTier (distance 200, only used when transit link is down).
# check_gateway is set to "none" to keep routes always active - using "ping" would cause
# the route to become inactive during ZeroTier path discovery, creating a chicken-and-egg
# problem where traffic can't flow until the ping check succeeds.
resource "routeros_ip_route" "kuberack_stationary_lan_zerotier" {
  provider      = routeros.kuberack
  disabled      = false
  dst_address   = "10.1.1.0/24"
  gateway       = var.stationary.zerotier_ip
  distance      = 200
  check_gateway = "none"
  comment       = "Fallback route to stationary LAN via ZeroTier"
  depends_on    = [routeros_ip_address.kuberack_zerotier_ip]
}

resource "routeros_ip_route" "stationary_kuberack_lan_zerotier" {
  provider      = routeros.stationary
  disabled      = false
  dst_address   = "10.10.10.0/24"
  gateway       = var.kuberack.zerotier_ip
  distance      = 200
  check_gateway = "none"
  comment       = "Fallback route to Kuberack LAN via ZeroTier"
  depends_on    = [routeros_ip_address.stationary_zerotier_ip]
}

resource "zerotier_identity" "poenttoe" {}

resource "zerotier_member" "poenttoe" {
  authorized              = true
  member_id               = zerotier_identity.poenttoe.id
  name                    = "poenttoe"
  network_id              = zerotier_network.network.id
  hidden                  = false
  allow_ethernet_bridging = true
  no_auto_assign_ips      = true
  ip_assignments          = [var.poenttoe_ip]
}
