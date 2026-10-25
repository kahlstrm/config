terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
  }
}

variable "pems" {
  description = "Every intermediate and cross-signed root the CA may issue from, keyed by name."
  type        = map(string)
}

# www-ssl workers look up the chain in the store when they start, so it must stay complete.
# RouterOS imports a certificate with the subject and key of an existing one over it, so a
# re-issued intermediate can neither sit next to the old one nor replace it without a gap.
# The installed copy is kept instead; it shares the key, so it completes either one's chain.
resource "routeros_system_certificate" "this" {
  for_each    = var.pems
  name        = "${each.key}.crt"
  common_name = each.key
  import {
    cert_file_content = each.value
  }
  lifecycle {
    ignore_changes = [common_name, import]
  }
}

locals {
  # invalid_after is the router's local time, which is close enough at this margin.
  expiring = [for cert in routeros_system_certificate.this : cert.name if timecmp("${replace(cert.invalid_after, " ", "T")}Z", timeadd(plantimestamp(), "2160h")) < 0]
}

check "chain_expiry" {
  assert {
    condition     = length(local.expiring) == 0
    error_message = "Installed chain certificates expire within 90 days: ${join(", ", local.expiring)}. If the CA re-issued one, run /certificate import on the router with its current file, which RouterOS applies in place; otherwise unpin it once no leaf uses it."
  }
}

output "pems" {
  description = "The pinned certificates, available once they are on the router."
  value       = { for key, cert in routeros_system_certificate.this : key => var.pems[key] }
}

output "key_ids" {
  description = "Subject key identifiers of the certificates installed on the router."
  value       = toset([for cert in routeros_system_certificate.this : cert.skid])
}
