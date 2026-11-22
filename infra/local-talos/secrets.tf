# A maintainer creates and fills this secret; Terraform only reads it, so no
# pending change can defer the read and leave the worker configurations unknown.
data "google_secret_manager_secret_version" "local_talos" {
  secret = "local-talos"
}

locals {
  # Disk serials aren't secret, but are kept out of this public repository;
  # for_each and plans need them unmarked.
  disk_serials = nonsensitive(jsondecode(data.google_secret_manager_secret_version.local_talos.secret_data)["disk_serials"])
}
