terraform {
  required_providers {
    google = {
      version = "~> 8.8.0"
      source  = "hashicorp/google"
    }
  }
}

provider "google" {
  project = local.project
  region  = "europe-north1"
}
