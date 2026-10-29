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

variable "control_planes" {
  description = "Control-plane nodes by hostname. patches follow controlplane_patches."
  type = map(object({
    ip            = string
    install_disk  = string
    install_image = string
    patches       = optional(list(string), [])
  }))
}

variable "workers" {
  description = "Worker nodes by hostname. patches follow worker_patches."
  type = map(object({
    ip            = string
    install_disk  = string
    install_image = string
    patches       = optional(list(string), [])
  }))
  default = {}
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
