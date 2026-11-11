# TODO

- [ ] Assess whether sharing the network inventory between Terraform and Nix
  makes sense, including agent DNS and firewall settings. If worthwhile, move
  the full inventory (hosts, addresses, subnets, gateways, DNS names, MAC
  addresses, and DHCP reservations) into shared JSON in a separate PR.
  Keep credentials and access policies separate from inventory.
- [ ] Move every secret to the private sops repository, as decided in
  [the private secrets repository ADR](docs/adr/2026-11-11-secrets-in-a-private-sops-repository.md):
  the recovery key first, then the agents' GitHub App key and the Headscale
  OIDC secret, then the cluster, Terraform and host secrets once off-host
  backups run.
