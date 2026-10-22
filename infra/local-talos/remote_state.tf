data "terraform_remote_state" "networking" {
  backend = "gcs"
  config = {
    bucket = "terraform-state-1751317459"
    prefix = "local-networking"
  }
}

locals {
  # Extract networking outputs to local variables
  k8s_controlplanes = data.terraform_remote_state.networking.outputs.k8s_controlplanes
  k8s_workers       = data.terraform_remote_state.networking.outputs.k8s_workers
  cluster_network   = data.terraform_remote_state.networking.outputs.cluster_network
  k8s_api_vip       = data.terraform_remote_state.networking.outputs.k8s_api_vip
  k8s_api_hostname  = data.terraform_remote_state.networking.outputs.k8s_api_hostname

  cluster_endpoint = "https://${local.k8s_api_hostname}:6443"
  # Tokens keep the issuer from when c1 was the endpoint: GCP workload identity
  # federation trusts it, and Talos 1.11 can't accept a second issuer.
  service_account_issuer = "https://10.10.10.11:6443"
}
