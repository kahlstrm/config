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
  description = "The issuer chain returned with the certificate; each element must be in chain_pems."
  type        = string
}

variable "chain_pems" {
  description = "Every intermediate and cross-signed root the CA may issue from, from a module that installs them on the router first."
  type        = map(string)
}

variable "chain_key_ids" {
  description = "Subject key identifiers of the chain certificates installed on the router."
  type        = set(string)
}
