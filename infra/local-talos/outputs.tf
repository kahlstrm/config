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

output "external_secrets_audience" {
  description = "Workload identity audience for the External Secrets Operator store"
  value       = "//iam.googleapis.com/${google_iam_workload_identity_pool_provider.kubernetes.name}"
}
