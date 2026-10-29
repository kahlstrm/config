# A Talos cluster: its secrets, each node's machine configuration, the nodes
# themselves and the etcd bootstrap. talos_machine upgrades a node whenever its
# running Talos version differs from its install image's tag.

locals {
  node_patches = {
    for hostname, node in merge(var.control_planes, var.workers) : hostname => templatefile(
      "${path.module}/install-disk-and-hostname.yaml.tmpl",
      { hostname = hostname, install_disk = node.install_disk, install_image = node.install_image }
    )
  }
}

resource "talos_machine_secrets" "this" {
  talos_version = "1.10"
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = keys(var.control_planes)
  nodes                = concat(keys(var.control_planes), keys(var.workers))
}

data "talos_machine_configuration" "controlplane" {
  for_each = var.control_planes

  cluster_name       = var.cluster_name
  talos_version      = var.talos_config_version
  kubernetes_version = var.kubernetes_version
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  config_patches     = concat([local.node_patches[each.key]], var.controlplane_patches, each.value.patches)
}

data "talos_machine_configuration" "worker" {
  for_each = var.workers

  cluster_name       = var.cluster_name
  talos_version      = var.talos_config_version
  kubernetes_version = var.kubernetes_version
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  config_patches     = concat([local.node_patches[each.key]], var.worker_patches, each.value.patches)
}

resource "talos_machine" "controlplane" {
  for_each = var.control_planes

  node                  = each.value.ip
  client_configuration  = talos_machine_secrets.this.client_configuration
  machine_configuration = data.talos_machine_configuration.controlplane[each.key].machine_configuration
  image                 = each.value.install_image
  drain_on_upgrade      = false
}

resource "talos_machine" "worker" {
  for_each = var.workers

  node                  = each.value.ip
  client_configuration  = talos_machine_secrets.this.client_configuration
  machine_configuration = data.talos_machine_configuration.worker[each.key].machine_configuration
  image                 = each.value.install_image
  kubeconfig            = talos_cluster_kubeconfig.this.kubeconfig_raw
}

# Bootstrap runs once per cluster; never let it be recreated.
resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine.controlplane]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.control_planes[var.bootstrap_node].ip
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.this]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.control_planes[var.bootstrap_node].ip
}
