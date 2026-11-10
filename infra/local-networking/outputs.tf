# Every output is sensitive, so plans and applies on the ops runner print none of them. Their
# consumers read them on purpose: local-talos through remote state, ops from the state object.
output "k8s_controlplanes" {
  description = "Kubernetes control plane nodes"
  value = { for hostname, config in local.k8s_control_plane_nodes : hostname => {
    ip = config.ip
  } }
  sensitive = true
}

output "k8s_workers" {
  description = "Kubernetes worker nodes"
  value = { for hostname, config in local.k8s_worker_nodes : hostname => {
    ip = config.ip
  } }
  sensitive = true
}

output "k8s_api_vip" {
  description = "Shared Kubernetes API address held by a healthy control plane"
  value       = local.k8s_api.ip
  sensitive   = true
}

output "k8s_api_hostname" {
  description = "DNS name of the shared Kubernetes API address"
  value       = local.k8s_api.hostname
  sensitive   = true
}

output "cluster_network" {
  description = "Kubernetes cluster network"
  value       = local.kuberack_network.network
  sensitive   = true
}

output "secret_id" {
  description = "Google Secret Manager secret ID for cross-layer access"
  value       = module.secrets.secret_id
  sensitive   = true
}

output "external_dns_username" {
  description = "MikroTik external-dns service account username"
  value       = "external-dns"
  sensitive   = true
}

output "kuberack_domain" {
  description = "Kuberack router domain name for API access"
  value       = local.kuberack.domain_name
  sensitive   = true
}

output "stationary_domain" {
  description = "Stationary router domain name for API access"
  value       = local.stationary.domain_name
  sensitive   = true
}

output "zerotier_network_id" {
  description = "ZeroTier Network ID"
  value       = module.zerotier.network_id
  sensitive   = true
}

output "poenttoe_zerotier_private_key" {
  description = "ZeroTier private key for poenttoe server"
  value       = module.zerotier.poenttoe_private_key
  sensitive   = true
}

# The ops VM's kuberack REST password. ops-routeros on ops reads it with ops' GCP key, which
# reads this layer's state for local-talos' remote state anyway.
output "ops_routeros_password" {
  value     = module.ops_kuberack.password
  sensitive = true
}

# Home Assistant's long-lived token from this layer's secret, for ops-home-assistant on ops.
# The secret's data source already keeps it in this state, which ops reads; null without one.
output "ops_home_assistant_token" {
  value     = try(local.config["home_assistant"]["token"], null)
  sensitive = true
}
