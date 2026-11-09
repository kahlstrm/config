# The ops VM's RouterOS user. Its group may read through the REST API and nothing else, so it
# changes no configuration itself (REST also needs `api`; ops reaches only HTTPS). It runs
# only the scripts below, which RouterOS runs with their own policy because
# dont_require_permissions is set; each power-cycles the PoE port it is named after and
# nothing else. They name ports, not devices: the router cannot vouch for what is plugged in.
# RouterOS refuses this user's other writes, script edits, scripts without that flag,
# reboots and group changes (checked over REST on CHR 7.21.3).
#
# Any user may run these scripts, including the read-only mktxp user: RouterOS runs them as
# their owner and doesn't tell them who started them. The worst a leaked mktxp credential
# could do through them is power-cycle a PoE port.
terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

resource "routeros_system_user_group" "ops" {
  name    = "ops-poe"
  policy  = ["read", "api", "rest-api"]
  comment = "ops VM: read, and run the ops-poe-cycle-* scripts"
}

# ops reads it from this layer's state with its GCP key (see the root's ops_routeros_password).
resource "random_password" "ops" {
  length  = 32
  special = false
}

resource "routeros_system_user" "ops" {
  name     = "ops"
  group    = routeros_system_user_group.ops.name
  password = random_password.ops.result
  address  = var.address
  comment  = "ops VM; password in local-networking's state"
}

resource "routeros_system_script" "poe_cycle" {
  for_each = toset(var.poe_cycle_ports)
  name     = "ops-poe-cycle-${each.value}"
  # power-cycle needs only `test`: on kuberack, read,write was refused ("not enough permissions")
  # and test alone worked. The fixed source bounds what the policy allows.
  policy                   = ["test"]
  dont_require_permissions = true
  source                   = "/interface ethernet poe power-cycle ${each.value} duration=${var.off_duration}"
  comment                  = "Power-cycle PoE port ${each.value} for ${var.off_duration}; run by ops"
}

output "password" {
  value     = random_password.ops.result
  sensitive = true
}
