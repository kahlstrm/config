output "talosconfig" {
  description = "Talos client configuration"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "kubeconfig" {
  description = "Kubernetes client configuration"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "machine_configurations" {
  description = "Rendered machine configuration of each node, by hostname"
  value = merge(
    { for hostname, config in data.talos_machine_configuration.controlplane : hostname => config.machine_configuration },
    { for hostname, config in data.talos_machine_configuration.worker : hostname => config.machine_configuration },
  )
  sensitive = true
}
