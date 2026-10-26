variable "account_key_pem" {
  description = "The account key for ACME provider."
  type        = string
  sensitive   = true
}

variable "domain" {
  description = "The domain to issue the certificate for."
  type        = string
}

variable "cf_dns_api_token" {
  description = "The Cloudflare DNS API token."
  type        = string
  sensitive   = true
}

variable "chain_pems" {
  description = "Every intermediate and cross-signed root the CA may issue from, from a module that installs them on the router first."
  type        = map(string)
}

variable "chain_key_ids" {
  description = "Subject key identifiers of the chain certificates installed on the router."
  type        = set(string)
}
