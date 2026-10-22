terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
    acme = {
      source = "vancluever/acme"
    }
    time = {
      source = "hashicorp/time"
    }
    tls = {
      source = "hashicorp/tls"
    }
  }
}

# acme_certificate renewals reuse the key, and RouterOS would keep serving the previous
# leaf (see ./router). Instead, each certificate is ordered for a new key, on a schedule
# well inside Let's Encrypt's certificate lifetime.
resource "time_rotating" "key" {
  rotation_days = 30
}

resource "tls_private_key" "cert" {
  algorithm = "RSA"
  rsa_bits  = 2048
  lifecycle {
    replace_triggered_by = [time_rotating.key]
  }
}

resource "tls_cert_request" "cert" {
  private_key_pem = tls_private_key.cert.private_key_pem
  dns_names       = [var.domain]
  subject {
    common_name = var.domain
  }
}

resource "acme_certificate" "cert" {
  account_key_pem         = var.account_key_pem
  certificate_request_pem = tls_cert_request.cert.cert_request_pem
  # Never renew in place, which would keep the key; the routers serve the old certificate
  # until the new one is installed, so it must stay valid.
  min_days_remaining            = -1
  revoke_certificate_on_destroy = false

  dns_challenge {
    provider = "cloudflare"
    config = {
      CF_DNS_API_TOKEN = var.cf_dns_api_token
    }
  }

  lifecycle {
    create_before_destroy = true
    postcondition {
      condition     = timecmp(self.certificate_not_after, timeadd(time_rotating.key.rotation_rfc3339, "336h")) > 0
      error_message = "The certificate expires less than two weeks after the next key rotation; shorten time_rotating.key."
    }
  }
}

module "router" {
  source          = "./router"
  domain          = var.domain
  issuance_id     = acme_certificate.cert.certificate_url
  certificate_pem = acme_certificate.cert.certificate_pem
  private_key_pem = tls_private_key.cert.private_key_pem
  issuer_pem      = acme_certificate.cert.issuer_pem
  # Let's Encrypt's intermediates and Root YR cross-signed by ISRG Root X1, which clients
  # that trust only X1 need: https://letsencrypt.org/certificates/
  chain_pems = { for file in fileset("${path.module}/chain", "*.pem") : trimsuffix(file, ".pem") => file("${path.module}/chain/${file}") }
}

moved {
  from = routeros_system_certificate.external
  to   = module.router.routeros_system_certificate.external
}

moved {
  from = routeros_system_certificate.external_issuer_cross
  to   = module.router.routeros_system_certificate.chain["root-yr-by-x1"]
}

moved {
  from = routeros_ip_service.www
  to   = module.router.routeros_ip_service.www
}

moved {
  from = routeros_ip_service.api_ssl
  to   = module.router.routeros_ip_service.api_ssl
}

moved {
  from = routeros_ip_service.www_ssl
  to   = module.router.routeros_ip_service.www_ssl
}
