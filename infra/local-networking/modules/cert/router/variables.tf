variable "domain" {
  description = "The domain the certificate is issued for."
  type        = string
}

variable "issuance_id" {
  description = "A non-secret value unique to each issuance, such as the ACME certificate URL."
  type        = string
}

variable "certificate_pem" {
  description = "The leaf certificate."
  type        = string
}

variable "private_key_pem" {
  description = "The leaf certificate's private key."
  type        = string
  sensitive   = true
}

variable "issuer_pem" {
  description = "The issuer chain: an intermediate followed by a cross-signed root."
  type        = string
}
