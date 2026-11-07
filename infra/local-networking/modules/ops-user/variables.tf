variable "public_key" {
  description = "The ops VM's SSH public key (modules/agent-ops/public/routeros.pub)."
  type        = string
}

variable "address" {
  description = "Source address the ops user may log in from: the host that masquerades the ops VM."
  type        = string
}

variable "poe_cycle_ports" {
  description = "PoE-out port to power-cycle, keyed by the node name each script is named after."
  type        = map(string)
}

variable "off_duration" {
  description = "How long each power cycle keeps the port unpowered."
  type        = string
  default     = "10s"
}
