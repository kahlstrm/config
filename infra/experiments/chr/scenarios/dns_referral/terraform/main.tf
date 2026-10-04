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

provider "routeros" {
  hosturl  = var.hosturl
  username = "admin"
  password = var.password
}

resource "routeros_ip_dhcp_client" "uplink" {
  interface    = "ether1"
  use_peer_dns = false
}

resource "routeros_ip_dns" "scenario" {
  depends_on            = [routeros_ip_dhcp_client.uplink]
  servers               = ["1.1.1.1"]
  allow_remote_requests = true
  use_doh_server        = ""
}
