# TODO

- [ ] Assess whether sharing the network inventory between Terraform and Nix
  makes sense, including agent DNS and firewall settings. If worthwhile, move
  the full inventory (hosts, addresses, subnets, gateways, DNS names, MAC
  addresses, and DHCP reservations) into shared JSON in a separate PR.
  Keep credentials and access policies separate from inventory.
- [ ] Move the agenix host secrets (`secrets/*.age`) to sops-nix with the same
  `.sops.yaml`, hosts decrypting with their SSH host keys. The agents' GitHub
  App key and the Headscale OIDC secret are internet-usable, so decide where
  they belong rather than committing them as public ciphertext.
