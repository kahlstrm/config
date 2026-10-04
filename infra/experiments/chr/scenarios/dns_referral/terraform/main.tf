terraform {
  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "1.98.0"
    }
  }
}

variable "hosturl" { type = string }
variable "password" {
  type      = string
  sensitive = true
}

variable "scenario_enabled" {
  type    = bool
  default = true
}

provider "routeros" {
  hosturl  = var.hosturl
  username = "admin"
  password = var.password
}

resource "routeros_ip_dhcp_client" "uplink" {
  interface    = "ether1"
  use_peer_dns = !var.scenario_enabled
}

resource "routeros_ip_dns" "scenario" {
  depends_on            = [routeros_ip_dhcp_client.uplink]
  servers               = var.scenario_enabled ? ["1.1.1.1"] : []
  allow_remote_requests = var.scenario_enabled
  use_doh_server        = ""
}
