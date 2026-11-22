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

# acme_certificate renewals reuse the key, and RouterOS would keep serving the previous
# leaf (see ./router). Instead, the first apply each month orders a certificate, which
# comes with a new key.
resource "terraform_data" "rotation" {
  input = formatdate("YYYY-MM", plantimestamp())
}

resource "acme_certificate" "cert" {
  account_key_pem = var.account_key_pem
  common_name     = var.domain
  # Never renew in place; the routers serve the old certificate until the new one is
  # installed, so it must stay valid.
  min_days_remaining            = -1
  revoke_certificate_on_destroy = false
  # Check DNS-01 propagation, and look up the zone, at kalski.xyz's authoritative
  # Cloudflare servers instead of the machine's resolver. The Cloudflare DNS provider asks
  # for the SOA of _acme-challenge.<domain> before it creates the TXT record, so a caching
  # resolver, such as a router's forwarder or a public recursor, then answers NXDOMAIN for
  # the zone's negative TTL (1800s), well past the provider's 2-minute propagation timeout.
  # Authoritative servers do not cache, and lego's authoritative check queries them anyway.
  # Update the list if `dig NS kalski.xyz` changes.
  recursive_nameservers = ["olivia.ns.cloudflare.com:53", "todd.ns.cloudflare.com:53"]

  dns_challenge {
    provider = "cloudflare"
    config = {
      CF_DNS_API_TOKEN = var.cf_dns_api_token
    }
  }

  lifecycle {
    create_before_destroy = true
    replace_triggered_by  = [terraform_data.rotation]
  }
}

check "certificate_expiry" {
  assert {
    condition     = timecmp(acme_certificate.cert.certificate_not_after, timeadd(plantimestamp(), "504h")) > 0
    error_message = "The certificate for ${var.domain} expires within three weeks; apply with -replace on its acme_certificate."
  }
}

module "router" {
  source          = "./router"
  domain          = var.domain
  issuance_id     = acme_certificate.cert.certificate_url
  certificate_pem = acme_certificate.cert.certificate_pem
  private_key_pem = acme_certificate.cert.private_key_pem
  issuer_pem      = acme_certificate.cert.issuer_pem
  chain_pems      = var.chain_pems
  chain_key_ids   = var.chain_key_ids
}
