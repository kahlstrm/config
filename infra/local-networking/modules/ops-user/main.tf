# The ops VM's RouterOS user. Its group may log in over SSH and read, nothing else, so it
# changes no configuration itself. It runs only the scripts below, which RouterOS runs with
# their own read and write policy because dont_require_permissions is set; each power-cycles
# one named port and nothing else. RouterOS refuses this user's other writes, script edits,
# scripts without that flag, password logins, and reboots (checked on CHR 7.21.3).
#
# Any user may run these scripts, including the read-only mktxp user: RouterOS runs them as
# their owner and doesn't tell them who started them. The worst a leaked mktxp credential
# could do through them is power-cycle a control plane.
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
  policy  = ["ssh", "read"]
  comment = "ops VM: read, and run the ops-poe-cycle-* scripts"
}

# RouterOS requires a password, but nothing uses this one: the group's only login policy is
# SSH, which refuses passwords for a user with a key (password-authentication=yes-if-no-key,
# the default).
resource "random_password" "ops" {
  length  = 32
  special = false
}

resource "routeros_system_user" "ops" {
  name     = "ops"
  group    = routeros_system_user_group.ops.name
  password = random_password.ops.result
  address  = var.address
  comment  = "ops VM; key from modules/agent-ops/public/routeros.pub"
}

resource "routeros_system_user_sshkeys" "ops" {
  user    = routeros_system_user.ops.name
  key     = var.public_key
  comment = "ops"
}

resource "routeros_system_script" "poe_cycle" {
  for_each                 = var.poe_cycle_ports
  name                     = "ops-poe-cycle-${each.key}"
  policy                   = ["read", "write"]
  dont_require_permissions = true
  source                   = "/interface ethernet poe power-cycle ${each.value} duration=${var.off_duration}"
  comment                  = "Power-cycle ${each.key}'s PoE port ${each.value} for ${var.off_duration}; run by ops"
}
