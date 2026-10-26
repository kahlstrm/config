terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
    tls = {
      source = "hashicorp/tls"
    }
  }
}

locals {
  issuer_pems = regexall("(?s)-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", var.issuer_pem)
  # Issuers are compared by subject rather than content: an intermediate the CA re-issues
  # keeps its name and key, so the router completes the chain of a leaf issued by either.
  pinned_subjects = toset([for cert in data.tls_certificate.chain : cert.certificates[0].subject])
  issuer_subjects = [for cert in data.tls_certificate.issuer : cert.certificates[0].subject]
}

# tls_certificate parses only the first certificate of its content. The issuer chain is
# unknown until a new certificate is issued, so its certificates are parsed in slots
# bounded by the pinned chain; a longer one must contain an unpinned certificate.
data "tls_certificate" "issuer" {
  count   = length(var.chain_pems)
  content = try(local.issuer_pems[count.index], local.issuer_pems[0])
}

data "tls_certificate" "chain" {
  for_each = var.chain_pems
  content  = each.value
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
  lifecycle {
    create_before_destroy = true
    precondition {
      condition     = length(local.issuer_pems) <= length(var.chain_pems) && length(setsubtract(local.issuer_subjects, local.pinned_subjects)) == 0
      error_message = "The issuer chain contains a certificate missing from chain_pems; pin it before installing this certificate."
    }
    # The subject check cannot see keys, and the router keeps its installed copy of a pinned
    # name. Checked once the router reports the leaf's issuer key, before services rebind.
    postcondition {
      condition     = contains(var.chain_key_ids, self.akid)
      error_message = "The certificate is not signed by an installed chain certificate; a pinned name has a new key. Import its current file on the router before installing this certificate."
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
