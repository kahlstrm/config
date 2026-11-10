terraform {
  required_providers {
    routeros = { source = "terraform-routeros/routeros" }
    local    = { source = "hashicorp/local" }
  }
}

variable "config" {
  description = "Site settings shared by the initial RouterOS script and Terraform resources."
  type        = any
}

variable "output_directory" {
  description = "Directory for the generated commissioning script."
  type        = string
}

locals {
  script = templatefile("${path.module}/bootstrap.tftpl.rsc", merge(var.config, {
    firewall_tables    = [for name in ["ipv4_nat", "ipv4_filter", "ipv6_addresses", "ipv6_filter"] : local.firewall_tables[name]]
    management_routes  = values(local.routes)
    local_bridge_ports = join("; ", formatlist("\"%s\"", var.config.local_bridge_ports))
  }))
  addresses = {
    lan     = { address = var.config.local_ipv4_address, interface = var.config.local_bridge_name }
    transit = { address = var.config.transit_ipv4_address, interface = var.config.transit_interface }
  }
  routes = { for route in var.config.management_routes : route.peer => merge(route, {
    ipv4_comment = "Primary route to ${route.peer} LAN via transit link"
  }) }
  records = var.config.all_router_dns_records
}

resource "local_file" "script" {
  filename = "${var.output_directory}/${var.config.system_identity}.rsc"
  content  = local.script
}

resource "routeros_file" "script" {
  name     = "${var.config.system_identity}.rsc"
  contents = local.script
}

resource "routeros_ip_address" "management" {
  for_each  = local.addresses
  address   = each.value.address
  interface = each.value.interface

  # Losing it cuts ops and maintainers off the router; remove this to delete it on purpose.
  lifecycle {
    prevent_destroy = true
  }
}

resource "routeros_ip_route" "peer" {
  for_each      = local.routes
  dst_address   = each.value.ipv4_destination
  gateway       = each.value.ipv4_gateway
  check_gateway = "ping"
  distance      = 1
  comment       = each.value.ipv4_comment

  # The route to the other site, which its management goes through; see management above.
  lifecycle {
    prevent_destroy = true
  }
}

resource "routeros_ip_dns_record" "a" {
  for_each = local.records
  name     = each.key
  type     = "A"
  address  = each.value.ip
}

output "adoption" {
  description = "RouterOS selectors for the resources owned by this module, using module-relative addresses."
  value = concat(
    [for name, address in local.addresses : {
      address = "routeros_ip_address.management[${jsonencode(name)}]"
      path    = "ip/address"
      match   = address
    }],
    [for name, route in local.routes : {
      address = "routeros_ip_route.peer[${jsonencode(name)}]"
      path    = "ip/route"
      match   = { dst-address = route.ipv4_destination, gateway = route.ipv4_gateway }
    }],
    [for name, record in local.records : {
      address = "routeros_ip_dns_record.a[${jsonencode(name)}]"
      path    = "ip/dns/static"
      match   = { name = name, type = "A", address = record.ip }
    }],
    [{
      address  = "routeros_file.script"
      path     = "file"
      match    = { name = "${var.config.system_identity}.rsc" }
      optional = true
    }],
    local.ipv6_adoption,
    local.firewall_adoption
  )
}

output "script" {
  description = "The commissioning script rendered from this module's site settings."
  value       = local.script
}
