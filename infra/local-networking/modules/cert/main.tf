terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
    acme = {
      source = "vancluever/acme"
    }
  }
}

resource "acme_certificate" "cert" {
  account_key_pem = var.account_key_pem
  common_name     = var.domain

  dns_challenge {
    provider = "cloudflare"
    config = {
      CF_DNS_API_TOKEN = var.cf_dns_api_token
    }
  }
}

module "router" {
  source          = "./router"
  domain          = acme_certificate.cert.common_name
  issuance_id     = acme_certificate.cert.certificate_url
  certificate_pem = acme_certificate.cert.certificate_pem
  private_key_pem = acme_certificate.cert.private_key_pem
  issuer_pem      = acme_certificate.cert.issuer_pem
}

moved {
  from = routeros_system_certificate.external
  to   = module.router.routeros_system_certificate.external
}

moved {
  from = routeros_system_certificate.external_issuer
  to   = module.router.routeros_system_certificate.external_issuer
}

moved {
  from = routeros_system_certificate.external_issuer_cross
  to   = module.router.routeros_system_certificate.external_issuer_cross
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
