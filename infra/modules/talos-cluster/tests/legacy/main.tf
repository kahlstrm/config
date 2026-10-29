# Machine configurations as the module rendered them before it composed the
# CNI patches: callers passed the Flannel network-policy patch themselves.
# cni.tftest.hcl compares the module's flannel configs with these.
terraform {
  required_providers {
    talos = {
      source = "siderolabs/talos"
    }
  }
}

variable "cluster_name" { type = string }
variable "cluster_endpoint" { type = string }
variable "talos_config_version" { type = string }
variable "kubernetes_version" { type = string }
variable "control_planes" { type = any }
variable "workers" { type = any }
variable "controlplane_patches" { type = list(string) }
variable "worker_patches" { type = list(string) }

resource "talos_machine_secrets" "this" {
  talos_version = "1.10"
}

locals {
  nodes = merge(var.control_planes, var.workers)
  node_patches = {
    for hostname, node in local.nodes : hostname => templatefile(
      "${path.module}/../../install-disk-and-hostname.yaml.tmpl",
      { hostname = hostname, install_disk = node.install_disk, install_image = node.install_image }
    )
  }
}

data "talos_machine_configuration" "this" {
  for_each = local.nodes

  cluster_name       = var.cluster_name
  talos_version      = var.talos_config_version
  kubernetes_version = var.kubernetes_version
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = contains(keys(var.control_planes), each.key) ? "controlplane" : "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  config_patches = concat(
    [local.node_patches[each.key]],
    contains(keys(var.control_planes), each.key) ? var.controlplane_patches : var.worker_patches,
    try(each.value.patches, []),
  )
}

output "machine_configurations" {
  value     = { for hostname, config in data.talos_machine_configuration.this : hostname => config.machine_configuration }
  sensitive = true
}
