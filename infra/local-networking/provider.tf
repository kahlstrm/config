terraform {
  required_providers {
    google = {
      version = "~> 6.0"
      source  = "hashicorp/google"
    }
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "~> 1.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    zerotier = {
      source  = "zerotier/zerotier"
      version = "~> 1.0"
    }
    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }
  }
}

provider "google" {
  project = "infra-464520"
  region  = "europe-north1"
}

variable "ALLOW_INSECURE" {
  default = false
  type    = bool
}

variable "stationary_hosturl" {
  description = "Hostname for stationary router (override during migration)"
  default     = "stationary.networking.kalski.xyz"
  type        = string
}

variable "kuberack_hosturl" {
  description = "Hostname for kuberack router (override during migration)"
  default     = "kuberack.networking.kalski.xyz"
  type        = string
}

provider "routeros" {
  alias    = "stationary"
  hosturl  = var.stationary_hosturl
  username = local.config["stationary_rb5009"]["username"]
  password = local.config["stationary_rb5009"]["password"]
  insecure = var.ALLOW_INSECURE
}

provider "routeros" {
  alias    = "kuberack"
  hosturl  = var.kuberack_hosturl
  username = local.config["kuberack_rb5009"]["username"]
  password = local.config["kuberack_rb5009"]["password"]
  insecure = var.ALLOW_INSECURE
}

provider "zerotier" {
  zerotier_central_token = local.config["zerotier_api_token"]
}

provider "acme" {
  server_url = "https://acme-v02.api.letsencrypt.org/directory"
}

resource "acme_registration" "reg" {
  email_address = "kalle.ahlstrom@iki.fi"
}
