locals {
  cluster_name = "klusse"

  versions = jsondecode(file("${path.module}/versions.json"))
  # Machine configuration contract from cluster creation; OS upgrades change only installer images.
  talos_config_version = "v1.11.5"

  # The provider upgrades a node when its running Talos version differs from the image tag.
  rpi5_installer_image   = "ghcr.io/kahlstrm/talos-installer-rpi5:${local.versions.talos}"
  worker_installer_image = data.talos_image_factory_urls.worker.urls.installer

  control_planes = {
    for hostname in ["c1.k8s.kalski.xyz", "c2.k8s.kalski.xyz", "c3.k8s.kalski.xyz"] : hostname => {
      ip            = local.k8s_controlplanes[hostname].ip
      install_disk  = "/dev/nvme0n1"
      install_image = local.rpi5_installer_image
      patches       = [file("${path.module}/patches/rpi5-ethernet-offloads.yaml")]
    }
  }

  # Disks are named by serial: NVMe device names follow probe order and have
  # shifted on both workers. Every new node sets install_disk_serial; see
  # README.md#install-disks.
  workers = {
    "w1.k8s.kalski.xyz" = {
      ip                  = local.k8s_workers["w1.k8s.kalski.xyz"].ip
      install_disk_serial = "S34ENB0J901856" # Samsung MZVPW256 256 GB
      install_image       = local.worker_installer_image
      patches = [
        # Samsung 980 PRO 1 TB, for the local-nvme StorageClass.
        templatefile("${path.module}/templates/user-volume.yaml.tmpl", { name = "local-storage", disk_serial = "S5GXNF0R218244B" }),
      ]
    }
    "w2.k8s.kalski.xyz" = {
      ip                  = local.k8s_workers["w2.k8s.kalski.xyz"].ip
      install_disk_serial = "S34ENB0J901857" # Samsung MZVPW256 256 GB
      install_image       = local.worker_installer_image
      patches = [
        # WD_BLACK SN7100 1 TB, for the local-nvme StorageClass.
        templatefile("${path.module}/templates/user-volume.yaml.tmpl", { name = "local-storage", disk_serial = "2450A7403637" }),
      ]
    }
    # Minisforum MS-01, i5-12600H: a dedicated orb node. Commissioning wipes both
    # disks; see docs/runbooks/minisforum-talos-worker.md.
    "w3.k8s.kalski.xyz" = {
      ip                  = local.k8s_workers["w3.k8s.kalski.xyz"].ip
      install_disk_serial = "220535669A25" # Micron MTFDKBA256TFK 256 GB
      install_image       = local.worker_installer_image
      wipe_disk_serials   = ["220535669A25", "50026B7384341BE2"]
      patches = [
        file("${path.module}/patches/orb-dedicated-worker.yaml"),
        # Kingston OM8TAP41024K1 1 TB, for orb thread disks.
        templatefile("${path.module}/templates/user-volume.yaml.tmpl", { name = "orb-storage", disk_serial = "50026B7384341BE2" }),
      ]
    }
  }

  controlplane_patches = [
    file("${path.module}/patches/openebs-controlplane.yaml"),
    file("${path.module}/patches/metrics-controlplane.yaml"),
    templatefile("${path.module}/templates/api-vip.yaml.tmpl", { vip = local.k8s_api_vip }),
    templatefile("${path.module}/templates/service-account-issuer.yaml.tmpl", {
      issuer = local.service_account_issuer
    }),
    local.flux_bootstrap_patch,
  ]

  worker_patches = [
    file("${path.module}/patches/openebs-worker.yaml"),
    file("${path.module}/patches/metrics-worker.yaml"),
    file("${path.module}/patches/containerd-worker.yaml"),
    file("${path.module}/patches/userns-worker.yaml"),
  ]
}

resource "talos_image_factory_schematic" "worker" {
  schematic = yamlencode({ customization = {} })
}

data "talos_image_factory_urls" "worker" {
  talos_version = local.versions.talos
  schematic_id  = talos_image_factory_schematic.worker.id
  platform      = "metal"
}

# Workers with a GPU add patches/nvidia-worker.yaml to their patches.
module "cluster" {
  source = "../modules/talos-cluster"

  cluster_name         = local.cluster_name
  cluster_endpoint     = local.cluster_endpoint
  talos_config_version = local.talos_config_version
  kubernetes_version   = local.versions.kubernetes
  bootstrap_node       = "c1.k8s.kalski.xyz"
  control_planes       = local.control_planes
  workers              = local.workers
  cni                  = var.cni
  cilium_manifest      = file("${path.module}/manifests/cilium.yaml")
  controlplane_patches = local.controlplane_patches
  worker_patches       = local.worker_patches
}
