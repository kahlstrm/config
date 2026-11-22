# Wipes a Talos node's disks, picked by serial, through the maintenance API
# before the node is first configured. A user volume only takes free space, so
# a data disk that still holds old partitions never provisions, and old boot
# partitions can make the firmware boot them instead of Talos.
#
# Talos serves --insecure calls only in maintenance mode, so a rerun against a
# configured node fails before it wipes anything. The apply needs talosctl and
# jq on PATH. terraform test runs provisioners even on overridden resources, so
# tests override this whole module.

variable "node" {
  description = "Address of the node in maintenance mode."
  type        = string
}

variable "serials" {
  description = "Serials of the disks to wipe; each must match exactly one disk."
  type        = list(string)
}

resource "terraform_data" "this" {
  input = { node = var.node, serials = var.serials }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = { NODE = var.node, SERIALS = join(" ", var.serials) }
    command     = <<-EOT
      set -euo pipefail
      disks=$(talosctl get disks --insecure -n "$NODE" -o json | jq -s .)
      # Resolve every serial before wiping any disk.
      names=()
      for serial in $SERIALS; do
        names+=("$(jq -er --arg serial "$serial" '[.[] | select(.spec.serial == $serial) | .metadata.id] | if length == 1 then .[0] else error("serial \($serial) matches \(length) disks") end' <<<"$disks")")
      done
      for disk in "$${names[@]}"; do
        echo "wiping $disk on $NODE"
        talosctl wipe disk "$disk" --insecure -n "$NODE"
      done
    EOT
  }
}
