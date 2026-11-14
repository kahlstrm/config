# Off-site restic repository for the hosts' backups (docs/backups.md). The hosts log in to
# the `restic` subaccount with the backup SSH key (`backup` in lib/ssh-keys.nix); its private
# half and the restic password stay in the private secrets repository, never in Terraform.
#
# Neither account accepts connections from outside Hetzner's network. poenttoe, on Hetzner
# Cloud, connects directly; pannu and zima jump through it (modules/backup.nix). No IP
# allowlist exists, and SFTP, FTP and password login can't be turned off, so the passwords
# below are reset in the Hetzner Console after the first apply and the subaccount's is not
# kept (README.md, "Storage Box").

# Hetzner requires a password for each account, and the provider keeps it in this layer's
# state. It never reads the password back, so the Console reset leaves the plan clean.
resource "random_password" "storage_box" {
  for_each = toset(["main", "restic"])

  length           = 40
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
  override_special = "!$%/()=?+#-.,;:~*@{}_&"
}

resource "hcloud_storage_box" "backups" {
  name             = "backups"
  storage_box_type = "bx11"
  location         = "fsn1"
  password         = random_password.storage_box["main"].result

  # The main account has no SSH key and nothing logs in with it.
  access_settings = {
    reachable_externally = false
    ssh_enabled          = false
    samba_enabled        = false
    webdav_enabled       = false
    zfs_enabled          = false
  }

  # Daily, outside restic, so no SFTP login can delete the last 10 days. BX11 keeps at most 10.
  snapshot_plan = {
    max_snapshots = 10
    minute        = 0
    hour          = 4
  }

  delete_protection = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "hcloud_storage_box_subaccount" "restic" {
  storage_box_id = hcloud_storage_box.backups.id
  name           = "restic"
  home_directory = "restic/"
  password       = random_password.storage_box["restic"].result
  description    = "restic repository for the hosts' backups"

  # SSH (port 23) for restic. External access is on only while the backup key is installed
  # (TF_VAR_STORAGE_BOX_SETUP=true, README.md), because the API cannot set a subaccount's keys.
  access_settings = {
    reachable_externally = var.STORAGE_BOX_SETUP
    ssh_enabled          = true
    samba_enabled        = false
    webdav_enabled       = false
    readonly             = false
  }
}
