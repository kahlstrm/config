terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
  }
}

locals {
  pem_pattern = "(?s)-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----"
  # Compares certificates regardless of line endings and wrapping.
  chain_bodies  = toset([for pem in values(var.chain_pems) : replace(regex(local.pem_pattern, pem), "/\\s/", "")])
  issuer_bodies = [for pem in regexall(local.pem_pattern, var.issuer_pem) : replace(pem, "/\\s/", "")]
}

# www-ssl workers look up the chain in the store when they start, so it must stay complete
# throughout a renewal. RouterOS deduplicates certificates by content, which rules out
# create_before_destroy for a chain that is only known once the new certificate is issued.
# The chain is therefore pinned and never touched by renewals; each key names fixed content.
resource "routeros_system_certificate" "chain" {
  for_each    = var.chain_pems
  name        = "${var.domain}.${each.key}.crt"
  common_name = each.key
  import {
    cert_file_content = each.value
  }
  lifecycle {
    ignore_changes = [common_name, import]
  }
}

resource "routeros_system_certificate" "external" {
  # RouterOS binds /ip service to a certificate's internal id, not its name, so a stable
  # name leaves www-ssl and api-ssl on the destroyed cert after a renewal and kills HTTPS.
  # The per-issuance suffix gives those services a real diff, and create_before_destroy
  # keeps the binding valid throughout. Hash the issuance id, not the sensitive pem.
  # www-ssl workers find their leaf by subject key identifier, which Let's Encrypt derives
  # from the key: a new leaf with the old key is served as the old one, so each issuance
  # needs a new key.
  name        = "${var.domain}-${substr(sha256(var.issuance_id), 0, 8)}.crt"
  common_name = var.domain
  import {
    cert_file_content = var.certificate_pem
    key_file_content  = var.private_key_pem
  }
  depends_on = [routeros_system_certificate.chain]
  lifecycle {
    create_before_destroy = true
    precondition {
      condition     = alltrue([for body in local.issuer_bodies : contains(local.chain_bodies, body)])
      error_message = "The issuer chain contains a certificate missing from chain_pems; pin it before installing this certificate."
    }
  }
}

# Enable HTTPS WebFig with that cert; disable plain HTTP
resource "routeros_ip_service" "www" {
  numbers  = "www"
  port     = 80
  disabled = true
}

resource "routeros_ip_service" "api_ssl" {
  numbers     = "api-ssl"
  certificate = routeros_system_certificate.external.name
  port        = 8729
  disabled    = false
}

resource "routeros_ip_service" "www_ssl" {
  numbers     = "www-ssl"
  certificate = routeros_system_certificate.external.name
  port        = 443
  disabled    = false
  # Terraform talks to RouterOS through www-ssl, and rebinding it drops in-flight
  # connections, so it is rebound last.
  depends_on = [routeros_ip_service.api_ssl]
}
