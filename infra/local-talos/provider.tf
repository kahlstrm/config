terraform {
  required_providers {
    google = {
      version = "~> 8.8.0"
      source  = "hashicorp/google"
    }
    talos = {
      version = "0.12.0"
      source  = "siderolabs/talos"
    }
  }
}

provider "google" {
  project = "infra-464520"
  region  = "europe-north1"
}

provider "talos" {}
