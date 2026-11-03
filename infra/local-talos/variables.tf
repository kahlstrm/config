variable "cni" {
  description = "Pod network: flannel or cilium. Plain plans and applies must keep the default; see README.md#cilium for when cilium is passed and when it becomes the default."
  type        = string
  default     = "flannel"

  validation {
    condition     = contains(["flannel", "cilium"], var.cni)
    error_message = "cni must be flannel or cilium."
  }
}
