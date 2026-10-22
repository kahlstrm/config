terraform {
  required_providers {
    routeros = { source = "terraform-routeros/routeros" }
  }
}

variable "hosturl" { type = string }
variable "password" {
  type      = string
  sensitive = true
}
variable "ca_certificate" {
  description = "Trust anchor file; empty skips verification while the router serves its self-signed certificate."
  type        = string
  default     = ""
}
variable "issuance_id" { type = string }
variable "certificate_pem" { type = string }
variable "private_key_pem" {
  type      = string
  sensitive = true
}
variable "issuer_pem" { type = string }

provider "routeros" {
  hosturl        = var.hosturl
  username       = "admin"
  password       = var.password
  insecure       = var.ca_certificate == ""
  ca_certificate = var.ca_certificate == "" ? null : var.ca_certificate
}

# Like acme_certificate during a renewal, a new issuance is unknown until apply.
resource "terraform_data" "issuance" {
  input = {
    id              = var.issuance_id
    certificate_pem = var.certificate_pem
    private_key_pem = var.private_key_pem
    issuer_pem      = var.issuer_pem
  }
}

module "router" {
  source          = "./modules/cert/router"
  domain          = "router.lab.test"
  issuance_id     = terraform_data.issuance.output.id
  certificate_pem = terraform_data.issuance.output.certificate_pem
  private_key_pem = terraform_data.issuance.output.private_key_pem
  issuer_pem      = terraform_data.issuance.output.issuer_pem
}
