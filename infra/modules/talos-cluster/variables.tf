variable "cluster_name" {
  description = "Talos and Kubernetes cluster name."
  type        = string
}

variable "cluster_endpoint" {
  description = "Kubernetes API endpoint, e.g. https://api.example:6443."
  type        = string
}

variable "talos_config_version" {
  description = "Machine configuration contract version the configs are generated for."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version of the control-plane components and kubelets."
  type        = string
}

variable "bootstrap_node" {
  description = "Key in control_planes of the node that bootstraps etcd."
  type        = string
}

# A fresh install writes Talos to install_disk_serial or install_disk; upgrades
# and resets use the disk Talos booted from. A device path such as /dev/nvme0n1
# follows probe order and can name a data disk after a disk is added, moved or
# replaced, and the next fresh install would overwrite it. A serial names one
# disk for good, so every new node sets install_disk_serial; install_disk
# remains only for nodes added before it.
variable "control_planes" {
  description = "Control-plane nodes by hostname. Set exactly one of install_disk_serial (the system disk's serial, from talosctl get disks) or install_disk (a device path). patches follow controlplane_patches."
  type = map(object({
    ip                  = string
    install_disk        = optional(string)
    install_disk_serial = optional(string)
    install_image       = string
    patches             = optional(list(string), [])
  }))

  validation {
    condition     = alltrue([for node in var.control_planes : (node.install_disk == null) != (node.install_disk_serial == null)])
    error_message = "Each control plane sets exactly one of install_disk_serial or install_disk."
  }
}

variable "workers" {
  description = "Worker nodes by hostname, with the install disk as in control_planes. wipe_disk_serials are disks wiped before the node's first configuration (see disk-wipe/main.tf). patches follow worker_patches."
  type = map(object({
    ip                  = string
    install_disk        = optional(string)
    install_disk_serial = optional(string)
    install_image       = string
    wipe_disk_serials   = optional(list(string), [])
    patches             = optional(list(string), [])
  }))
  default = {}

  validation {
    condition     = alltrue([for node in var.workers : (node.install_disk == null) != (node.install_disk_serial == null)])
    error_message = "Each worker sets exactly one of install_disk_serial or install_disk."
  }
}

variable "cni" {
  description = "Pod network: flannel (Talos's Flannel with kube-network-policies, and kube-proxy) or cilium (cilium_manifest on the control planes, no Talos CNI or kube-proxy)."
  type        = string
  default     = "flannel"

  validation {
    condition     = contains(["flannel", "cilium"], var.cni)
    error_message = "cni must be flannel or cilium."
  }
}

variable "cilium_manifest" {
  description = "Rendered Cilium manifest that Talos installs on the control planes when cni is cilium."
  type        = string
  default     = null

  validation {
    condition     = var.cni != "cilium" || var.cilium_manifest != null
    error_message = "cni = \"cilium\" needs cilium_manifest."
  }
}

variable "controlplane_patches" {
  description = "Machine-config patches for every control plane, applied after its install disk and hostname."
  type        = list(string)
  default     = []
}

variable "worker_patches" {
  description = "Machine-config patches for every worker, applied after its install disk and hostname."
  type        = list(string)
  default     = []
}
