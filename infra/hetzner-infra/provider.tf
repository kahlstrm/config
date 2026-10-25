terraform {
  required_providers {
    google = {
      version = "~> 8.0"
      source  = "hashicorp/google"
    }
    hcloud = {
      version = "~> 1.58"
      source  = "hetznercloud/hcloud"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = "infra-464520"
  region  = "europe-north1"
}

provider "hcloud" {
  token = local.config["hcloud_token"]
}

provider "cloudflare" {
  api_token = local.config["cf_dns_api_token"]
}
