# TODO

- [ ] In a separate PR, move the full network inventory (hosts, addresses,
  subnets, gateways, DNS names, MAC addresses, and DHCP reservations) into shared
  JSON consumed by Terraform and Nix, including agent DNS and firewall settings.
  Keep credentials and access policies separate from inventory.

- [ ] Migrate MinIO root/Loki and Harbor admin passwords in
  [kubernetes-secrets.tf](local-talos/kubernetes-secrets.tf) to ephemeral
  Terraform resources and write-only Kubernetes Secret fields so credentials
  are not stored in Terraform state.
