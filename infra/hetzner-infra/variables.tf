variable "BOOTSTRAP" {
  description = "Enable temporary public SSH access for bootstrapping"
  type        = bool
  default     = false
}

variable "STORAGE_BOX_SETUP" {
  description = "Let the Storage Box's restic subaccount accept connections from outside Hetzner's network, only while its SSH key is installed"
  type        = bool
  default     = false
}
