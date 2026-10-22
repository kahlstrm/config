output "k8s_controlplanes" {
  description = "Kubernetes control plane nodes"
  value = { for hostname, config in local.k8s_control_plane_nodes : hostname => {
    ip = config.ip
  } }
}

output "k8s_workers" {
  description = "Kubernetes worker nodes"
  value = { for hostname, config in local.k8s_worker_nodes : hostname => {
    ip = config.ip
  } }
}

output "k8s_api_vip" {
  description = "Shared Kubernetes API address held by a healthy control plane"
  value       = local.k8s_api.ip
}

output "k8s_api_hostname" {
  description = "DNS name of the shared Kubernetes API address"
  value       = local.k8s_api.hostname
}

output "cluster_network" {
  description = "Kubernetes cluster network"
  value       = local.kuberack_network.network
}

output "secret_id" {
  description = "Google Secret Manager secret ID for cross-layer access"
  value       = module.secrets.secret_id
}

output "external_dns_username" {
  description = "MikroTik external-dns service account username"
  value       = "external-dns"
}

output "kuberack_domain" {
  description = "Kuberack router domain name for API access"
  value       = local.kuberack.domain_name
}

output "stationary_domain" {
  description = "Stationary router domain name for API access"
  value       = local.stationary.domain_name
}

output "zerotier_network_id" {
  description = "ZeroTier Network ID"
  value       = module.zerotier.network_id
}

output "poenttoe_zerotier_private_key" {
  description = "ZeroTier private key for poenttoe server"
  value       = module.zerotier.poenttoe_private_key
  sensitive   = true
}
