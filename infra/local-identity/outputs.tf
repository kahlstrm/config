output "pocket_id_enrolment_url" {
  description = "One-time link for registering a passkey in Pocket ID"
  value       = "https://id.kube.kalski.xyz/lc/${pocketid_one_time_access_token.kalle.token}"
  sensitive   = true
}
