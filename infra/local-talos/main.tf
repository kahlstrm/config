locals {
  cluster_name = "klusse"

  # Node that does the talos cluster bootstrap
  bootstrap_node = "c1.k8s.kalski.xyz"

  versions = jsondecode(file("${path.module}/versions.json"))
  # Machine configuration contract from cluster creation; OS upgrades change only installer images.
  talos_config_version = "v1.11.5"

  # The provider upgrades a node when its running Talos version differs from the image tag.
  rpi5_installer_image   = "ghcr.io/kahlstrm/talos-installer-rpi5:${local.versions.talos}"
  worker_installer_image = data.talos_image_factory_urls.worker.urls.installer

  control_plane_node_config = {
    "c1.k8s.kalski.xyz" = {
      install_disk  = "/dev/nvme0n1"
      install_image = local.rpi5_installer_image
    }
    "c2.k8s.kalski.xyz" = {
      install_disk  = "/dev/nvme0n1"
      install_image = local.rpi5_installer_image
    }
    "c3.k8s.kalski.xyz" = {
      install_disk  = "/dev/nvme0n1"
      install_image = local.rpi5_installer_image
    }
  }

  # Node-specific configuration
  worker_node_config = {
    "w1.k8s.kalski.xyz" = {
      install_disk        = "/dev/nvme0n1"
      install_image       = local.worker_installer_image
      storage_disks       = []
      storage_disk_serial = "S5GXNF0R218244B" # nvme2n1 for local-nvme StorageClass
    }
    "w2.k8s.kalski.xyz" = {
      install_disk        = "/dev/nvme1n1"
      install_image       = local.worker_installer_image
      storage_disk_serial = "2450A7403637"
    }
  }
}

resource "talos_image_factory_schematic" "worker" {
  schematic = yamlencode({ customization = {} })
}

data "talos_image_factory_urls" "worker" {
  talos_version = local.versions.talos
  schematic_id  = talos_image_factory_schematic.worker.id
  platform      = "metal"
}

resource "talos_machine_secrets" "salaisuudet" {
  talos_version = "1.10"
}

data "talos_client_configuration" "this" {
  cluster_name         = local.cluster_name
  client_configuration = talos_machine_secrets.salaisuudet.client_configuration
  endpoints            = [for hostname, node in local.control_plane_node_config : hostname]
  nodes                = concat(keys(local.control_plane_node_config), keys(local.worker_node_config))
}

data "talos_machine_configuration" "controlplane" {
  for_each = local.control_plane_node_config

  cluster_name       = local.cluster_name
  talos_version      = local.talos_config_version
  kubernetes_version = local.versions.kubernetes
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.salaisuudet.machine_secrets
  config_patches = [
    templatefile("${path.module}/templates/install-disk-and-hostname.yaml.tmpl", merge({
      hostname = each.key
      },
      each.value
    )),
    file("${path.module}/patches/openebs-controlplane.yaml"),
    file("${path.module}/patches/metrics-controlplane.yaml"),
    file("${path.module}/patches/network-policy-controlplane.yaml"),
    templatefile("${path.module}/templates/api-vip.yaml.tmpl", { vip = local.k8s_api_vip }),
    templatefile("${path.module}/templates/service-account-issuer.yaml.tmpl", {
      issuer = local.service_account_issuer
    }),
    local.flux_bootstrap_patch
  ]
}

data "talos_machine_configuration" "worker" {
  for_each = local.worker_node_config

  cluster_name       = local.cluster_name
  talos_version      = local.talos_config_version
  kubernetes_version = local.versions.kubernetes
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.salaisuudet.machine_secrets
  config_patches = concat([
    templatefile("${path.module}/templates/install-disk-and-hostname.yaml.tmpl", merge({
      hostname = each.key
      },
      each.value
    )),
    file("${path.module}/patches/openebs-worker.yaml"),
    file("${path.module}/patches/metrics-worker.yaml")
    ],
    lookup(each.value, "storage_disk_serial", null) != null ? [
      templatefile("${path.module}/templates/user-volume.yaml.tmpl", {
        storage_disk_serial = each.value.storage_disk_serial
      })
    ] : [],
    lookup(each.value, "nvidia_gpu", false) ? [
      file("${path.module}/patches/nvidia-worker.yaml")
    ] : []
  )
}

resource "talos_machine" "controlplane" {
  for_each = local.control_plane_node_config

  node                  = local.k8s_controlplanes[each.key].ip
  client_configuration  = talos_machine_secrets.salaisuudet.client_configuration
  machine_configuration = data.talos_machine_configuration.controlplane[each.key].machine_configuration
  image                 = each.value.install_image
  drain_on_upgrade      = false
}

resource "talos_machine" "worker" {
  for_each = local.worker_node_config

  node                  = local.k8s_workers[each.key].ip
  client_configuration  = talos_machine_secrets.salaisuudet.client_configuration
  machine_configuration = data.talos_machine_configuration.worker[each.key].machine_configuration
  image                 = each.value.install_image
  kubeconfig            = talos_cluster_kubeconfig.this.kubeconfig_raw
}

# WARNING:there should be just one of there per cluster
resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine.controlplane]
  client_configuration = talos_machine_secrets.salaisuudet.client_configuration
  node                 = local.k8s_controlplanes[local.bootstrap_node].ip
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.this]
  client_configuration = talos_machine_secrets.salaisuudet.client_configuration
  node                 = local.k8s_controlplanes[local.bootstrap_node].ip
}
