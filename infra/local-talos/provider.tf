terraform {
  required_providers {
    google = {
      version = "~> 7.6.0"
      source  = "hashicorp/google"
    }
    talos = {
      version = "0.12.0-alpha.5"
      source  = "siderolabs/talos"
    }
    helm = {
      version = "~> 3.0"
      source  = "hashicorp/helm"
    }
    kubernetes = {
      version = "~> 3.2.1"
      source  = "hashicorp/kubernetes"
    }
    random = {
      version = "~> 3.9"
      source  = "hashicorp/random"
    }
    null = {
      version = "~> 3.0"
      source  = "hashicorp/null"
    }
  }
}

provider "google" {
  project = "infra-464520"
  region  = "europe-north1"
}

provider "talos" {}

provider "helm" {
  kubernetes = {
    host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
    client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
    client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
    cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
  }
}

provider "kubernetes" {
  host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
  client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
  client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
  cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
}
