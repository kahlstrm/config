# A lab cluster through production's talos-cluster module, which composes
# the CNI patches for var.cni as it does for local-talos. The role patches are
# production's files that apply to QEMU VMs (see internal/lab/production.go),
# the API VIP and user volume templates for lab addresses and disks, and the
# lab's own patches from the test (Flux without sync, no NTP).
terraform {
  backend "local" {}

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "0.12.0"
    }
  }
}

variable "cni" {
  type = string
}

variable "cilium_manifest" {
  description = "A Cilium manifest instead of production's, such as a broken one; empty for production's."
  type        = string
  default     = ""
}

variable "talos_config_version" {
  description = "Production's contract version from local-talos/main.tf."
  type        = string
}

variable "control_planes" {
  description = "IP by hostname."
  type        = map(string)
}

variable "workers" {
  description = "IP by hostname."
  type        = map(string)
}

variable "vip" {
  type = string
}

variable "storage_serial" {
  description = "Serial of each worker's second disk, for the local-storage user volume."
  type        = string
}

variable "lab_patches" {
  type = object({ controlplane = list(string), worker = list(string) })
}

locals {
  production = "${path.module}/../../../../../local-talos"
  versions   = jsondecode(file("${local.production}/versions.json"))
  # Production's worker installer: the Image Factory's empty schematic.
  install_image = "factory.talos.dev/metal-installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:${local.versions.talos}"
}

module "cluster" {
  source = "../../../../../modules/talos-cluster"

  cluster_name         = "talos-lab"
  cluster_endpoint     = "https://${var.vip}:6443"
  talos_config_version = var.talos_config_version
  kubernetes_version   = local.versions.kubernetes
  bootstrap_node       = keys(var.control_planes)[0]
  control_planes = {
    for hostname, ip in var.control_planes : hostname => { ip = ip, install_disk = "/dev/vda", install_image = local.install_image }
  }
  workers = {
    for hostname, ip in var.workers : hostname => {
      ip            = ip
      install_disk  = "/dev/vda"
      install_image = local.install_image
      patches       = [templatefile("${local.production}/templates/user-volume.yaml.tmpl", { name = "local-storage", disk_serial = var.storage_serial })]
    }
  }
  cni             = var.cni
  cilium_manifest = coalesce(var.cilium_manifest, file("${local.production}/manifests/cilium.yaml"))
  controlplane_patches = concat([
    file("${local.production}/patches/openebs-controlplane.yaml"),
    file("${local.production}/patches/metrics-controlplane.yaml"),
    templatefile("${local.production}/templates/api-vip.yaml.tmpl", { vip = var.vip }),
  ], var.lab_patches.controlplane)
  worker_patches = concat([
    file("${local.production}/patches/metrics-worker.yaml"),
    file("${local.production}/patches/containerd-worker.yaml"),
  ], var.lab_patches.worker)
}

output "talosconfig" {
  value     = module.cluster.talosconfig
  sensitive = true
}

output "kubeconfig" {
  value     = module.cluster.kubeconfig
  sensitive = true
}
