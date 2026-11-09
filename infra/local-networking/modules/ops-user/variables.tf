variable "address" {
  description = "Source address the ops user may log in from: the host that masquerades the ops VM."
  type        = string
}

variable "poe_cycle_ports" {
  description = "PoE-out ports ops may power-cycle; each gets a script named after the port."
  type        = list(string)
}

variable "off_duration" {
  description = "How long each power cycle keeps the port unpowered."
  type        = string
  default     = "10s"
}
